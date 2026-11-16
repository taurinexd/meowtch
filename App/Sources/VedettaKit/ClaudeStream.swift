import Foundation

/// One finished turn of a `claude -p` stream-json session.
public struct ClaudeTurnResult: Equatable, Sendable {
    public var isError: Bool
    public var text: String
    /// Cost of this turn alone (measured: not cumulative across turns).
    public var costUSD: Double
    public var durationMs: Int
    public var outputTokens: Int

    public init(isError: Bool, text: String, costUSD: Double, durationMs: Int, outputTokens: Int) {
        self.isError = isError
        self.text = text
        self.costUSD = costUSD
        self.durationMs = durationMs
        self.outputTokens = outputTokens
    }
}

public enum ClaudeStreamEvent: Equatable, Sendable {
    case textDelta(String)
    case result(ClaudeTurnResult)
    case other
}

/// The stream-json wire format of the `claude` CLI, as observed on 2.1.325.
/// Not a contract: anything unexpected degrades to `.other`, never a crash.
public enum ClaudeStream {
    public static func parse(line: String) -> ClaudeStreamEvent {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return .other }
        switch type {
        case "stream_event":
            guard let event = object["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return .other }
            return .textDelta(text)
        case "result":
            let usage = object["usage"] as? [String: Any]
            return .result(ClaudeTurnResult(
                isError: object["is_error"] as? Bool ?? true,
                text: object["result"] as? String ?? "",
                costUSD: (object["total_cost_usd"] as? NSNumber)?.doubleValue ?? 0,
                durationMs: (object["duration_ms"] as? NSNumber)?.intValue ?? 0,
                outputTokens: (usage?["output_tokens"] as? NSNumber)?.intValue ?? 0
            ))
        default:
            return .other
        }
    }

    /// One user message for `--input-format stream-json`, newline-terminated.
    public static func userLine(_ content: String) -> String {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        let data = (try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
