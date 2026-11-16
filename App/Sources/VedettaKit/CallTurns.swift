import Foundation

/// What the client has said that no suggestion has used yet. Volatile
/// results keep rewriting the open line, so a line consumed mid-sentence is
/// cut by the characters already seen; closed lines are consumed whole.
public struct CallTurns: Sendable {
    private var consumed: Set<UUID> = []
    private var openCut: (id: UUID, characters: Int)?

    public init() {}

    /// Client text after the mark, lines joined by a space.
    public func pending(in transcript: CallTranscript) -> String {
        transcript.lines
            .filter { $0.speaker == .client && !consumed.contains($0.id) }
            .map { line -> String in
                guard let cut = openCut, cut.id == line.id else { return line.text }
                return String(line.text.dropFirst(cut.characters))
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Marks everything the client said so far as used.
    public mutating func consumeAll(in transcript: CallTranscript) {
        for line in transcript.lines where line.speaker == .client {
            if line.isFinal {
                consumed.insert(line.id)
            } else {
                openCut = (line.id, line.text.count)
            }
        }
    }

    /// The last `lines` client lines, consumed or not: what ⌥ Space answers
    /// when nothing is pending.
    public func lastClientText(in transcript: CallTranscript, lines: Int) -> String {
        transcript.lines.filter { $0.speaker == .client }
            .suffix(lines)
            .map(\.text)
            .joined(separator: " ")
    }
}
