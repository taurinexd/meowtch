import SwiftUI

/// Tiny bitmap sprite drawn from a string pattern — Vedetta's 8-bit mascot.
/// `#` = lit pixel, anything else = transparent.
struct PixelSprite: View {
    var pattern: [String]
    var color: Color
    var pixelSize: CGFloat = 2.5

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
            for (row, line) in pattern.enumerated() {
                for (col, char) in line.enumerated() where char == "#" {
                    let rect = CGRect(
                        x: CGFloat(col) * pixelSize,
                        y: CGFloat(row) * pixelSize,
                        width: pixelSize,
                        height: pixelSize
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(
            width: CGFloat(pattern.first?.count ?? 0) * pixelSize,
            height: CGFloat(pattern.count) * pixelSize
        )
    }
}
