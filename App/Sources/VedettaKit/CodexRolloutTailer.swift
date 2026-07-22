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

/// One pending request_user_input, as written in the rollout: the TUI shows
/// the options as a numbered picker, so their order IS the answer key.
public struct CodexPendingQuestion: Equatable, Sendable {
    public let question: String
    public let optionLabels: [String]
    /// Multi-question calls step through the TUI one at a time with
    /// restarting numbers: remote numeric answers are only safe for a
    /// single question.
    public let isMultiQuestion: Bool

    public init(question: String, optionLabels: [String], isMultiQuestion: Bool) {
        self.question = question
        self.optionLabels = optionLabels
        self.isMultiQuestion = isMultiQuestion
    }
}

public struct CodexRolloutSnapshot: Equatable, Sendable {
    public enum State: Equatable, Sendable { case running, waiting }

    public var threadID: String?
    public var cwd: String?
    public var originator: String?
    public var source: String?
    public var threadSource: String?
    public var origin: String?
    public var subagentKind: String?
    public var subagentParentThreadID: String?
    public var subagentNickname: String?
    public var subagentRole: String?
    public var firstUserMessage: String?
    public var lastUserMessage: String?
    public var lastAgentMessage: String?
    public var lastActivityAt: Date?
    public var reasoningEffort: String?
    public var activeTurnIDs: Set<String> = []
    public var openTools: [String: CodexRolloutTool] = [:]
    /// Open request_user_input calls (callID → question): the model is
    /// waiting for the USER, not working. Answered in the TUI; mirrored in
    /// the notch, with number-selectable options when there is one question.
    public var pendingUserInput: [String: CodexPendingQuestion] = [:]

    public var pendingUserInputQuestion: CodexPendingQuestion? {
        pendingUserInput.values.first
    }

    public var state: State { activeTurnIDs.isEmpty ? .waiting : .running }
    public var currentTool: String? {
        openTools.values.max(by: { $0.sequence < $1.sequence })?.name
    }
    public var currentToolDetail: String? {
        openTools.values.max(by: { $0.sequence < $1.sequence })?.detail
    }

    public var admissionMetadata: [String: String] {
        var metadata: [String: String] = [:]
        if let originator { metadata["originator"] = originator }
        if let source { metadata["source"] = source }
        if let threadSource { metadata["thread_source"] = threadSource }
        if let origin { metadata["origin"] = origin }
        if let subagentKind { metadata["subagent_kind"] = subagentKind }
        return metadata
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
            snapshot.originator = payload["originator"] as? String
            snapshot.source = payload["source"] as? String
            snapshot.threadSource = payload["thread_source"] as? String
            snapshot.origin = payload["origin"] as? String
            snapshot.subagentKind = payload["subagent_kind"] as? String
            snapshot.subagentParentThreadID = (payload["subagent_parent_thread_id"] as? String)
                ?? (payload["parent_thread_id"] as? String)
            snapshot.subagentNickname = payload["subagent_nickname"] as? String
            snapshot.subagentRole = payload["subagent_role"] as? String
            return
        }

        if type == "turn_context" {
            let settings = (payload["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any]
            let direct = Self.nonEmpty(payload["effort"] as? String)
            let nested = Self.nonEmpty(settings?["reasoning_effort"] as? String)
            snapshot.reasoningEffort = direct ?? nested ?? snapshot.reasoningEffort
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
            if payload["name"] as? String == "request_user_input" {
                snapshot.pendingUserInput[callID] = Self.firstQuestion(input)
                    ?? CodexPendingQuestion(
                        question: "Question pending",
                        optionLabels: [],
                        isMultiQuestion: false
                    )
            }
        case "function_call_output", "custom_tool_call_output", "tool_search_output":
            if let callID = (payload["call_id"] as? String) ?? (payload["id"] as? String) {
                snapshot.openTools.removeValue(forKey: callID)
                snapshot.pendingUserInput.removeValue(forKey: callID)
            }
        default:
            break
        }
    }

    /// The first question from request_user_input arguments
    /// ({"questions":[{"question":"…","options":[{"label":"…"},…]}]},
    /// JSON-in-string).
    private static func firstQuestion(_ input: Any?) -> CodexPendingQuestion? {
        var value = input
        if let text = value as? String,
           let decoded = try? JSONSerialization.jsonObject(with: Data(text.utf8)) {
            value = decoded
        }
        guard let object = value as? [String: Any],
              let questions = object["questions"] as? [[String: Any]],
              let firstQuestion = questions.first,
              let text = firstQuestion["question"] as? String,
              !text.isEmpty else { return nil }
        let labels = (firstQuestion["options"] as? [[String: Any]])?
            .compactMap { $0["label"] as? String } ?? []
        let multi = questions.count > 1
        return CodexPendingQuestion(
            question: multi ? "\(text) (+\(questions.count - 1))" : text,
            optionLabels: labels,
            isMultiQuestion: multi
        )
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
            if snapshot.activeTurnIDs.isEmpty {
                snapshot.openTools.removeAll()
                snapshot.pendingUserInput.removeAll()
            }
            snapshot.lastActivityAt = Self.date(payload["completed_at"])
                ?? snapshot.lastActivityAt
        case "turn_aborted":
            if let turnID = payload["turn_id"] as? String {
                snapshot.activeTurnIDs.remove(turnID)
            } else if snapshot.activeTurnIDs.count == 1 {
                snapshot.activeTurnIDs.removeAll()
            }
            if snapshot.activeTurnIDs.isEmpty {
                snapshot.openTools.removeAll()
                snapshot.pendingUserInput.removeAll()
            }
            snapshot.lastActivityAt = Self.date(payload["completed_at"])
                ?? snapshot.lastActivityAt
        case "thread_rolled_back":
            snapshot.activeTurnIDs.removeAll()
            snapshot.openTools.removeAll()
            snapshot.pendingUserInput.removeAll()
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

    /// Marks turns the rollout reported without a turn_id: they can never
    /// match a hook-provided turn identity and must not be compared to one.
    public static let anonymousTurnPrefix = "anonymous-turn-"

    private mutating func nextAnonymousTurnID() -> String {
        anonymousTurnSequence += 1
        return "\(Self.anonymousTurnPrefix)\(anonymousTurnSequence)"
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
        case "request_user_input": "Question"
        default: name
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = (value as? NSNumber)?.doubleValue, seconds > 0 {
            return Date(timeIntervalSince1970: seconds)
        }
        if let value = value as? String {
            // Codex stamps milliseconds ("…T08:20:12.128Z"); the plain
            // formatter rejects fractional seconds outright.
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: value)
                ?? ISO8601DateFormatter().date(from: value)
        }
        return nil
    }
}
