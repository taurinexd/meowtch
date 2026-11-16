import Foundation

/// Latency and override counters of one call (spec 09-02, «Metriche»),
/// read over the debug socket.
public struct CallMetrics: Sendable {
    private var endpointToDecision: [Int] = []
    private var decisionToFirstToken: [Int] = []
    private var overrides = 0

    public init() {}

    public mutating func recordDecision(endpointToDecisionMs: Int) {
        endpointToDecision.append(endpointToDecisionMs)
    }

    public mutating func recordFirstToken(decisionToFirstTokenMs: Int) {
        decisionToFirstToken.append(decisionToFirstTokenMs)
    }

    public mutating func recordOverride() {
        overrides += 1
    }

    public func snapshot() -> [String: Int] {
        var out = ["manual_override_count": overrides, "trigger_count": endpointToDecision.count]
        if !endpointToDecision.isEmpty {
            out["endpoint_to_decision_ms_median"] = Self.median(endpointToDecision)
            out["endpoint_to_decision_ms_p95"] = Self.p95(endpointToDecision)
        }
        if !decisionToFirstToken.isEmpty {
            out["decision_to_first_token_ms_median"] = Self.median(decisionToFirstToken)
        }
        return out
    }

    private static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        return sorted[(sorted.count - 1) / 2]
    }

    /// Nearest-rank 95th percentile.
    private static func p95(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up))
        return sorted[max(rank - 1, 0)]
    }
}
