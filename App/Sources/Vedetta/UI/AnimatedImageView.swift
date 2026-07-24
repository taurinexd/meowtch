import AppKit
import SwiftUI

/// Animated GIF for custom sprites: NSImageView animates GIFs natively.
/// Height-capped with preserved aspect, never upscaled past the image's
/// own pixel height.
struct AnimatedImageView: NSViewRepresentable {
    let url: URL
    let targetHeight: CGFloat

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.animates = true
        view.imageScaling = .scaleProportionallyDown
        view.image = NSImage(contentsOf: url)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image?.name() == nil { view.image = NSImage(contentsOf: url) }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize, nsView: NSImageView, context: Context
    ) -> CGSize? {
        guard let size = nsView.image?.size, size.height > 0 else {
            return CGSize(width: targetHeight, height: targetHeight)
        }
        let height = min(targetHeight, size.height)
        return CGSize(width: size.width * height / size.height, height: height)
    }
}
