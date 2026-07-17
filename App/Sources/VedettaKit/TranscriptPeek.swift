import Foundation

/// Bounded, tolerant reader for Claude Code transcript JSONL files:
/// pulls the first real user prompt (session title) and the latest
/// user/assistant text (card body lines) without loading giant files.
public struct TranscriptPeek: Sendable {
    public var firstUserPrompt: String?
    public var lastUserText: String?
    public var lastAssistantText: String?
    /// The name the user gave the session (Claude Code records renames as
    /// system-reminder entries); the last rename wins.
    public var sessionName: String?
    /// Working directory recorded in the entries.
    public var cwd: String?

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

            if let cwd = entry["cwd"] as? String { peek.cwd = cwd }
            guard let text = textContent(of: message), !text.isEmpty else { continue }
            switch type {
            case "user":
                if let name = namedSession(in: text) {
                    peek.sessionName = name
                    continue
                }
                // Command invocations, caveats and reminders are transport
                // noise, not something the user typed.
                guard !text.hasPrefix("<") else { continue }
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

    /// Extracts NAME from `The user named this session "NAME"`.
    private static func namedSession(in text: String) -> String? {
        guard let range = text.range(of: #"The user named this session "([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let match = text[range]
        guard let open = match.firstIndex(of: "\""),
              let close = match.lastIndex(of: "\""), open < close else { return nil }
        return String(match[match.index(after: open)..<close])
    }

    /// Reads a bounded window of the file: the head answers "how did this
    /// session start" (first prompt, cwd), the tail answers "what happened
    /// last" (latest messages). Keeping them separate avoids attributing a
    /// head text as the latest message when the tail has none. Files can
    /// be tens of MB; we never load them whole.
    public static func read(path: String, headBytes: Int = 128 << 10, tailBytes: Int = 256 << 10) -> TranscriptPeek {
        guard let handle = FileHandle(forReadingAtPath: path) else { return TranscriptPeek() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0

        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: min(headBytes, size))) ?? Data()
        let headPeek = parse(head)
        guard size > headBytes else { return headPeek }

        let tailStart = max(size - tailBytes, headBytes)
        try? handle.seek(toOffset: UInt64(tailStart))
        var tail = ((try? handle.read(upToCount: size - tailStart)) ?? nil) ?? Data()
        if let newline = tail.firstIndex(of: 0x0A) {
            // drop the (possibly truncated) first line
            tail = tail.suffix(from: newline + 1)
        }
        let tailPeek = parse(tail)

        var merged = TranscriptPeek()
        merged.firstUserPrompt = headPeek.firstUserPrompt
        // The starting directory identifies the session (mid-session cd
        // into subdirectories must not relabel it); fall back to the tail
        // only when the original path no longer exists (dir renamed).
        if let headCwd = headPeek.cwd, FileManager.default.fileExists(atPath: headCwd) {
            merged.cwd = headCwd
        } else {
            merged.cwd = tailPeek.cwd ?? headPeek.cwd
        }
        merged.sessionName = tailPeek.sessionName ?? headPeek.sessionName
        merged.lastUserText = tailPeek.lastUserText
        merged.lastAssistantText = tailPeek.lastAssistantText

        // Renames can live anywhere in the file: when the windows missed
        // one, stream the whole file looking only for the marker.
        if merged.sessionName == nil, size > headBytes + tailBytes {
            merged.sessionName = scanForSessionName(handle: handle, size: size)
        }
        return merged
    }

    /// Streaming search for the rename marker across the whole file
    /// (chunked, constant memory); the last occurrence wins. The pattern
    /// is anchored to the raw bytes of a genuine reminder entry — code or
    /// conversation that merely QUOTES the phrase carries one more level
    /// of JSON escaping and cannot match.
    private static func scanForSessionName(handle: FileHandle, size: Int) -> String? {
        guard size < 128 << 20 else { return nil }
        // Both raw shapes are real: content as a plain string and content
        // as an array of text blocks.
        let markers = [
            Data(#""content":"<system-reminder>\nThe user named this session \""#.utf8),
            Data(#""text":"<system-reminder>\nThe user named this session \""#.utf8),
        ]
        let closer = Data(#"\""#.utf8)
        let chunkSize = 4 << 20
        var name: String?
        var offset = 0
        var carry = Data()
        try? handle.seek(toOffset: 0)
        while offset < size {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            offset += chunk.count
            var window = carry
            window.append(chunk)
            for marker in markers {
                var searchRange = window.startIndex..<window.endIndex
                while let found = window.range(of: marker, in: searchRange) {
                    if let end = window.range(of: closer, in: found.upperBound..<window.endIndex),
                       let extracted = String(data: window[found.upperBound..<end.lowerBound], encoding: .utf8),
                       !extracted.isEmpty, extracted.count < 120 {
                        name = extracted
                    }
                    searchRange = found.upperBound..<window.endIndex
                }
            }
            carry = window.suffix(markers[0].count + 256)
        }
        return name
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
