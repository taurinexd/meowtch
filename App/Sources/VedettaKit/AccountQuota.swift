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
        case (let push?, let pull?): return push.at >= pull.at ? push : pull
        }
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
