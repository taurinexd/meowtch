import Testing
@testable import VedettaKit

struct UnitBezierTests {
    @Test func endpointsAndClamping() {
        let curve = UnitBezier(0.16, 0.84, 0.28, 1)
        #expect(curve.progress(at: 0) == 0)
        #expect(curve.progress(at: 1) == 1)
        #expect(curve.progress(at: -0.5) == 0)
        #expect(curve.progress(at: 1.5) == 1)
    }

    @Test func monotonicallyIncreases() {
        let curve = UnitBezier(0.16, 0.84, 0.28, 1)
        var last = -0.001
        for step in 0...50 {
            let value = curve.progress(at: Double(step) / 50)
            #expect(value >= last)
            last = value
        }
    }

    @Test func strongEaseOutFrontLoadsTheTravel() {
        // The collapse curve must cover most of the distance early and land
        // gently: >70% done at half time, >95% at 80% time.
        let curve = UnitBezier(0.16, 0.84, 0.28, 1)
        #expect(curve.progress(at: 0.5) > 0.7)
        #expect(curve.progress(at: 0.8) > 0.95)
    }

    @Test func linearCurveIsIdentity() {
        let linear = UnitBezier(1.0 / 3, 1.0 / 3, 2.0 / 3, 2.0 / 3)
        for step in 1..<10 {
            let u = Double(step) / 10
            #expect(abs(linear.progress(at: u) - u) < 0.001)
        }
    }
}
