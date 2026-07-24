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

    @Test func metersFromLimitsArray() {
        let json = """
        {"five_hour":{"utilization":18,"resets_at":"2026-07-24T15:50:00.09+00:00"},
         "seven_day":{"utilization":98,"resets_at":"2026-07-24T23:00:00.09+00:00"},
         "limits":[
           {"kind":"session","percent":18,"severity":"normal","resets_at":"2026-07-24T15:50:00.09+00:00"},
           {"kind":"weekly_all","percent":98,"severity":"critical","resets_at":"2026-07-24T23:00:00.09+00:00"},
           {"kind":"weekly_scoped","percent":77,"severity":"warning","resets_at":"2026-07-24T22:59:59.88+00:00",
            "scope":{"model":{"display_name":"Fable"}}}
         ]}
        """
        let parsed = RateLimitHarvest.parse(from: Data(json.utf8))
        #expect(parsed.meters.count == 3)
        #expect(parsed.meters[0].label == "Current session")
        #expect(parsed.meters[0].percent == 18)
        #expect(parsed.meters[0].severity == .normal)
        #expect(parsed.meters[0].resetsAt != nil)   // fractional ISO parsed
        #expect(parsed.meters[1].label == "Current week (all models)")
        #expect(parsed.meters[1].severity == .critical)
        #expect(parsed.meters[2].label == "Current week (Fable)")
        #expect(parsed.meters[2].percent == 77)
        #expect(parsed.meters[2].severity == .warning)
        // The condensed windows still populate for the strip.
        #expect(parsed.fiveHour?.percent == 18)
        #expect(parsed.sevenDay?.percent == 98)
    }

    @Test func metersFallBackToWindowsWithoutLimits() {
        // The statusline shape (no `limits` array): derive session + week.
        let json = """
        {"five_hour":{"used_percentage":17,"resets_at":1784908200},
         "seven_day":{"used_percentage":98,"resets_at":1784934000}}
        """
        let parsed = RateLimitHarvest.parse(from: Data(json.utf8))
        #expect(parsed.meters.count == 2)
        #expect(parsed.meters[0].label == "Current session")
        #expect(parsed.meters[0].percent == 17)
        #expect(parsed.meters[0].severity == .normal)
        #expect(parsed.meters[1].label == "Current week (all models)")
        #expect(parsed.meters[1].severity == .critical)   // 98% ≥ 80
    }
}
