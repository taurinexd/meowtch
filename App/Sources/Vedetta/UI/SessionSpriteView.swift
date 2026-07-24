import SwiftUI
import VedettaKit

/// The session sprite slot: the user's per-state GIF when custom sprites
/// are enabled and the file exists, the guard cat otherwise. No tint on
/// GIFs — state color stays on indicators and text.
struct SessionSpriteView: View {
    let state: SessionState
    var stateChangedAt: Date = .distantPast
    var color: Color
    var pixelSize: CGFloat
    @AppStorage(CustomSpriteLibrary.enabledKey) private var customEnabled = false

    var body: some View {
        if customEnabled, let url = CustomSpriteLibrary.standard.url(for: state) {
            AnimatedImageView(url: url, targetHeight: 7 * pixelSize)
                .id(url)
        } else {
            MascotSprite(
                state: state,
                stateChangedAt: stateChangedAt,
                color: color,
                pixelSize: pixelSize
            )
        }
    }
}
