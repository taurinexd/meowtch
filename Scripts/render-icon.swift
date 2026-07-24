// Renders Vedetta's app icon: the guard cat under a pixel starfield on a
// dark rounded tile. Usage: swift render-icon.swift out.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
// The guard cat (MascotFrame.base). '#' = lit pixel; 'o'/'.' transparent.
let sprite = [
    ".#....#.",
    ".##..##.",
    ".######.",
    ".#o##o#.",
    ".######.",
    "..####..",
    "..#..#..",
]

let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// tile scuro con angoli macOS
let inset = CGFloat(size) * 0.09
let tile = CGRect(x: inset, y: inset, width: CGFloat(size) - inset * 2, height: CGFloat(size) - inset * 2)
let path = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.22, cornerHeight: tile.width * 0.22, transform: nil)
context.addPath(path)
context.setFillColor(CGColor(red: 0.047, green: 0.055, blue: 0.047, alpha: 1))
context.fillPath()

context.saveGState()
context.addPath(path)
context.clip()

// starfield deterministico (stesso LCG di StarfieldView)
var seed: UInt64 = 0x5EED_CAFE
func next() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
}
for _ in 0..<24 {
    let x = tile.minX + next() * tile.width
    let y = tile.minY + next() * tile.height
    let side = (next() > 0.72 ? 2.2 : 1.4) * CGFloat(size) / 128
    let alpha = 0.2 + Double(next()) * 0.3
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
    context.fill(CGRect(x: x, y: y, width: side, height: side))
}

// gatto centrato con glow
let columns = sprite[0].count, rows = sprite.count
let pixel = tile.width * 0.68 / CGFloat(columns)
let originX = tile.midX - pixel * CGFloat(columns) / 2
let originY = tile.midY - pixel * CGFloat(rows) / 2
let green = CGColor(red: 0.42, green: 0.78, blue: 0.48, alpha: 1)
context.setShadow(offset: .zero, blur: pixel * 1.1, color: CGColor(red: 0.42, green: 0.78, blue: 0.48, alpha: 0.85))
context.setFillColor(green)
for (row, line) in sprite.enumerated() {
    for (col, char) in line.enumerated() where char == "#" {
        let rect = CGRect(
            x: originX + CGFloat(col) * pixel + pixel * 0.06,
            y: originY + CGFloat(rows - 1 - row) * pixel + pixel * 0.06,
            width: pixel * 0.88, height: pixel * 0.88
        )
        context.fill(rect)
    }
}
context.restoreGState()

let image = context.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
