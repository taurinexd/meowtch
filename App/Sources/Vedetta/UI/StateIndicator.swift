import SwiftUI
import VedettaKit

/// Shared clock for the pixel animations. A plain RunLoop timer keeps
/// ticking even though the panel is a non-activating (never-key) window,
/// where SwiftUI's TimelineView animation schedules get paused.
/// One clock for all indicators also keeps every blink in sync,
/// like the original.
@MainActor
final class PixelClock: ObservableObject {
    static let shared = PixelClock()

    @Published private(set) var now = Date()
    private var timer: Timer?

    private init() {
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Blink timing measured on the original (bursts at a true 0.244s
    /// capture cadence): 1.2s period, on 60% of it.
    var blinkOn: Bool {
        let phase = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2)
        return phase < 0.72
    }

    /// Spinner step, advancing every 0.12s.
    var spinTick: Int {
        Int(now.timeIntervalSinceReferenceDate / 0.12)
    }
}

/// The little animated status element that sits next to the sprite,
/// mirroring the original: a spinning pixel block while the agent works,
/// a blinking green bar when it waits for input, a "?" whose dot blinks
/// when a question or approval is pending.
struct StateIndicator: View {
    let state: SessionState
    /// 1 in the expanded rows; smaller in the collapsed bar, where the
    /// left wing is only 40pt and the indicator must never reach the
    /// physical notch.
    var scale: CGFloat = 1

    var body: some View {
        switch state {
        case .running:
            PixelSpinner(cell: 3 * scale)
        case .compacting:
            PixelSpinner(color: Theme.color(for: .compacting), cell: 3 * scale)
        case .waitingForInput:
            BlinkingBar(color: Theme.color(for: .waitingForInput), scale: scale)
        case .needsApproval:
            BlinkingQuestionMark(color: Theme.color(for: .needsApproval), scale: scale)
        case .completed:
            EmptyView()
        }
    }
}

/// 8-bit spinner: a lit block chasing around the perimeter of a square.
struct PixelSpinner: View {
    @ObservedObject private var clock = PixelClock.shared
    var color: Color = Theme.toolBlue
    var cell: CGFloat = 3

    /// Perimeter of a 3×3 grid, clockwise from the top-left corner.
    private static let ring: [(Int, Int)] = [
        (0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1),
    ]

    var body: some View {
        let tick = clock.spinTick
        Canvas { gc, _ in
            let inset = cell * 0.07
            for (i, (cx, cy)) in Self.ring.enumerated() {
                let distance = (i - tick % 8 + 8) % 8
                let alpha = 1.0 - Double(distance) * 0.13
                let rect = CGRect(
                    x: CGFloat(cx) * cell + inset,
                    y: CGFloat(cy) * cell + inset,
                    width: cell - inset * 2,
                    height: cell - inset * 2
                )
                gc.fill(Path(rect), with: .color(color.opacity(alpha)))
            }
        }
        .frame(width: cell * 3, height: cell * 3)
        .shadow(color: color.opacity(0.8), radius: cell * 1.4)
    }
}

/// Hard on/off blinking bar (waiting for input): a 2×4 grid of small
/// squares with grid gaps and glow, like the original — not a solid pill.
struct BlinkingBar: View {
    @ObservedObject private var clock = PixelClock.shared
    var color: Color
    var scale: CGFloat = 1

    private static let glyph: [String] = ["##", "##", "##", "##"]

    var body: some View {
        PixelSprite(pattern: Self.glyph, color: color, pixelSize: 2.9 * scale)
            .opacity(clock.blinkOn ? 1 : 0)
    }
}

/// Pixel question mark whose dot blinks (question / approval pending).
struct BlinkingQuestionMark: View {
    @ObservedObject private var clock = PixelClock.shared
    var color: Color
    var scale: CGFloat = 1
    private var pixel: CGFloat { 2.5 * scale }

    private static let glyph: [String] = [
        ".###.",
        "#...#",
        "....#",
        "...#.",
        "..#..",
        "..#..",
    ]

    var body: some View {
        VStack(spacing: pixel) {
            PixelSprite(pattern: Self.glyph, color: color, pixelSize: pixel)
            PixelSprite(pattern: ["##", "##"], color: color, pixelSize: pixel)
                .opacity(clock.blinkOn ? 1 : 0)
        }
    }
}
