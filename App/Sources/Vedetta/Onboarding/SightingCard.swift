import SwiftUI

/// The shareable pixel-art postcard — a "sighting report" from the lookout.
/// One of a handful of phosphor palettes; shuffle re-rolls it. Rendered
/// identically on screen and through ImageRenderer for the PNG export.
struct SightingPalette: Equatable {
    let name: String
    let sprite: Color
    let sky: Color
    let ink: Color

    static let all: [SightingPalette] = [
        SightingPalette(
            name: "PHOSPHOR",
            sprite: Color(red: 0.42, green: 0.95, blue: 0.5),
            sky: Color(red: 0.03, green: 0.08, blue: 0.05),
            ink: Color(red: 0.66, green: 1.0, blue: 0.72)
        ),
        SightingPalette(
            name: "AMBER",
            sprite: Color(red: 1.0, green: 0.72, blue: 0.25),
            sky: Color(red: 0.09, green: 0.05, blue: 0.02),
            ink: Color(red: 1.0, green: 0.84, blue: 0.55)
        ),
        SightingPalette(
            name: "ICE",
            sprite: Color(red: 0.55, green: 0.85, blue: 1.0),
            sky: Color(red: 0.02, green: 0.05, blue: 0.10),
            ink: Color(red: 0.75, green: 0.92, blue: 1.0)
        ),
        SightingPalette(
            name: "SIGNAL",
            sprite: Color(red: 1.0, green: 0.45, blue: 0.65),
            sky: Color(red: 0.08, green: 0.02, blue: 0.06),
            ink: Color(red: 1.0, green: 0.7, blue: 0.82)
        ),
        SightingPalette(
            name: "VIOLET",
            sprite: Color(red: 0.75, green: 0.6, blue: 1.0),
            sky: Color(red: 0.05, green: 0.03, blue: 0.10),
            ink: Color(red: 0.85, green: 0.76, blue: 1.0)
        ),
    ]
}

struct SightingCard: View {
    let palette: SightingPalette
    /// Fixed at first render so the exported card matches the screen.
    let sightedOn: String

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                palette.sky
                StarfieldView(driftSpeed: 0.6, starCount: 60, tint: palette.ink)
                VStack(spacing: 14) {
                    PixelSprite(pattern: PixelSprite.lookout, color: palette.sprite, pixelSize: 9)
                    Text("SIGHTING CONFIRMED")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .kerning(3)
                        .foregroundStyle(palette.ink)
                }
            }
            .frame(height: 190)

            VStack(alignment: .leading, spacing: 5) {
                Text("> lookout posted to the notch")
                Text("> watching: claude code · codex")
                Text("> sighted \(sightedOn) · \(palette.name)")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(palette.ink.opacity(0.85))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.black)
        }
        .frame(width: 340)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(palette.sprite.opacity(0.55), lineWidth: 1.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: palette.sprite.opacity(0.25), radius: 18)
    }
}
