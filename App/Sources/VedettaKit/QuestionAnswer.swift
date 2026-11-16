import Foundation

/// One AskUserQuestion answer as Claude Code expects it in
/// `updatedInput.answers`: the chosen option labels, plus the user's own
/// text when they typed one (the terminal picker's "Type something").
public enum QuestionAnswer {
    public static func values(labels: [String], selected: Set<Int>, freeText: String?) -> [String] {
        var values = selected.sorted().compactMap { labels.indices.contains($0) ? labels[$0] : nil }
        if let text = trimmed(freeText) { values.append(text) }
        return values
    }

    public static func isAnswered(selected: Set<Int>, freeText: String?) -> Bool {
        !selected.isEmpty || trimmed(freeText) != nil
    }

    private static func trimmed(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
