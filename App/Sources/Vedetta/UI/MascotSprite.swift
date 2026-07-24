import SwiftUI
import VedettaKit

/// The guard cat: samples MascotFrame on every PixelClock tick so the
/// eyes scan/blink per state and the ears twitch right after an event.
struct MascotSprite: View {
    @ObservedObject private var clock = PixelClock.shared
    let state: SessionState
    var stateChangedAt: Date = .distantPast
    var color: Color
    var pixelSize: CGFloat = 2.5

    var body: some View {
        PixelSprite(
            pattern: MascotFrame.frame(
                state: state,
                now: clock.now,
                stateChangedAt: stateChangedAt,
                blinkOn: clock.blinkOn
            ),
            color: color,
            pixelSize: pixelSize
        )
    }
}
