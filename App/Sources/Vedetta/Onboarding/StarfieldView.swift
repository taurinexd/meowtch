import SwiftUI

/// The night sky behind the lookout: two layers of pixel stars drifting at
/// different speeds (parallax), deterministic per star so the field is
/// stable across renders. Honors Reduce Motion by standing still.
struct StarfieldView: View {
    /// Points per second of the slow layer; the near layer moves 2.4×.
    var driftSpeed: CGFloat = 2.0
    var starCount: Int = 90
    var tint: Color = .white

    private struct Star {
        let x: CGFloat        // 0…1, wraps horizontally
        let y: CGFloat        // 0…1
        let size: CGFloat     // pixel square side
        let brightness: Double
        let near: Bool        // parallax layer
        let twinklePhase: Double
    }

    private static func makeStars(count: Int) -> [Star] {
        // Cheap deterministic PRNG (LCG) so the sky is the same every time.
        var seed: UInt64 = 0x5EED_CAFE
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
        }
        return (0..<count).map { _ in
            let near = next() > 0.72
            return Star(
                x: next(),
                y: next(),
                size: near ? 2.6 : 1.6,
                brightness: 0.25 + Double(next()) * (near ? 0.55 : 0.35),
                near: near,
                twinklePhase: Double(next()) * .pi * 2
            )
        }
    }

    private let stars: [Star]
    private let reduceMotion =
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    init(driftSpeed: CGFloat = 2.0, starCount: Int = 90, tint: Color = .white) {
        self.driftSpeed = driftSpeed
        self.starCount = starCount
        self.tint = tint
        stars = Self.makeStars(count: starCount)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                let t = reduceMotion
                    ? 0 : timeline.date.timeIntervalSinceReferenceDate
                for star in stars {
                    let speed = driftSpeed * (star.near ? 2.4 : 1.0)
                    let x = (star.x * size.width + CGFloat(t) * speed)
                        .truncatingRemainder(dividingBy: size.width)
                    let y = star.y * size.height
                    // Slow twinkle, subtle enough to read as phosphor noise.
                    let twinkle = reduceMotion
                        ? 1.0 : 0.75 + 0.25 * sin(t * 1.3 + star.twinklePhase)
                    context.fill(
                        Path(CGRect(x: x, y: y, width: star.size, height: star.size)),
                        with: .color(tint.opacity(star.brightness * twinkle))
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}
