import Testing
@testable import VedettaKit

struct IndicatorFramesTests {
    @Test func ringHasEightCellsClockwise() {
        #expect(IndicatorFrames.ring.count == 8)
        #expect(IndicatorFrames.ring[0].x == 0 && IndicatorFrames.ring[0].y == 0)
        #expect(IndicatorFrames.ring[4].x == 2 && IndicatorFrames.ring[4].y == 2)
    }

    @Test func dualChaseHasTwoOppositeHeads() {
        // A tick 0 le teste sono alle posizioni 0 e 4 (alpha piena).
        #expect(IndicatorFrames.dualChaseAlpha(index: 0, tick: 0) == 1.0)
        #expect(IndicatorFrames.dualChaseAlpha(index: 4, tick: 0) == 1.0)
        // Una cella dietro ciascuna testa: alpha 0.7.
        #expect(abs(IndicatorFrames.dualChaseAlpha(index: 1, tick: 0) - 0.7) < 0.001)
        #expect(abs(IndicatorFrames.dualChaseAlpha(index: 5, tick: 0) - 0.7) < 0.001)
        // Equidistante dalle due teste (d=2): alpha 0.4.
        #expect(abs(IndicatorFrames.dualChaseAlpha(index: 2, tick: 0) - 0.4) < 0.001)
    }

    @Test func dualChaseAdvancesWithTick() {
        #expect(IndicatorFrames.dualChaseAlpha(index: 1, tick: 1) == 1.0)
        #expect(IndicatorFrames.dualChaseAlpha(index: 5, tick: 1) == 1.0)
    }

    @Test func squashCyclesThroughHeights() {
        #expect((0...5).map { IndicatorFrames.squashRowCount(tick: $0) } == [4, 3, 2, 1, 2, 3])
        #expect(IndicatorFrames.squashRowCount(tick: 6) == 4)   // il ciclo riparte
    }
}
