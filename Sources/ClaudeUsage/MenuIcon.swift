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

    /// Headroom for the hop. The canvas is this much taller than the art, and
    /// the art rests centred in it, so a resting frame sits exactly where a
    /// plain icon would.
    ///
    /// Centring costs half the headroom, so the highest usable lift is
    /// `bounceHeight / 2` — ask for more and the top of the art is silently
    /// clipped and the extra frames come out identical. Must stay under the
    /// ~22pt a status item gets, or macOS scales the artwork down.
    private static let bounceHeight: CGFloat = 4

    /// How far the art is lifted in each frame, in pixels.
    ///
    /// Integers only: the art is nearest-neighbour scaled pixel art, and a
    /// fractional lift would smear the very edges we went to trouble to keep
    /// hard. The trailing zeros are a beat of rest, so a repeat reads as a hop
    /// rather than a vibration.
    static let bounceSequence: [CGFloat] = [0, 1, 2, 2, 1, 0, 0, 0]

    /// The resting frame — what the menu bar shows when nothing is happening.
    static var image: NSImage? { frames.first }

    /// One image per bounce step, rendered once at startup.
    ///
    /// Pre-rendered because the alternative is rasterising artwork on every
    /// animation tick, and this runs in the menu bar of an app whose whole point
    /// is to be cheap to leave running.
    static let frames: [NSImage] = {
        guard let url = Bundle.main.url(forResource: "MenuIcon", withExtension: "png"),
              let loaded = NSImage(contentsOf: url),
              let cg = loaded.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return [] }

        // Artwork often has transparent padding around the subject. Scaling the
        // padded canvas to menu bar height shrinks the subject; trim first so it
        // fills the height.
        let cropped = trimTransparentEdges(cg) ?? cg

        let aspect = CGFloat(cropped.width) / CGFloat(cropped.height)
        let artWidth = (targetHeight * aspect).rounded()
        let size = NSSize(width: artWidth + trailingGap, height: targetHeight + bounceHeight)

        return bounceSequence.map { lift in
            let img = NSImage(size: size, flipped: false) { _ in
                guard let ctx = NSGraphicsContext.current else { return false }
                // Nearest-neighbour here too — this draw is what rasterises the
                // artwork, so smoothing it now would blur the pixels before
                // SwiftUI ever sees the image.
                ctx.imageInterpolation = .none
                ctx.cgContext.draw(cropped, in: CGRect(x: 0,
                                                       y: bounceHeight / 2 + lift,
                                                       width: artWidth,
                                                       height: targetHeight))
                return true
            }
            // Keep the artwork's own colors instead of flattening to a template.
            img.isTemplate = false
            return img
        }
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
