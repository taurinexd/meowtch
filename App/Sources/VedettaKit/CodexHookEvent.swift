import Foundation

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init?(any value: Any?) {
        guard let value, !(value is NSNull) else {
            self = .null
            return
        }
        if let value = value as? Bool {
            self = .bool(value)
        } else if let value = value as? NSNumber {
            self = .number(value.doubleValue)
        } else if let value = value as? String {
            self = .string(value)
        } else if let value = value as? [Any] {
            self = .array(value.compactMap(JSONValue.init(any:)))
        } else if let value = value as? [String: Any] {
            self = .object(value.compactMapValues(JSONValue.init(any:)))
        } else {
            return nil
        }
    }

    public var anyValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.anyValue)
        case .object(let values): values.mapValues(\.anyValue)
        }
    }
}

public enum CodexHookKind: String, CaseIterable, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case permissionRequest = "PermissionRequest"
    case postToolUse = "PostToolUse"
    case subagentStop = "SubagentStop"
    case stop = "Stop"
}

public enum CodexHookEventError: Error, LocalizedError {
    case wrongSource
    case missingEvent
    case unsupportedKind(String)
    case missingThreadID

    public var errorDescription: String? {
        switch self {
        case .wrongSource: "L'envelope non proviene da Codex"
        case .missingEvent: "Payload hook Codex mancante"
        case .unsupportedKind(let name): "Evento hook Codex non supportato: \(name)"
        case .missingThreadID: "Identità thread Codex mancante"
        }
    }
}

/// Typed, normalized fact decoded from the source-agnostic bridge envelope.
/// The original Codex identifiers remain available even though the Vedetta
/// session ID is namespaced to prevent collisions with Claude sessions.
public struct CodexHookEvent: Equatable, Sendable {
    public let kind: CodexHookKind
    public let threadID: String
    public let turnID: String?
    public let toolUseID: String?
    public let model: String?
    public let permissionMode: String?
    public let cwd: String?
    public let transcriptPath: String?
    public let toolName: String?
    public let toolInput: JSONValue?
    public let toolOutput: JSONValue?
    public let prompt: String?
    public let finalResponse: String?
    public let parentThreadID: String?
    public let subagentKind: String?
    public let subagentRole: String?
    public let subagentNickname: String?
    public let configuredReviewer: String?
    public let sandboxPolicy: JSONValue?
    public let autoReviewed: Bool
    public let terminal: TerminalInfo
    public let capturedAt: Date?

    public var sessionID: String { "codex-\(threadID)" }

    /// The original's Stop hook explicitly prints this benign response. Other
    /// non-blocking Codex hooks do not require hook output.
    public var nonBlockingResponse: JSONValue? {
        kind == .stop ? .object(["continue": .bool(true)]) : nil
    }

    public var nonBlockingResponseData: Data? {
        guard let nonBlockingResponse else { return nil }
        return try? JSONSerialization.data(withJSONObject: nonBlockingResponse.anyValue)
    }

