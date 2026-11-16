import Foundation

public struct TriggerInput: Sendable {
    public var pending: String
    public var now: Date
    /// Last transcript update of the client channel.
    public var lastClientActivity: Date?
    /// Last time the client's audio was loud. The transcript trails the
    /// audio by ~1 s and keeps updating through short pauses (measured
    /// 2026-11-16), so silence is read from here when it is known.
    public var lastClientSpeech: Date?
    public var lastMeActivity: Date?
    public var answered: [String]

    public init(pending: String, now: Date, lastClientActivity: Date?, lastClientSpeech: Date? = nil,
                lastMeActivity: Date?, answered: [String]) {
        self.pending = pending
        self.now = now
        self.lastClientActivity = lastClientActivity
        self.lastClientSpeech = lastClientSpeech
        self.lastMeActivity = lastMeActivity
        self.answered = answered
    }
}

public enum SuppressReason: String, Sendable {
    case meSpeaking
    case duplicate
}

public enum TriggerDecision: Equatable, Sendable {
    /// Not yet: keep listening.
    case wait
    /// The client asked something; `endpointAt` is when they stopped.
    case fire(question: String, endpointAt: Date)
    /// Drop what is pending without answering.
    case consume(reason: SuppressReason)
}

/// Decides whether the client just finished a question. Pure and cheap: it
/// never calls the answer engine (spec 09-02, «Confini non negoziabili»).
public enum AnswerTrigger {
    static let silenceAfterQuestionMark: TimeInterval = 0.6
    static let silenceAfterMarker: TimeInterval = 1.0
    static let meSpeakingWindow: TimeInterval = 1.5
    /// Without a «?», the transcript must stop changing this long first:
    /// the last words of a question arrive after the audio went quiet.
    static let textSettle: TimeInterval = 0.8
    static let minimumWords = 3
    /// A question longer than this many sentences is cut to its tail.
    static let maxQuestionSentences = 2
    static let duplicateSimilarity = 0.8

    static let truncationEndings: Set<String> = [
        "e", "ed", "ma", "che", "di", "del", "della", "per", "con", "a", "al", "in", "il", "la",
        "lo", "i", "gli", "le", "un", "una", "o", "se", "quindi", "però", "cioè", "tipo", "ehm",
    ]
    static let questionWords: Set<String> = [
        "chi", "cosa", "come", "quando", "quanto", "quanti", "quante", "perché", "quale", "quali", "dove",
    ]
    static let modalOpeners = [
        "potete", "potreste", "puoi", "potresti", "riuscite", "riesci", "avete", "hai", "sapete", "sai",
        "possiamo", "possono", "si potrebbe", "sarebbe possibile", "ci dite", "mi dite", "vi risulta",
        "è possibile", "si può", "ci sono", "c'è", "mi sai dire", "mi dici",
    ]

    public static func decide(_ input: TriggerInput) -> TriggerDecision {
        let text = input.pending.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = normalizedWords(text)
        guard words.count >= minimumWords,
              let clientAt = input.lastClientSpeech ?? input.lastClientActivity else { return .wait }
        let question = questionText(text)

        if let meAt = input.lastMeActivity,
           meAt > clientAt || input.now.timeIntervalSince(meAt) <= meSpeakingWindow {
            return .consume(reason: .meSpeaking)
        }
        if input.answered.contains(where: { isNearDuplicate(question, $0) }) {
            return .consume(reason: .duplicate)
        }
        let endsWithQuestionMark = text.hasSuffix("?")
        if !endsWithQuestionMark, let last = words.last, truncationEndings.contains(last) {
            return .wait
        }
        let silence = input.now.timeIntervalSince(clientAt)
        if endsWithQuestionMark, silence >= silenceAfterQuestionMark {
            return .fire(question: question, endpointAt: clientAt)
        }
        let settled = input.lastClientActivity.map { input.now.timeIntervalSince($0) } ?? .infinity
        // The transcript must have moved after the audio stopped: before
        // that, the last words are still being recognized.
        let caughtUp = input.lastClientSpeech.flatMap { speech in
            input.lastClientActivity.map { $0 > speech }
        } ?? true
        if looksLikeQuestion(question), silence >= silenceAfterMarker, settled >= textSettle, caughtUp {
            return .fire(question: question, endpointAt: clientAt)
        }
        return .wait
    }

    /// The tail of what was said, at most `maxQuestionSentences` sentences,
    /// without the stray punctuation a cut leaves at the start.
    public static func questionText(_ pending: String) -> String {
        var parts = sentences(pending)
        // A cut inside a word the transcriber later rewrote leaves a tail
        // like «llo?» in front: lowercase start, more sentences after it.
        if parts.count > 1, let first = parts.first?.first, first.isLowercase {
            parts.removeFirst()
        }
        return parts.suffix(maxQuestionSentences).joined(separator: " ")
    }

    static func sentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text.drop(while: { $0.isWhitespace || "?!.,;:".contains($0) }) {
            current.append(character)
            if "?!.".contains(character) {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        sentences.append(current.trimmingCharacters(in: .whitespaces))
        return sentences.filter { !$0.isEmpty }
    }

    /// Jaccard similarity of the normalized word sets.
    public static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        let left = Set(normalizedWords(a)), right = Set(normalizedWords(b))
        guard !left.isEmpty, !right.isEmpty else { return false }
        let similarity = Double(left.intersection(right).count) / Double(left.union(right).count)
        return similarity >= duplicateSimilarity
    }

    /// A question word anywhere, or a sentence that opens like a request.
    private static func looksLikeQuestion(_ text: String) -> Bool {
        sentences(text).contains { sentence in
            let words = normalizedWords(sentence)
            if words.contains(where: questionWords.contains) { return true }
            let opening = words.joined(separator: " ")
            return modalOpeners.contains { opening == $0 || opening.hasPrefix($0 + " ") }
        }
    }

    /// Lowercased words without punctuation; apostrophes kept («c'è»).
    static func normalizedWords(_ text: String) -> [String] {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .unicodeScalars.map { scalar -> Character in
                CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar == "'"
                    ? Character(scalar) : " "
            }
        return String(cleaned).split(separator: " ").map(String.init)
    }
}

/// One answer streams at a time; while it does, only the newest waiting
/// item is kept (spec: «resta in coda solo l'ultima»).
public struct LatestOnlyQueue<Item: Sendable>: Sendable {
    public private(set) var isBusy = false
    private var waiting: Item?

    public init() {}

    /// The item to start now, or nil when it was queued instead.
    public mutating func submit(_ item: Item) -> Item? {
        guard isBusy else {
            isBusy = true
            return item
        }
        waiting = item
        return nil
    }

    /// The current item finished: the waiting one to start, if any.
    public mutating func finish() -> Item? {
        guard let next = waiting else {
            isBusy = false
            return nil
        }
        waiting = nil
        return next
    }
}
