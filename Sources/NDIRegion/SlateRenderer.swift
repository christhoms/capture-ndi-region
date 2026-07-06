import AppKit
import CoreGraphics
import RegionCore

/// The placeholder frame sent while a feed's window is gone: the studio dawg
/// on a dark card, so anyone watching the NDI output knows the feed is being
/// held, not broken.
struct SlateFrame {
    let pixels: Data  // BGRA, top line first
    let width: Int
    let height: Int
    let bytesPerRow: Int

    func send(via sender: NDISender, fps: Int32) {
        // NDI's sync send only reads the buffer; the mutable pointer is just
        // the C signature.
        pixels.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            sender.send(
                pixels: UnsafeMutableRawPointer(mutating: base),
                width: width, height: height, bytesPerRow: bytesPerRow, fpsN: fps, fpsD: 1)
        }
    }
}

enum SlateRenderer {
    /// Render at the feed's last output size so receivers don't see a
    /// resolution change when the slate takes over.
    static func render(
        width: Int, height: Int, title: String, subtitle: String, image: NSImage?
    ) -> SlateFrame {
        // Even dimensions with a sane floor, same rule as live capture.
        let w = max(320, (width / 2) * 2)
        let h = max(180, (height / 2) * 2)
        let bytesPerRow = w * 4
        var pixels = Data(count: bytesPerRow * h)

        pixels.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let cg = CGContext(
                      data: base, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }

            cg.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1))
            cg.fill(CGRect(x: 0, y: 0, width: w, height: h))

            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
            defer { NSGraphicsContext.current = previous }

            let fw = CGFloat(w)
            let fh = CGFloat(h)

            // The slate image (the dawg, or the user's own), centered in the
            // upper part of the frame.
            if let image, image.size.height > 0 {
                let boxHeight = fh * 0.42
                let aspect = image.size.width / image.size.height
                let drawWidth = min(boxHeight * aspect, fw * 0.6)
                let drawHeight = drawWidth / aspect
                image.draw(
                    in: CGRect(
                        x: (fw - drawWidth) / 2, y: fh * 0.40,
                        width: drawWidth, height: drawHeight),
                    from: .zero, operation: .sourceOver, fraction: 1.0)
            }

            drawCentered(
                title,
                font: .systemFont(ofSize: fh * 0.075, weight: .bold),
                color: .white, centerY: fh * 0.30, frameWidth: fw)
            drawCentered(
                subtitle,
                font: .systemFont(ofSize: fh * 0.045, weight: .regular),
                color: NSColor(white: 1, alpha: 0.65), centerY: fh * 0.19, frameWidth: fw)
        }

        return SlateFrame(pixels: pixels, width: w, height: h, bytesPerRow: bytesPerRow)
    }

    private static func drawCentered(
        _ text: String, font: NSFont, color: NSColor, centerY: CGFloat, frameWidth: CGFloat
    ) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        string.draw(at: CGPoint(x: (frameWidth - size.width) / 2, y: centerY - size.height / 2))
    }
}