    public init(envelope: [String: Any]) throws {
        guard envelope["source"] as? String == "codex" else {
            throw CodexHookEventError.wrongSource
        }
        guard let event = envelope["event"] as? [String: Any],
              let name = event["hook_event_name"] as? String else {
            throw CodexHookEventError.missingEvent
        }
        guard let kind = CodexHookKind(rawValue: name) else {
            throw CodexHookEventError.unsupportedKind(name)
        }
        let threadID = (event["codex_thread_id"] as? String)
            ?? (event["session_id"] as? String)
        guard let threadID, !threadID.isEmpty else {
            throw CodexHookEventError.missingThreadID
        }

        self.kind = kind
        self.threadID = threadID.removingCodexNamespace
        turnID = (event["codex_turn_id"] as? String) ?? (event["turn_id"] as? String)
        toolUseID = (event["tool_use_id"] as? String) ?? (event["call_id"] as? String)
        model = event["model"] as? String
        permissionMode = (event["permission_mode"] as? String)
            ?? (event["approval_policy"] as? String)
        cwd = event["cwd"] as? String
        transcriptPath = event["transcript_path"] as? String
        toolName = Self.displayToolName(event["tool_name"] as? String)
        toolInput = JSONValue(any: event["tool_input"] ?? event["input"])
        toolOutput = JSONValue(any: event["tool_response"] ?? event["tool_output"])
        prompt = event["prompt"] as? String
        finalResponse = event["last_assistant_message"] as? String
        parentThreadID = (event["parent_session_id"] as? String)
            ?? (event["parent_thread_id"] as? String)
            ?? (event["subagent_parent_thread_id"] as? String)
        subagentKind = event["subagent_kind"] as? String
        subagentRole = event["subagent_role"] as? String
        subagentNickname = event["subagent_nickname"] as? String
        configuredReviewer = event["approvals_reviewer"] as? String
        sandboxPolicy = JSONValue(any: event["sandbox_policy"])
        autoReviewed = (event["auto_reviewed"] as? Bool) ?? false
        terminal = Self.decodeTerminal(envelope["terminal"] as? [String: Any])
        capturedAt = (envelope["capturedAt"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    /// Transitional dictionary representation for existing presentation code.
    /// The ingress coordinator will consume this type directly.
    public var normalizedEnvelope: [String: Any] {
        var event: [String: Any] = [
            "hook_event_name": kind.rawValue,
            "session_id": sessionID,
            "codex_thread_id": threadID,
        ]
        if let turnID {
            event["turn_id"] = turnID
            event["codex_turn_id"] = turnID
        }
        if let toolUseID { event["tool_use_id"] = toolUseID }
        if let model { event["model"] = model }
        if let permissionMode { event["permission_mode"] = permissionMode }
        if let cwd { event["cwd"] = cwd }
        if let transcriptPath { event["transcript_path"] = transcriptPath }
        if let toolName { event["tool_name"] = toolName }
        if let toolInput { event["tool_input"] = toolInput.anyValue }
        if let toolOutput { event["tool_response"] = toolOutput.anyValue }
        if let prompt { event["prompt"] = prompt }
        if let finalResponse { event["last_assistant_message"] = finalResponse }
        if let parentThreadID { event["parent_session_id"] = parentThreadID }
        if let subagentKind { event["subagent_kind"] = subagentKind }
        if let subagentRole { event["subagent_role"] = subagentRole }
        if let subagentNickname { event["subagent_nickname"] = subagentNickname }
        if let configuredReviewer { event["approvals_reviewer"] = configuredReviewer }
        if let sandboxPolicy { event["sandbox_policy"] = sandboxPolicy.anyValue }
        event["auto_reviewed"] = autoReviewed

        var envelope: [String: Any] = [
            "v": 1,
            "source": "codex",
            "terminal": terminal.dictionaryValue,
            "event": event,
        ]
        if let capturedAt { envelope["capturedAt"] = capturedAt.timeIntervalSince1970 }
        return envelope
    }

    private static func displayToolName(_ name: String?) -> String? {
        switch name {
        case "exec", "exec_command", "shell", "local_shell": "Bash"
        case "apply_patch": "Edit"
        default: name
        }
    }

    private static func decodeTerminal(_ terminal: [String: Any]?) -> TerminalInfo {
        guard let terminal else { return TerminalInfo() }
        return TerminalInfo(
            tty: terminal["tty"] as? String,
            termProgram: terminal["termProgram"] as? String,
            bundleIdentifier: terminal["bundleIdentifier"] as? String,
            pid: (terminal["pid"] as? NSNumber)?.int32Value,
            windowId: (terminal["windowId"] as? NSNumber)?.intValue,
            pidChain: (terminal["pidChain"] as? [Any])?.compactMap {
                ($0 as? NSNumber)?.intValue
            }
        )
    }
}

/// A decoded hook is already the normalized fact consumed by Codex ingress.
public typealias CodexFact = CodexHookEvent

private extension String {
    var removingCodexNamespace: String {
        hasPrefix("codex-") ? String(dropFirst("codex-".count)) : self
    }
}

private extension TerminalInfo {
    var dictionaryValue: [String: Any] {
        var value: [String: Any] = [:]
        if let tty { value["tty"] = tty }
        if let termProgram { value["termProgram"] = termProgram }
        if let bundleIdentifier { value["bundleIdentifier"] = bundleIdentifier }
        if let pid { value["pid"] = pid }
        if let windowId { value["windowId"] = windowId }
        if let pidChain { value["pidChain"] = pidChain }
        return value
    }
}
