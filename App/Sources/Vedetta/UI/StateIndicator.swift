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

    /// Frame counter for step-driven animations (spinner 0.12s, squash 0.15s).
    func tick(_ step: TimeInterval) -> Int {
        Int(now.timeIntervalSinceReferenceDate / step)
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
            DualChaseSpinner(cell: 3 * scale)
        case .compacting:
            CompactingSquash(cell: 3 * scale)
        case .waitingForInput:
            BlinkingBar(color: Theme.color(for: .waitingForInput), scale: scale)
        case .needsApproval:
            BlinkingQuestionMark(color: Theme.color(for: .needsApproval), scale: scale)
        case .completed:
            EmptyView()
        }
    }
}

/// 8-bit spinner: two opposite blocks chasing each other around the
/// perimeter of a square, each cell fading with distance from a head.
struct DualChaseSpinner: View {
    @ObservedObject private var clock = PixelClock.shared
    var color: Color = Theme.toolBlue
    var cell: CGFloat = 3

    var body: some View {
        let tick = clock.tick(0.12)
        Canvas { gc, _ in
            let inset = cell * 0.07
            for (i, p) in IndicatorFrames.ring.enumerated() {
                let alpha = IndicatorFrames.dualChaseAlpha(index: i, tick: tick)
                guard alpha > 0 else { continue }
                let rect = CGRect(
                    x: CGFloat(p.x) * cell + inset,
                    y: CGFloat(p.y) * cell + inset,
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

/// Compacting: a two-cell-wide column that squashes down to one row and
/// re-expands in steps — the context being compressed.
struct CompactingSquash: View {
    @ObservedObject private var clock = PixelClock.shared
    var color: Color = Theme.color(for: .compacting)
    var cell: CGFloat = 3

    var body: some View {
        let rows = IndicatorFrames.squashRowCount(tick: clock.tick(0.15))
        let maxRows = IndicatorFrames.squashHeights.max() ?? 4
        Canvas { gc, _ in
            let inset = cell * 0.07
            let top = CGFloat(maxRows - rows) * cell / 2
            for r in 0..<rows {
                let rect = CGRect(
                    x: inset,
                    y: top + CGFloat(r) * cell + inset,
                    width: cell * 2 - inset * 2,
                    height: cell - inset * 2
                )
                gc.fill(Path(rect), with: .color(color))
            }
        }
        .frame(width: cell * 2, height: cell * CGFloat(maxRows))
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
