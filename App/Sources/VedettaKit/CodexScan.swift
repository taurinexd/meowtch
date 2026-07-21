import Foundation

/// Parsers for Codex CLI session artifacts: rollout JSONL files
/// (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) and the session index
/// (`~/.codex/session_index.jsonl`) that carries thread names.
///
/// Rollouts remain the fallback for Codex sessions that started before hook
/// installation. They record a turn's life as `task_started` … tool calls …
/// `task_complete` event_msgs, enough to drive running/waiting plus the current
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
        var complete = data
        if complete.last != 0x0A { complete.append(0x0A) }
        var tailer = CodexRolloutTailer()
        let snapshot = tailer.ingest(complete, resetting: true)
        return Rollout(
            sessionId: snapshot.threadID,
            cwd: snapshot.cwd,
            firstUserMessage: snapshot.firstUserMessage,
            lastUserMessage: snapshot.lastUserMessage,
            lastAgentMessage: snapshot.lastAgentMessage,
            state: snapshot.state == .running ? .running : .waiting,
            currentTool: snapshot.currentTool,
            currentToolDetail: snapshot.currentToolDetail,
            lastActivityAt: snapshot.lastActivityAt
        )
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
