import Foundation
import Testing
@testable import VedettaKit

struct MascotFrameTests {
    private let calm = Date.distantPast   // nessun twitch in corso

    @Test func patternsAreEightBySeven() {
        for pattern in [MascotFrame.base, MascotFrame.lookLeft, MascotFrame.lookRight,
                        MascotFrame.wideEyes, MascotFrame.closedEyes, MascotFrame.twitch] {
            #expect(pattern.count == 7)
            #expect(pattern.allSatisfy { $0.count == 8 })
        }
    }

    @Test func runningScansLeftCenterRight() {
        // tick k = now / 0.36; la sequenza è [base, sx, base, dx]
        let expected = [MascotFrame.base, MascotFrame.lookLeft,
                        MascotFrame.base, MascotFrame.lookRight]
        for k in 0..<4 {
            let now = Date(timeIntervalSinceReferenceDate: Double(k) * 0.36 + 0.01)
            let frame = MascotFrame.frame(state: .running, now: now,
                                          stateChangedAt: calm, blinkOn: true)
            #expect(frame == expected[k])
        }
    }

    @Test func compactingScansLikeRunning() {
        let now = Date(timeIntervalSinceReferenceDate: 0.37)
        let frame = MascotFrame.frame(state: .compacting, now: now,
                                      stateChangedAt: calm, blinkOn: true)
        #expect(frame == MascotFrame.lookLeft)
    }

    @Test func waitingBlinksBetweenOpenAndClosed() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        #expect(MascotFrame.frame(state: .waitingForInput, now: now,
                                  stateChangedAt: calm, blinkOn: true) == MascotFrame.base)
        #expect(MascotFrame.frame(state: .waitingForInput, now: now,
                                  stateChangedAt: calm, blinkOn: false) == MascotFrame.closedEyes)
    }

    @Test func approvalIsWideEyed() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        #expect(MascotFrame.frame(state: .needsApproval, now: now,
                                  stateChangedAt: calm, blinkOn: true) == MascotFrame.wideEyes)
    }

    @Test func completedSleeps() {
        let now = Date(timeIntervalSinceReferenceDate: 100)
        #expect(MascotFrame.frame(state: .completed, now: now,
                                  stateChangedAt: calm, blinkOn: true) == MascotFrame.closedEyes)
    }

    @Test func twitchBurstsTwiceAfterAStateChange() {
        let changed = Date(timeIntervalSinceReferenceDate: 100)
        func frame(after dt: TimeInterval) -> [String] {
            MascotFrame.frame(state: .running, now: changed.addingTimeInterval(dt),
                              stateChangedAt: changed, blinkOn: true)
        }
        #expect(frame(after: 0.05) == MascotFrame.twitch)    // primo burst
        #expect(frame(after: 0.20) != MascotFrame.twitch)    // pausa tra i burst
        #expect(frame(after: 0.35) == MascotFrame.twitch)    // secondo burst
        #expect(frame(after: 0.50) != MascotFrame.twitch)    // finestra chiusa
    }

    @Test func completedNeverTwitches() {
        let changed = Date(timeIntervalSinceReferenceDate: 100)
        let frame = MascotFrame.frame(state: .completed,
                                      now: changed.addingTimeInterval(0.05),
                                      stateChangedAt: changed, blinkOn: true)
        #expect(frame == MascotFrame.closedEyes)
    }
}
