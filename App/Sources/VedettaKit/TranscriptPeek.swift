import Foundation

/// Bounded, tolerant reader for Claude Code transcript JSONL files:
/// pulls the first real user prompt (session title) and the latest
/// user/assistant text (card body lines) without loading giant files.
public struct TranscriptPeek: Sendable {
    public var firstUserPrompt: String?
    public var lastUserText: String?
    public var lastAssistantText: String?

    /// Parses transcript JSONL content. Malformed lines are skipped.
    public static func parse(_ data: Data) -> TranscriptPeek {
        var peek = TranscriptPeek()
        for lineData in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(lineData)),
                  let entry = object as? [String: Any],
                  let type = entry["type"] as? String,
                  let message = entry["message"] as? [String: Any] else { continue }
            // Subagent (sidechain) traffic interleaves with the main loop:
            // its texts are not the session's own words.
            if entry["isSidechain"] as? Bool == true { continue }

            guard let text = textContent(of: message), !text.isEmpty else { continue }
            switch type {
            case "user":
                if peek.firstUserPrompt == nil { peek.firstUserPrompt = text }
                peek.lastUserText = text
            case "assistant":
                peek.lastAssistantText = text
            default:
                break
            }
        }
        return peek
    }

    /// Reads a bounded window of the file: head for the title, tail for
    /// the latest messages. Files can be tens of MB; we never load them.
    public static func read(path: String, headBytes: Int = 128 << 10, tailBytes: Int = 256 << 10) -> TranscriptPeek {
        guard let handle = FileHandle(forReadingAtPath: path) else { return TranscriptPeek() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0

        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: min(headBytes, size))) ?? Data()
        var combined = head

        if size > headBytes {
            let tailStart = max(size - tailBytes, headBytes)
            try? handle.seek(toOffset: UInt64(tailStart))
            if var tail = (try? handle.read(upToCount: size - tailStart)) ?? nil {
                // drop the (possibly truncated) first line of the tail
                if let newline = tail.firstIndex(of: 0x0A) {
                    tail = tail.suffix(from: newline + 1)
                }
                combined.append(0x0A)
                combined.append(tail)
            }
        }
        return parse(combined)
    }

    /// Joins the text parts of a message's content (string or blocks).
    private static func textContent(of message: [String: Any]) -> String? {
        if let text = message["content"] as? String { return text }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }
}
