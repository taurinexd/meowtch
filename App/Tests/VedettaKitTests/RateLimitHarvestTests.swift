import Foundation
import Testing
@testable import VedettaKit

struct RateLimitHarvestTests {
    @Test func parsesStatuslineShape() {
        let json = """
        {"five_hour":{"used_percentage":42,"resets_at":"2026-07-24T15:00:00Z"},
         "seven_day":{"used_percentage":81,"resets_at":"2026-07-28T00:00:00Z"}}
        """
        let result = RateLimitHarvest.windows(from: Data(json.utf8))
        #expect(result.fiveHour?.percent == 42)
        #expect(result.sevenDay?.percent == 81)
        #expect(result.fiveHour?.resetsAt != nil)
    }

    @Test func parsesOAuthUsageShape() {
        let json = """
        {"five_hour":{"utilization":12,"resets_at":"2026-07-24T15:00:00Z"},
         "seven_day":{"utilization":63,"resets_at":"2026-07-28T00:00:00Z"},
         "seven_day_opus":{"utilization":5,"resets_at":"2026-07-28T00:00:00Z"}}
        """
        let result = RateLimitHarvest.windows(from: Data(json.utf8))
        #expect(result.fiveHour?.percent == 12)
        #expect(result.sevenDay?.percent == 63)
    }

    @Test func parsesEpochResetAndNestedKeys() {
        let json = """
        {"rate_limits":{"primary":{"used_percent":9,"resets_at":1753350000}}}
        """
        let result = RateLimitHarvest.windows(from: Data(json.utf8))
        #expect(result.fiveHour?.percent == 9)
        #expect(result.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_753_350_000))
        #expect(result.sevenDay == nil)
    }

    @Test func garbageYieldsNothing() {
        let result = RateLimitHarvest.windows(from: Data("not json".utf8))
        #expect(result.fiveHour == nil && result.sevenDay == nil)
    }
}
