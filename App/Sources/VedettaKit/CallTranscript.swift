import Foundation

/// Who said a line. The capture channel is the label: meeting audio is the
/// client, the microphone is Matteo — no diarization to guess.
public enum CallSpeaker: String, Sendable {
    case client
    case me
}

public struct CallLine: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let speaker: CallSpeaker
    public var text: String
    public var isFinal: Bool
    public let startedAt: Date
    public var updatedAt: Date
}

/// The live conversation, in memory only. Each channel has at most one
/// open (non-final) line, always its latest: volatile results rewrite it,
/// a final result closes it, the next result opens a new one.
public struct CallTranscript: Sendable {
    public struct Update: Sendable {
        public var speaker: CallSpeaker
        public var text: String
        public var isFinal: Bool
        public var at: Date

        public init(speaker: CallSpeaker, text: String, isFinal: Bool, at: Date) {
            self.speaker = speaker
            self.text = text
            self.isFinal = isFinal
            self.at = at
        }
    }

    public private(set) var lines: [CallLine] = []

    public init() {}

    public mutating func apply(_ update: Update) {
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let index = lines.lastIndex(where: { $0.speaker == update.speaker }),
           !lines[index].isFinal {
            lines[index].text = text
            lines[index].isFinal = update.isFinal
            lines[index].updatedAt = update.at
        } else {
            lines.append(CallLine(
                id: UUID(), speaker: update.speaker, text: text,
                isFinal: update.isFinal, startedAt: update.at, updatedAt: update.at
            ))
        }
    }

    /// The last `limit` lines, oldest first.
    public func recent(_ limit: Int) -> [CallLine] {
        Array(lines.suffix(limit))
    }

    /// The most recently updated line still being spoken, on either channel.
    public var liveLine: CallLine? {
        lines.filter { !$0.isFinal }.max { $0.updatedAt < $1.updatedAt }
    }
}
