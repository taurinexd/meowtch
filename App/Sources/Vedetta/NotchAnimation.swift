import SwiftUI
import VedettaKit

/// The panel's open/close motion, defined once and shared: SwiftUI animates
/// with these curves, the controller interpolates hover hit-test geometry
/// with the same math, so both always agree on where the shape is.
///
/// The collapse is a fixed-duration bezier, not a spring: the original's measured
/// collapse is ~0.6s, monotonic, with a soft settle — a critically damped
/// spring over this travel distance crawls asymptotically for ~1.3s and
/// then visibly clamps a few points at termination (the "snap" at the end).
/// The bezier lands at zero velocity exactly at the end.
enum NotchAnimation {
    static let expandDuration: TimeInterval = 0.35
    static let collapseDuration: TimeInterval = 0.6
    /// Hit-test approximation of the expand spring (which stays a spring:
    /// its barely-there overshoot is measured on the original and fine).
    static let expandCurve = UnitBezier(0.3, 0.9, 0.4, 1)
    /// Fast departure, long gentle landing (measured feel of the original).
    static let collapseCurve = UnitBezier(0.16, 0.84, 0.28, 1)

    static let expand = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let collapse = Animation.timingCurve(0.16, 0.84, 0.28, 1, duration: collapseDuration)

    /// Fraction of the shape transition completed `elapsed` seconds after it
    /// started (1 when past the end).
    static func progress(elapsed: TimeInterval, expanding: Bool) -> Double {
        let duration = expanding ? expandDuration : collapseDuration
        let curve = expanding ? expandCurve : collapseCurve
        guard duration > 0 else { return 1 }
        return curve.progress(at: elapsed / duration)
    }
}
