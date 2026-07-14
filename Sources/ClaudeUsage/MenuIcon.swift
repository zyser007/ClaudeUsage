import AppKit

/// Custom menu bar icon, loaded from Resources/MenuIcon.png in the app bundle.
/// Absent -> the app falls back to an SF Symbol, so a missing file degrades
/// visibly rather than showing an empty menu bar item.
enum MenuIcon {
    /// Menu bar items get ~18pt of height; leave a little breathing room.
    private static let targetHeight: CGFloat = 15

    /// Transparent gap baked onto the trailing edge, so the percentage doesn't
    /// crowd the artwork.
    ///
    /// It lives here rather than as `.padding()` on the label because
    /// MenuBarExtra collapses its label into an NSStatusItem's `image` and
    /// `title`, which silently drops SwiftUI padding. Padding the image is also
    /// exact in points, where a space character would vary with the menu bar
    /// font.
    private static let trailingGap: CGFloat = 4

    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuIcon", withExtension: "png"),
              let loaded = NSImage(contentsOf: url),
              let cg = loaded.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        // Artwork often has transparent padding around the subject. Scaling the
        // padded canvas to menu bar height shrinks the subject; trim first so it
        // fills the height.
        let cropped = trimTransparentEdges(cg) ?? cg

        let aspect = CGFloat(cropped.width) / CGFloat(cropped.height)
        let artWidth = (targetHeight * aspect).rounded()
        let img = NSImage(size: NSSize(width: artWidth + trailingGap, height: targetHeight),
                          flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current else { return false }
            // Nearest-neighbour here too — this draw is what rasterises the
            // artwork, so smoothing it now would blur the pixels before SwiftUI
            // ever sees the image.
            ctx.imageInterpolation = .none
            ctx.cgContext.draw(cropped,
                               in: CGRect(x: 0, y: 0, width: artWidth, height: targetHeight))
            return true
        }
        // Keep the artwork's own colors instead of flattening to a template.
        img.isTemplate = false
        return img
    }()

    /// Returns the image cropped to the bounding box of pixels with alpha > 0.
    /// nil when the image is fully transparent or can't be read.
    private static func trimTransparentEdges(_ cg: CGImage) -> CGImage? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }

        // Redraw into a known RGBA8 layout — the source may be palette-based,
        // 16-bit, or any other format CGImage supports.
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w * 4
            for x in 0..<w where pixels[row + x * 4 + 3] > 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }

        return cg.cropping(to: CGRect(x: minX, y: minY,
                                      width: maxX - minX + 1,
                                      height: maxY - minY + 1))
    }
}
