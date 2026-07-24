// Renders the DMG background: black starfield, a pixel arrow between the
// two icons, and a typewriter caption. 1200×800 px tagged 144 dpi (renders
// as 600×400 pt). Usage: swift render-dmg-bg.swift out.png
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let W = 1200, H = 800
let context = CGContext(
    data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// notte
context.setFillColor(CGColor(red: 0.016, green: 0.027, blue: 0.016, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: W, height: H))

// starfield deterministico (stesso LCG di StarfieldView)
var seed: UInt64 = 0x5EED_CAFE
func next() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
}
for _ in 0..<70 {
    let x = next() * CGFloat(W)
    let y = next() * CGFloat(H)
    let side: CGFloat = next() > 0.72 ? 4 : 2.6
    let alpha = 0.2 + Double(next()) * 0.5
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
    context.fill(CGRect(x: x, y: y, width: side, height: side))
}

// freccia pixel verde tra le due icone (posizionate a ~300 e ~900 px)
let green = CGColor(red: 0.42, green: 0.78, blue: 0.48, alpha: 1)
let b: CGFloat = 22
let ay = CGFloat(H) * 0.54
let ax = CGFloat(W) / 2 - b * 3.1
context.setShadow(offset: .zero, blur: 16, color: CGColor(red: 0.42, green: 0.78, blue: 0.48, alpha: 0.8))
context.setFillColor(green)
for i in 0..<3 {
    context.fill(CGRect(x: ax + CGFloat(i) * b * 1.25, y: ay, width: b, height: b))
}
let hx = ax + 3 * b * 1.25
context.fill(CGRect(x: hx, y: ay - b * 1.25, width: b, height: b))
context.fill(CGRect(x: hx, y: ay, width: b, height: b))
context.fill(CGRect(x: hx, y: ay + b * 1.25, width: b, height: b))
context.fill(CGRect(x: hx + b * 1.25, y: ay, width: b, height: b))
context.setShadow(offset: .zero, blur: 0, color: nil)

// riga typewriter in basso, centrata
let ns = NSGraphicsContext(cgContext: context, flipped: false)
NSGraphicsContext.current = ns
let attrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 28, weight: .regular),
    .foregroundColor: NSColor(white: 1, alpha: 0.55),
]
let caption = NSAttributedString(string: "> drag to install _", attributes: attrs)
let captionSize = caption.size()
caption.draw(at: NSPoint(x: (CGFloat(W) - captionSize.width) / 2, y: CGFloat(H) * 0.10))
NSGraphicsContext.current = nil

// PNG a 144 dpi
let image = context.makeImage()!
let url = URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL
let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
let props: [CFString: Any] = [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144]
CGImageDestinationAddImage(destination, image, props as CFDictionary)
CGImageDestinationFinalize(destination)
