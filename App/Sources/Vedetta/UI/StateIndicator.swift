import SwiftUI
import VedettaKit

/// The little animated status element that sits next to the sprite,
/// mirroring the original: a spinning pixel block while the agent works,
/// a blinking green bar when it waits for input, a "?" whose dot blinks
/// when a question or approval is pending.
struct StateIndicator: View {
    let state: SessionState

    var body: some View {
        switch state {
        case .running:
            PixelSpinner()
        case .waitingForInput:
            BlinkingBar(color: Theme.color(for: .waitingForInput))
        case .needsApproval:
            BlinkingQuestionMark(color: Theme.color(for: .needsApproval))
        case .completed:
            EmptyView()
        }
    }
}

/// 8-bit spinner: a lit block chasing around the perimeter of a square.
struct PixelSpinner: View {
    var color: Color = Theme.toolBlue
    var cell: CGFloat = 3

    /// Perimeter of a 3×3 grid, clockwise from the top-left corner.
    private static let ring: [(Int, Int)] = [
        (0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1),
    ]

    var body: some View {
        TimelineView(.periodic(from: .distantPast, by: 0.12)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / 0.12)
            Canvas { gc, _ in
                for (i, (cx, cy)) in Self.ring.enumerated() {
                    let distance = (i - tick % 8 + 8) % 8
                    let alpha = 1.0 - Double(distance) * 0.13
                    let rect = CGRect(
                        x: CGFloat(cx) * cell,
                        y: CGFloat(cy) * cell,
                        width: cell,
                        height: cell
                    )
                    gc.fill(Path(rect), with: .color(color.opacity(alpha)))
                }
            }
            .frame(width: cell * 3, height: cell * 3)
        }
    }
}

/// Hard on/off blinking vertical bar (waiting for input).
struct BlinkingBar: View {
    var color: Color
    var period: Double = 1.0

    var body: some View {
        TimelineView(.periodic(from: .distantPast, by: period / 2)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / (period / 2)) % 2 == 0
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 5, height: 16)
                .opacity(on ? 1 : 0)
        }
    }
}

/// Pixel question mark whose dot blinks (question / approval pending).
struct BlinkingQuestionMark: View {
    var color: Color
    var period: Double = 1.0
    private let pixel: CGFloat = 2.5

    private static let glyph: [String] = [
        ".###.",
        "#...#",
        "....#",
        "...#.",
        "..#..",
        "..#..",
    ]

    var body: some View {
        TimelineView(.periodic(from: .distantPast, by: period / 2)) { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate / (period / 2)) % 2 == 0
            VStack(spacing: pixel) {
                PixelSprite(pattern: Self.glyph, color: color, pixelSize: pixel)
                Rectangle()
                    .fill(color)
                    .frame(width: pixel * 2, height: pixel * 2)
                    .opacity(on ? 1 : 0)
            }
        }
    }
}
