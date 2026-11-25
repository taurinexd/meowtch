import Foundation

/// On speakers the microphone hears the meeting: the "me" channel then
/// transcribes the client's own words a beat later. Treating that echo as
/// Matteo talking suppressed every question (measured 2026-11-25: zero
/// triggers in a whole call on the MacBook speakers). A "me" line counts as
/// echo when most of its words were just said by the client.
public enum CallEcho {
    /// Share of the line's words that must appear in nearby client speech.
    static let containment = 0.5
    /// How far apart the two channels' lines may be and still match.
    static let window: TimeInterval = 8
    static let minimumWords = 3

    public static func isEcho(_ line: CallLine, in transcript: CallTranscript) -> Bool {
        guard line.speaker == .me else { return false }
        let words = AnswerTrigger.normalizedWords(line.text)
        guard words.count >= minimumWords else { return false }
        let client = Set(transcript.lines
            .filter {
                $0.speaker == .client
                    && $0.updatedAt >= line.startedAt.addingTimeInterval(-window)
                    && $0.startedAt <= line.updatedAt.addingTimeInterval(window)
            }
            .flatMap { AnswerTrigger.normalizedWords($0.text) })
        guard !client.isEmpty else { return false }
        let shared = words.filter(client.contains).count
        return Double(shared) / Double(words.count) >= containment
    }

    /// Last update of a "me" line that is Matteo's own voice, not echo.
    public static func lastOwnSpeech(in transcript: CallTranscript) -> Date? {
        transcript.lines.last { $0.speaker == .me && !isEcho($0, in: transcript) }?.updatedAt
    }
}
