import Foundation

/// Per-account quota sample and the push/pull merge policy: the freshest
/// sample wins wholesale; anything older than the tolerance is stale and
/// the UI must show its age, never a bare percentage.
public enum AccountQuota {
    public enum Origin: Equatable, Sendable { case push, pull }

    public struct Sample: Equatable, Sendable {
        public var fiveHour: QuotaWindow?
        public var sevenDay: QuotaWindow?
        public var meters: [UsageMeter]
        public var at: Date
        public var origin: Origin

        public init(
            fiveHour: QuotaWindow?, sevenDay: QuotaWindow?,
            meters: [UsageMeter] = [], at: Date, origin: Origin
        ) {
            self.fiveHour = fiveHour
            self.sevenDay = sevenDay
            self.meters = meters
            self.at = at
            self.origin = origin
        }
    }

    public static func merge(push: Sample?, pull: Sample?) -> Sample? {
        switch (push, pull) {
        case (nil, nil): return nil
        case (let sample?, nil): return sample
        case (nil, let sample?): return sample
        case (let push?, let pull?):
            // Freshest source drives the strip windows and staleness, but
            // the meters are UNIONED: the statusline (push) lacks the
            // per-model week that only the endpoint (pull) reports, so a
            // fresh push must not drop pull's richer meters.
            let fresher = push.at >= pull.at ? push : pull
            return Sample(
                fiveHour: fresher.fiveHour,
                sevenDay: fresher.sevenDay,
                meters: unionMeters(push, pull),
                at: fresher.at,
                origin: fresher.origin
            )
        }
    }

    /// Union of both samples' meters keyed by label: a shared meter takes
    /// the fresher sample's value; a meter only one source has (the
    /// per-model week) is kept. Ordered session → weekly-all → per-model.
    private static func unionMeters(_ a: Sample, _ b: Sample) -> [UsageMeter] {
        var chosen: [String: (meter: UsageMeter, at: Date)] = [:]
        for sample in [a, b] {
            for meter in sample.meters {
                if let existing = chosen[meter.label], existing.at >= sample.at { continue }
                chosen[meter.label] = (meter, sample.at)
            }
        }
        return chosen.values.map(\.meter).sorted { lhs, rhs in
            let (rankLHS, rankRHS) = (meterRank(lhs.label), meterRank(rhs.label))
            return rankLHS != rankRHS ? rankLHS < rankRHS : lhs.label < rhs.label
        }
    }

    private static func meterRank(_ label: String) -> Int {
        if label == "Current session" { return 0 }
        if label == "Current week (all models)" { return 1 }
        if label.hasPrefix("Current week") { return 2 }
        return 3
    }

    public static func isStale(
        _ sample: Sample?, now: Date, tolerance: TimeInterval = 600
    ) -> Bool {
        guard let sample else { return true }
        return now.timeIntervalSince(sample.at) > tolerance
    }
}

/// Pure poll scheduling for the opt-in oauth/usage probe: base interval,
/// per-account stagger, exponential backoff on 429 honoring Retry-After.
public struct UsagePollScheduler: Sendable {
    public static let baseInterval: TimeInterval = 300
    public static let stagger: TimeInterval = 20
    public static let backoffSteps: [TimeInterval] = [600, 1200, 1800]

    private var nextAllowedAt: [String: Date] = [:]
    private var backoffLevel: [String: Int] = [:]
    private let epochStart: Date

    public init(epochStart: Date = Date()) {
        self.epochStart = epochStart
    }

    public func shouldPoll(account: String, index: Int, now: Date) -> Bool {
        if let next = nextAllowedAt[account] { return now >= next }
        // Never polled: allow after the per-account stagger, so the
        // accounts never all hit the endpoint in the same instant.
        return now.timeIntervalSince(epochStart) >= Double(index) * Self.stagger
    }

    public mutating func recordSuccess(account: String, now: Date) {
        backoffLevel[account] = 0
        nextAllowedAt[account] = now.addingTimeInterval(Self.baseInterval)
    }

    public mutating func record429(account: String, retryAfter: TimeInterval?, now: Date) {
        let level = min(backoffLevel[account] ?? 0, Self.backoffSteps.count - 1)
        backoffLevel[account] = level + 1
        let backoff = Self.backoffSteps[level]
        nextAllowedAt[account] = now.addingTimeInterval(max(backoff, retryAfter ?? 0))
    }

    public mutating func recordFailure(account: String, now: Date) {
        nextAllowedAt[account] = now.addingTimeInterval(Self.baseInterval)
    }
}
