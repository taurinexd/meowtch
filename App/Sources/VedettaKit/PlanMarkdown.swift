import Foundation

/// Block-level Markdown for the plan card. SwiftUI's `AttributedString`
/// parses inline syntax only, so a plan rendered through it kept its `#`,
/// `>` and list markers as literal text. This splits the plan into the few
/// block kinds a plan actually uses and leaves the inline syntax alone —
/// the view still hands each block's text to `AttributedString`, so bold,
/// italics and code spans keep working inside a heading or a list item.
public enum PlanMarkdown {
    public enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(depth: Int, text: String)
        case ordered(depth: Int, marker: String, text: String)
        case quote(String)
        case code(String)
        case divider
    }

    public static func blocks(from markdown: String) -> [Block] {
        var blocks: [Block] = []
        // Soft-wrapped lines join into the block being built; a blank line,
        // or a line that opens a different block, closes it.
        var pending: [String] = []
        var pendingKind: Kind?

        func flush() {
            defer { pending = []; pendingKind = nil }
            let text = pending.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, let pendingKind else { return }
            switch pendingKind {
            case .paragraph: blocks.append(.paragraph(text))
            case .quote: blocks.append(.quote(text))
            case .bullet(let depth): blocks.append(.bullet(depth: depth, text: text))
            case .ordered(let depth, let marker):
                blocks.append(.ordered(depth: depth, marker: marker, text: text))
            }
        }

        var lines = markdown.components(separatedBy: .newlines)[...]
        while let line = lines.first {
            lines = lines.dropFirst()
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            let body = line.trimmingCharacters(in: .whitespaces)

            if let fence = fenceToken(body) {
                flush()
                var code: [String] = []
                while let next = lines.first {
                    lines = lines.dropFirst()
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    code.append(next)
                }
                let joined = trimBlankEdges(code).joined(separator: "\n")
                if !joined.isEmpty { blocks.append(.code(joined)) }
                continue
            }

            if body.isEmpty { flush(); continue }

            if isRule(body) {
                flush()
                blocks.append(.divider)
                continue
            }

            if let heading = heading(body) {
                flush()
                blocks.append(heading)
                continue
            }

            if body.hasPrefix(">") {
                let text = String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
                if case .quote = pendingKind {} else { flush(); pendingKind = .quote }
                pending.append(text)
                continue
            }

            let depth = indent / 2
            if let marker = bulletMarker(body) {
                flush()
                pendingKind = .bullet(depth: depth)
                pending.append(String(body.dropFirst(marker.count))
                    .trimmingCharacters(in: .whitespaces))
                continue
            }

            if let (marker, consumed) = orderedMarker(body) {
                flush()
                pendingKind = .ordered(depth: depth, marker: marker)
                pending.append(String(body.dropFirst(consumed))
                    .trimmingCharacters(in: .whitespaces))
                continue
            }

            // A plain line continues whatever block is open (an indented
            // continuation of a list item included) or starts a paragraph.
            if pendingKind == nil { pendingKind = .paragraph }
            pending.append(body)
        }
        flush()
        return blocks
    }

    // MARK: - Line shapes

    private enum Kind: Equatable {
        case paragraph
        case quote
        case bullet(depth: Int)
        case ordered(depth: Int, marker: String)
    }

    private static func fenceToken(_ body: String) -> String? {
        for token in ["```", "~~~"] where body.hasPrefix(token) { return token }
        return nil
    }

    private static func isRule(_ body: String) -> Bool {
        for token: Character in ["-", "*", "_"] {
            let stripped = body.filter { !$0.isWhitespace }
            if stripped.count >= 3, stripped.allSatisfy({ $0 == token }) { return true }
        }
        return false
    }

    private static func heading(_ body: String) -> Block? {
        let hashes = body.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = String(body.dropFirst(hashes))
        guard rest.first == " " || rest.isEmpty else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .heading(level: hashes, text: text)
    }

    private static func bulletMarker(_ body: String) -> String? {
        for marker in ["- ", "* ", "+ "] where body.hasPrefix(marker) { return marker }
        return nil
    }

    /// `1.` and `1)` both count; the number is kept because in a plan it is
    /// content — a renderer that renumbered would misdescribe the steps.
    private static func orderedMarker(_ body: String) -> (marker: String, consumed: Int)? {
        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = body.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")" else { return nil }
        let after = rest.dropFirst()
        guard after.first == " " || after.isEmpty else { return nil }
        return ("\(digits).", digits.count + 1)
    }

    private static func trimBlankEdges(_ lines: [String]) -> [String] {
        var lines = lines[...]
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines = lines.dropFirst()
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines = lines.dropLast()
        }
        return Array(lines)
    }
}
