import Foundation
import Testing
@testable import VedettaKit

struct AccountQuotaTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private func sample(_ origin: AccountQuota.Origin, at: Date) -> AccountQuota.Sample {
        AccountQuota.Sample(
            fiveHour: QuotaWindow(percent: 10), sevenDay: nil, at: at, origin: origin
        )
    }

    @Test func freshestSampleWins() {
        let push = sample(.push, at: t0)
        let pull = sample(.pull, at: t0.addingTimeInterval(60))
        #expect(AccountQuota.merge(push: push, pull: pull)?.origin == .pull)
        #expect(AccountQuota.merge(push: pull, pull: push)?.origin == .pull)
        #expect(AccountQuota.merge(push: push, pull: nil)?.origin == .push)
        #expect(AccountQuota.merge(push: nil, pull: nil) == nil)
    }

    @Test func mergeUnionsMetersKeepingRicherAndFresher() {
        let sessionFresh = UsageMeter(label: "Current session", percent: 19, resetsAt: nil, severity: .normal)
        let sessionOld = UsageMeter(label: "Current session", percent: 18, resetsAt: nil, severity: .normal)
        let weekly = UsageMeter(label: "Current week (all models)", percent: 99, resetsAt: nil, severity: .critical)
        let fable = UsageMeter(label: "Current week (Fable)", percent: 77, resetsAt: nil, severity: .warning)
        // push is fresher but only 2 meters (no per-model); pull is older
        // but has the Fable meter.
        let push = AccountQuota.Sample(
            fiveHour: nil, sevenDay: nil, meters: [sessionFresh, weekly],
            at: t0.addingTimeInterval(60), origin: .push
        )
        let pull = AccountQuota.Sample(
            fiveHour: nil, sevenDay: nil, meters: [sessionOld, weekly, fable],
            at: t0, origin: .pull
        )
        let merged = AccountQuota.merge(push: push, pull: pull)
        #expect(merged?.meters.map(\.label) == [
            "Current session", "Current week (all models)", "Current week (Fable)",
        ])
        // Session takes the fresher push value; Fable survives from pull.
        #expect(merged?.meters.first?.percent == 19)
        #expect(merged?.meters.last?.percent == 77)
    }

    @Test func staleness() {
        let fresh = sample(.push, at: t0)
        #expect(!AccountQuota.isStale(fresh, now: t0.addingTimeInterval(300)))
        #expect(AccountQuota.isStale(fresh, now: t0.addingTimeInterval(601)))
        #expect(AccountQuota.isStale(nil, now: t0))
    }

    @Test func schedulerStaggersFirstPolls() {
        let scheduler = UsagePollScheduler(epochStart: t0)
        let a = "acc-a", b = "acc-b"
        #expect(scheduler.shouldPoll(account: a, index: 0, now: t0))
        #expect(!scheduler.shouldPoll(account: b, index: 1, now: t0))          // stagger 20s
        #expect(scheduler.shouldPoll(account: b, index: 1, now: t0.addingTimeInterval(21)))
    }

    @Test func schedulerBaseIntervalAfterSuccess() {
        var scheduler = UsagePollScheduler(epochStart: t0)
        let a = "acc-a"
        scheduler.recordSuccess(account: a, now: t0)
        #expect(!scheduler.shouldPoll(account: a, index: 0, now: t0.addingTimeInterval(299)))
        #expect(scheduler.shouldPoll(account: a, index: 0, now: t0.addingTimeInterval(301)))
    }

    @Test func schedulerBacksOffOn429() {
        var scheduler = UsagePollScheduler(epochStart: t0)
        let a = "acc-a"
        // 429 senza Retry-After → 600, poi 1200, poi cap 1800.
        scheduler.record429(account: a, retryAfter: nil, now: t0)
        #expect(!scheduler.shouldPoll(account: a, index: 0, now: t0.addingTimeInterval(599)))
        #expect(scheduler.shouldPoll(account: a, index: 0, now: t0.addingTimeInterval(601)))
        scheduler.record429(account: a, retryAfter: nil, now: t0)
        #expect(!scheduler.shouldPoll(account: a, index: 0, now: t0.addingTimeInterval(1199)))
        scheduler.record429(account: a, retryAfter: nil, now: t0)
        scheduler.record429(account: a, retryAfter: nil, now: t0)
        #expect(!scheduler.shouldPoll(account: a, index: 0, now: t0.addingTimeInterval(1799)))
        #expect(scheduler.shouldPoll(account: a, index: 0, now: t0.addingTimeInterval(1801)))
        // Retry-After più lungo del backoff vince.
        scheduler.record429(account: a, retryAfter: 3600, now: t0)
        #expect(!scheduler.shouldPoll(account: a, index: 0, now: t0.addingTimeInterval(1801)))
        #expect(scheduler.shouldPoll(account: a, index: 0, now: t0.addingTimeInterval(3601)))
        // Un successo azzera il backoff.
        scheduler.recordSuccess(account: a, now: t0)
        scheduler.record429(account: a, retryAfter: nil, now: t0)
        #expect(scheduler.shouldPoll(account: a, index: 0, now: t0.addingTimeInterval(601)))
    }

    // MARK: - Shared-slot push attribution

    private func push(_ percent: Int, resets: TimeInterval, at: Date) -> AccountQuota.Sample {
        AccountQuota.Sample(
            fiveHour: QuotaWindow(percent: percent, resetsAt: Date(timeIntervalSince1970: resets)),
            sevenDay: nil, at: at, origin: .push
        )
    }

    @Test func slotPushWithoutAHandoverIsTheOwners() {
        let fresh = push(14, resets: 1_792_355_400, at: t0)
        #expect(AccountQuota.slotPushBelongsToOwner(fresh, handoverAt: nil, snapshot: nil))
    }

    @Test func slotPushInsideTheGraceWindowIsDropped() {
        // Open sessions keep their Keychain read cached for 30s: a reply
        // landing right after the switch was still served by the old
        // account's token.
        let early = push(20, resets: 1_792_364_400, at: t0.addingTimeInterval(30))
        #expect(!AccountQuota.slotPushBelongsToOwner(early, handoverAt: t0, snapshot: nil))
        let late = push(20, resets: 1_792_364_400, at: t0.addingTimeInterval(60))
        #expect(AccountQuota.slotPushBelongsToOwner(late, handoverAt: t0, snapshot: nil))
    }

    @Test func slotPushRepeatingThePreviousOwnersWindowsIsDropped() {
        // The bug seen live on 2026-10-18: the same 14% re-credited to
        // claude-1, -2 and -3 in turn. A push identical to what the drop
        // held at the handover is the old owner's numbers re-rendered.
        let snapshot = ParsedUsage(
            fiveHour: QuotaWindow(percent: 14, resetsAt: Date(timeIntervalSince1970: 1_792_355_400)),
            sevenDay: nil, meters: []
        )
        let leftover = push(14, resets: 1_792_355_400, at: t0.addingTimeInterval(600))
        #expect(!AccountQuota.slotPushBelongsToOwner(leftover, handoverAt: t0, snapshot: snapshot))
        let own = push(0, resets: 1_792_364_400, at: t0.addingTimeInterval(600))
        #expect(AccountQuota.slotPushBelongsToOwner(own, handoverAt: t0, snapshot: snapshot))
    }
}

struct UsageColumnsTests {
    private func meter(_ label: String) -> UsageMeter {
        UsageMeter(label: label, percent: 0, resetsAt: nil, severity: .normal)
    }

    @Test func columnsUnionAccountsInMeterOrder() {
        let tech = [meter("Current week (all models)"), meter("Current week (Fable)")]
        let dev = [meter("Current session"), meter("Current week (Opus)"), meter("Current week (all models)")]
        #expect(AccountQuota.columns(for: [tech, [], dev]) == [
            "Current session", "Current week (all models)",
            "Current week (Fable)", "Current week (Opus)",
        ])
        #expect(AccountQuota.columns(for: [[], []]).isEmpty)
    }

    @Test func columnTitlesAreShort() {
        #expect(AccountQuota.columnTitle("Current session") == "SESSION 5H")
        #expect(AccountQuota.columnTitle("Current week (all models)") == "WEEK 7D")
        #expect(AccountQuota.columnTitle("Current week (Fable)") == "FABLE 7D")
        #expect(AccountQuota.columnTitle("Something else") == "SOMETHING ELSE")
    }
}
