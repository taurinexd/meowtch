import Foundation

public struct CodexRolloutTool: Equatable, Sendable {
    public let callID: String
    public let name: String
    public let detail: String?
    fileprivate let sequence: Int

    public init(callID: String, name: String, detail: String?) {
        self.callID = callID
        self.name = name
        self.detail = detail
        sequence = 0
    }

    fileprivate init(callID: String, name: String, detail: String?, sequence: Int) {
        self.callID = callID
        self.name = name
        self.detail = detail
        self.sequence = sequence
    }
}

public struct CodexRolloutSnapshot: Equatable, Sendable {
    public enum State: Equatable, Sendable { case running, waiting }

    public var threadID: String?
    public var cwd: String?
    public var firstUserMessage: String?
    public var lastUserMessage: String?
    public var lastAgentMessage: String?
    public var lastActivityAt: Date?
    public var activeTurnIDs: Set<String> = []
    public var openTools: [String: CodexRolloutTool] = [:]

    public var state: State { activeTurnIDs.isEmpty ? .waiting : .running }
    public var currentTool: String? {
        openTools.values.max(by: { $0.sequence < $1.sequence })?.name
    }
    public var currentToolDetail: String? {
        openTools.values.max(by: { $0.sequence < $1.sequence })?.detail
    }
}

/// Incremental JSONL reader for one Codex rollout file. `offset` advances by
/// bytes actually read, while an unterminated final record remains buffered.
/// Inode changes and truncation reset both cursor and semantic state.
public struct CodexRolloutTailer: Sendable {
    public private(set) var offset: UInt64 = 0
    public private(set) var snapshot = CodexRolloutSnapshot()
    private var fileIdentity: UInt64?
    private var pending = Data()
    private var sequence = 0
    private var anonymousTurnSequence = 0

    public init() {}

    public mutating func read(from url: URL) throws -> CodexRolloutSnapshot {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let identity = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        if fileIdentity != nil && (identity != fileIdentity || size < offset) {
            reset()
        }
        fileIdentity = identity

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let appended = try handle.readToEnd() ?? Data()
        return ingest(appended)
    }

    /// Feeds already-read appended bytes. Used by the startup compatibility
    /// scan and by tests; live file reads should use `read(from:)`.
    public mutating func ingest(
        _ appended: Data,
        resetting: Bool = false
    ) -> CodexRolloutSnapshot {
        if resetting { reset() }
        offset += UInt64(appended.count)
        pending.append(appended)
        consumeCompleteLines()
        return snapshot
    }

    private mutating func reset() {
        offset = 0
        pending.removeAll(keepingCapacity: true)
        snapshot = CodexRolloutSnapshot()
        sequence = 0
        anonymousTurnSequence = 0
    }

    private mutating func consumeCompleteLines() {
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[..<newline]
            pending.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let entry = object as? [String: Any] else { continue }
            consume(entry)
        }
    }

    private mutating func consume(_ entry: [String: Any]) {
        guard let type = entry["type"] as? String,
              let payload = entry["payload"] as? [String: Any] else { return }

        if type == "session_meta" {
            snapshot.threadID = (payload["session_id"] as? String)
                ?? (payload["id"] as? String)
            snapshot.cwd = payload["cwd"] as? String
            return
        }

        guard let kind = payload["type"] as? String else { return }
        if type == "response_item" {
            consumeResponseItem(kind: kind, payload: payload)
            return
        }
        guard type == "event_msg" else { return }
        consumeEvent(kind: kind, payload: payload)
    }

    private mutating func consumeResponseItem(kind: String, payload: [String: Any]) {
        switch kind {
        case "function_call", "custom_tool_call":
            sequence += 1
            let callID = (payload["call_id"] as? String)
                ?? (payload["id"] as? String)
                ?? "anonymous-call-\(sequence)"
            let name = Self.friendlyToolName(payload["name"] as? String) ?? "Tool"
            let input = payload["input"] ?? payload["arguments"]
            snapshot.openTools[callID] = CodexRolloutTool(
                callID: callID,
                name: name,
                detail: Self.toolDetail(input),
                sequence: sequence
            )
        case "function_call_output", "custom_tool_call_output", "tool_search_output":
            if let callID = (payload["call_id"] as? String) ?? (payload["id"] as? String) {
                snapshot.openTools.removeValue(forKey: callID)
            }
        default:
            break
        }
    }

    private mutating func consumeEvent(kind: String, payload: [String: Any]) {
        switch kind {
        case "task_started":
            let turnID = payload["turn_id"] as? String ?? nextAnonymousTurnID()
            snapshot.activeTurnIDs.insert(turnID)
            snapshot.lastActivityAt = Self.date(payload["started_at"])
                ?? snapshot.lastActivityAt
        case "task_complete":
            if let turnID = payload["turn_id"] as? String {
                snapshot.activeTurnIDs.remove(turnID)
            } else if snapshot.activeTurnIDs.count == 1 {
                snapshot.activeTurnIDs.removeAll()
            }
            snapshot.lastActivityAt = Self.date(payload["completed_at"])
                ?? snapshot.lastActivityAt
        case "user_message":
            if let message = payload["message"] as? String, !message.isEmpty {
                if snapshot.firstUserMessage == nil { snapshot.firstUserMessage = message }
                snapshot.lastUserMessage = message
            }
        case "agent_message":
            if let message = payload["message"] as? String, !message.isEmpty {
                snapshot.lastAgentMessage = message
            }
        default:
            break
        }
    }

    private mutating func nextAnonymousTurnID() -> String {
        anonymousTurnSequence += 1
        return "anonymous-turn-\(anonymousTurnSequence)"
    }

    private static func toolDetail(_ input: Any?) -> String? {
        var value = input
        if let string = value as? String,
           let data = string.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) {
            value = decoded
        }
        guard let object = value as? [String: Any] else {
            return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let detail = (object["cmd"] as? String)
            ?? (object["command"] as? String)
            ?? (object["path"] as? String)
            ?? (object["file_path"] as? String)
            ?? (object["query"] as? String)
        return detail?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func friendlyToolName(_ name: String?) -> String? {
        switch name {
        case "exec", "exec_command", "shell", "local_shell": "Bash"
        case "apply_patch": "Edit"
        case "read_file": "Read"
        case "web_search": "WebSearch"
        default: name
        }
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = (value as? NSNumber)?.doubleValue, seconds > 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        if let value = value as? String {
            return ISO8601DateFormatter().date(from: value)
        }
        return nil
    }
}
