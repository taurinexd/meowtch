import SwiftUI

/// Terminal-style reveal: the line types itself out with a blinking block
/// cursor at the head. Reduce Motion (or `animated: false`) shows the full
/// line at once, cursor still blinking — the prompt idiom stays.
struct TypewriterText: View {
    let text: String
    var font: Font = .system(size: 12, design: .monospaced)
    var color: Color = Theme.primaryText
    var charactersPerSecond: Double = 36
    var startDelay: TimeInterval = 0.15
    var animated: Bool = true

    @State private var visibleCount = 0
    @State private var cursorOn = true

    private var reveal: Bool {
        animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var body: some View {
        // The full line reserves its final size invisibly, so the layout
        // never shifts while the visible prefix grows over it.
        Text(text)
            .opacity(0)
            .overlay(alignment: .leading) {
                HStack(spacing: 0) {
                    Text(String(text.prefix(visibleCount)))
                    Text("_")
                        .opacity(cursorOn ? 1 : 0)
                }
                .lineLimit(1)
                .fixedSize()
            }
            .font(font)
            .foregroundStyle(color)
            .task(id: text) {
                visibleCount = reveal ? 0 : text.count
                guard reveal else { return }
                try? await Task.sleep(for: .seconds(startDelay))
                while visibleCount < text.count, !Task.isCancelled {
                    visibleCount += 1
                    try? await Task.sleep(for: .seconds(1.0 / charactersPerSecond))
                }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(0.55))
                    cursorOn.toggle()
                }
            }
    }
}
