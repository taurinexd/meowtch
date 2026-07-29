import SwiftUI
import VedettaKit

/// The plan preview inside an approval card. `AttributedString` alone only
/// understands inline syntax, so headings, quotes and lists used to reach
/// the notch as raw `#`, `>` and `-`. Blocks come from `PlanMarkdown`; each
/// block's text still goes through `AttributedString`, so bold, italics and
/// code spans keep working inside it.
struct PlanMarkdownView: View {
    let markdown: String

    var body: some View {
        let blocks = PlanMarkdown.blocks(from: markdown)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .padding(.top, index == 0 ? 0 : spacingAbove(block))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: PlanMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: level == 1 ? 13 : 12, weight: .bold))
                .foregroundStyle(level == 1 ? Theme.primaryText : Theme.accent)

        case .paragraph(let text):
            inline(text)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.primaryText)

        case .bullet(let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
                inline(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.primaryText)
            }
            .padding(.leading, indent(depth))

        case .ordered(let depth, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
                inline(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.primaryText)
            }
            .padding(.leading, indent(depth))

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Capsule()
                    .fill(Theme.accent.opacity(0.5))
                    .frame(width: 2)
                inline(text)
                    .font(.system(size: 11.5))
                    .italic()
                    .foregroundStyle(Theme.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let code):
            Text(code)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))

        case .divider:
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(height: 1)
        }
    }

    /// Headings and rules get room to breathe; consecutive list items stay
    /// tight so a numbered plan reads as one list.
    private func spacingAbove(_ block: PlanMarkdown.Block) -> CGFloat {
        switch block {
        case .heading: return 12
        case .divider: return 10
        case .bullet, .ordered: return 4
        case .code, .quote, .paragraph: return 8
        }
    }

    private func indent(_ depth: Int) -> CGFloat { CGFloat(min(depth, 4)) * 12 }

    private func inline(_ text: String) -> Text {
        Text((try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text))
    }
}
