import Foundation

/// Cubic bezier timing curve (CSS-style: endpoints fixed at 0,0 and 1,1).
/// Used to share one animation curve between SwiftUI (which animates with
/// it) and the controller (which interpolates hit-test geometry with it).
public struct UnitBezier: Sendable {
    public let p1x: Double
    public let p1y: Double
    public let p2x: Double
    public let p2y: Double

    public init(_ p1x: Double, _ p1y: Double, _ p2x: Double, _ p2y: Double) {
        self.p1x = p1x
        self.p1y = p1y
        self.p2x = p2x
        self.p2y = p2y
    }

    private func sampleX(_ t: Double) -> Double {
        let c = 3 * p1x
        let b = 3 * (p2x - p1x) - c
        let a = 1 - c - b
        return ((a * t + b) * t + c) * t
    }

    private func sampleY(_ t: Double) -> Double {
        let c = 3 * p1y
        let b = 3 * (p2y - p1y) - c
        let a = 1 - c - b
        return ((a * t + b) * t + c) * t
    }

    /// Progress (0…1) at normalized time `u` (0…1), clamped outside.
    public func progress(at u: Double) -> Double {
        if u <= 0 { return 0 }
        if u >= 1 { return 1 }
        // Solve x(t) = u by bisection (monotonic for valid control points).
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if sampleX(mid) < u { low = mid } else { high = mid }
        }
        return sampleY((low + high) / 2)
    }
}
