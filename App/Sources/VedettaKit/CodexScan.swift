import Foundation

/// Parsers for Codex CLI session artifacts: rollout JSONL files
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) and the session index
/// (`~/.codex/session_index.jsonl`) that carries thread names.
///
/// Codex has no hooks, so the rollout is the only signal. It records a turn's
/// life as `task_started` … tool calls … `task_complete` event_msgs, which is
/// enough to drive the same running/waiting card as Claude, plus the current
/// tool from the last open `function_call`.
public enum CodexScan {
    public enum State: Sendable { case running, waiting }

    public struct Rollout: Sendable {
        public var sessionId: String?
        public var cwd: String?
        public var firstUserMessage: String?
        public var lastUserMessage: String?
        public var lastAgentMessage: String?
        public var state: State = .waiting
        public var currentTool: String?
        public var currentToolDetail: String?
        public var lastActivityAt: Date?
    }

    public static func parseRollout(_ data: Data) -> Rollout {
        var rollout = Rollout()
        var openTurns = 0             // task_started minus task_complete
        var toolOpen = false          // a function_call awaiting its output
        var lastToolName: String?
        var lastToolDetail: String?

        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let entry = object as? [String: Any] else { continue }
            let type = entry["type"] as? String
            guard let payload = entry["payload"] as? [String: Any] else {
                if type == "session_meta" {
                    // Older rollouts put session_meta fields at the top level.
                }
                continue
            }

            if type == "session_meta" {
                rollout.sessionId = (payload["session_id"] as? String) ?? (payload["id"] as? String)
                rollout.cwd = payload["cwd"] as? String
                continue
            }

            guard let kind = payload["type"] as? String else { continue }

            if type == "response_item" {
                switch kind {
                case "function_call", "custom_tool_call":
                    lastToolName = payload["name"] as? String
                    lastToolDetail = toolDetail(arguments: payload["arguments"] as? String)
                    toolOpen = true
                case "function_call_output", "custom_tool_call_output",
                     "web_search_call", "tool_search_output":
                    toolOpen = false
                default:
                    break
                }
                continue
            }

            guard type == "event_msg" else { continue }
            switch kind {
            case "task_started":
                openTurns += 1
                rollout.lastActivityAt = epoch(payload["started_at"]) ?? rollout.lastActivityAt
            case "task_complete":
                openTurns = max(0, openTurns - 1)
                toolOpen = false
                rollout.lastActivityAt = epoch(payload["completed_at"]) ?? rollout.lastActivityAt
            case "user_message":
                if let message = payload["message"] as? String, !message.isEmpty {
                    if rollout.firstUserMessage == nil { rollout.firstUserMessage = message }
                    rollout.lastUserMessage = message
                }
            case "agent_message":
                if let message = payload["message"] as? String, !message.isEmpty {
                    rollout.lastAgentMessage = message
                }
            default:
                break
            }
        }

        rollout.state = openTurns > 0 ? .running : .waiting
        if rollout.state == .running, toolOpen {
            rollout.currentTool = friendlyToolName(lastToolName)
            rollout.currentToolDetail = lastToolDetail
        }
        return rollout
    }

    private static func epoch(_ value: Any?) -> Date? {
        guard let seconds = (value as? NSNumber)?.doubleValue, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// A short detail for the tool line, pulled from the call arguments (the
    /// command for a shell, the path for a patch/read).
    private static func toolDetail(arguments: String?) -> String? {
        guard let arguments, let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let detail = (args["cmd"] as? String)
            ?? (args["command"] as? String)
            ?? (args["path"] as? String)
            ?? (args["file_path"] as? String)
            ?? (args["query"] as? String)
        return detail?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Codex's internal tool names mapped to the familiar Claude-style labels.
    private static func friendlyToolName(_ name: String?) -> String? {
        switch name {
        case "exec_command", "shell", "local_shell": return "Bash"
        case "apply_patch": return "Edit"
        case "read_file": return "Read"
        case "web_search": return "WebSearch"
        case nil: return nil
        default: return name
        }
    }

    /// id → thread name from the session index (last entry wins).
    public static func parseIndex(_ data: Data) -> [String: String] {
        var names: [String: String] = [:]
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let entry = object as? [String: Any],
                  let id = entry["id"] as? String,
                  let name = entry["thread_name"] as? String, !name.isEmpty else { continue }
            names[id] = name
        }
        return names
    }
}
