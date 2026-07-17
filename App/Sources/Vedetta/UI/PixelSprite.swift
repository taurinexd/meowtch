import SwiftUI

/// Tiny bitmap sprite drawn from a string pattern — Vedetta's 8-bit mascot.
/// `#` = lit pixel, anything else = transparent.
/// Matches the original's rendering: each pixel is a slightly inset square
/// (thin dark grid gaps between pixels) and the whole glyph emits a subtle
/// glow of its own color.
struct PixelSprite: View {
    var pattern: [String]
    var color: Color
    var pixelSize: CGFloat = 2.5
    /// Fraction of the cell left as a gap between pixels (grid texture).
    var gapRatio: CGFloat = 0.14
    var glow: Bool = true

    static let lookout: [String] = [
        ".#....#.",
        "..####..",
        ".######.",
        "##.##.##",
        "########",
        "..#..#..",
        ".#....#.",
    ]

    var body: some View {
        Canvas { context, _ in
            let inset = pixelSize * gapRatio / 2
            for (row, line) in pattern.enumerated() {
                for (col, char) in line.enumerated() where char == "#" {
                    let rect = CGRect(
                        x: CGFloat(col) * pixelSize + inset,
                        y: CGFloat(row) * pixelSize + inset,
                        width: pixelSize - inset * 2,
                        height: pixelSize - inset * 2
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(
            width: CGFloat(pattern.first?.count ?? 0) * pixelSize,
            height: CGFloat(pattern.count) * pixelSize
        )
        // View-level shadow: it follows the glyph silhouette and is not
        // clipped at the canvas bounds, matching the original's bloom.
        .shadow(color: glow ? color.opacity(0.8) : .clear, radius: pixelSize * 1.4)
    }
}
