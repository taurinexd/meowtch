import Foundation

/// The quick lane's answer: what to say, then a control line the notch
/// never shows (`VERIFICA: no` or `VERIFICA: <what to look up>`).
public enum QuickAnswer {
    private static let marker = "VERIFICA"

    /// The text to show while it streams: a trailing control line, complete
    /// or still arriving («V», «VERIF», «VERIFICA: cer»), is cut.
    public static func visible(_ streaming: String) -> String {
        var lines = streaming.components(separatedBy: "\n")
        if let last = lines.last {
            let head = last.trimmingCharacters(in: .whitespaces).uppercased()
            if !head.isEmpty, (marker + ":").hasPrefix(head) || head.hasPrefix(marker) {
                lines.removeLast()
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the answer asks to verify; nil for `no` or a missing line.
    public static func verify(_ final: String) -> String? {
        guard let last = final.components(separatedBy: "\n")
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { !$0.isEmpty }),
            last.uppercased().hasPrefix(marker),
            let colon = last.firstIndex(of: ":") else { return nil }
        let value = last[last.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value.lowercased() == "no" ? nil : value
    }
}
