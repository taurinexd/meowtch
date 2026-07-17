import Foundation

/// Parsers for Codex CLI session artifacts: rollout JSONL files
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) and the session index
/// (`~/.codex/session_index.jsonl`) that carries thread names.
public enum CodexScan {
    public struct Rollout: Sendable {
        public var sessionId: String?
        public var cwd: String?
        public var firstUserMessage: String?
        public var lastUserMessage: String?
        public var lastAgentMessage: String?
    }

    public static func parseRollout(_ data: Data) -> Rollout {
        var rollout = Rollout()
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let entry = object as? [String: Any] else { continue }
            let type = entry["type"] as? String
            let payload = entry["payload"] as? [String: Any]

            if type == "session_meta", let payload {
                rollout.sessionId = (payload["session_id"] as? String) ?? (payload["id"] as? String)
                rollout.cwd = payload["cwd"] as? String
                continue
            }
            guard type == "event_msg", let payload,
                  let kind = payload["type"] as? String,
                  let message = payload["message"] as? String, !message.isEmpty else { continue }
            switch kind {
            case "user_message":
                if rollout.firstUserMessage == nil { rollout.firstUserMessage = message }
                rollout.lastUserMessage = message
            case "agent_message":
                rollout.lastAgentMessage = message
            default:
                break
            }
        }
        return rollout
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
