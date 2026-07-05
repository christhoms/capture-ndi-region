// Compose the NDI Region app icon from the brand assets:
// the laptop mark with the dawg on screen, and a green region-selection
// marquee cropping the bottom strip — i.e. what the app does.
//
// Usage: swift Scripts/make-icon.swift   (writes Assets/logo_1024.png)
import AppKit

let projectDir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let assets = projectDir.appendingPathComponent("Assets")

guard
    let laptop = NSImage(contentsOf: assets.appendingPathComponent("chris_laptop_icon.png")),
    let dawg = NSImage(contentsOf: assets.appendingPathComponent("DAWG.png"))
else {
    fputs("error: missing source images in Assets/\n", stderr)
    exit(1)
}

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: 1024, height: 1024)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: ~824pt content centered in the 1024 canvas.
let content = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: content, xRadius: 186, yRadius: 186)
NSGradient(
    starting: NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.18, alpha: 1),
    ending: NSColor(calibratedRed: 0.02, green: 0.03, blue: 0.05, alpha: 1)
)!.draw(in: squircle, angle: -90)

squircle.addClip()

// Laptop mark, centered.
let laptopW: CGFloat = 700
let laptopH = laptopW * laptop.size.height / laptop.size.width  // 539x467 source
let laptopRect = NSRect(
    x: (1024 - laptopW) / 2, y: (1024 - laptopH) / 2 - 20,
    width: laptopW, height: laptopH
)
laptop.draw(in: laptopRect, from: .zero, operation: .sourceOver, fraction: 1)

// The black screen area of the laptop mark, as fractions of the source image.
let screen = NSRect(
    x: laptopRect.minX + 0.130 * laptopW,
    y: laptopRect.minY + (1 - 0.770) * laptopH,
    width: (0.862 - 0.130) * laptopW,
    height: (0.770 - 0.280) * laptopH
)

// Dawg on screen, fitted to screen height.
NSGraphicsContext.current?.saveGraphicsState()
NSBezierPath(rect: screen).addClip()
let dawgH = screen.height * 1.06
let dawgW = dawgH * dawg.size.width / dawg.size.height  // 419x720 source
dawg.draw(
    in: NSRect(x: screen.midX - dawgW / 2, y: screen.minY, width: dawgW, height: dawgH),
    from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.current?.restoreGraphicsState()

// Region-selection marquee over the bottom strip of the screen.
let marquee = NSRect(
    x: screen.minX + 6, y: screen.minY + 14,
    width: screen.width - 12, height: screen.height * 0.40
)
let green = NSColor(calibratedRed: 0.22, green: 0.90, blue: 0.50, alpha: 1)
green.withAlphaComponent(0.16).setFill()
NSBezierPath(rect: marquee).fill()

let dash = NSBezierPath(rect: marquee)
dash.lineWidth = 9
dash.setLineDash([26, 16], count: 2, phase: 0)
green.setStroke()
dash.stroke()

// Corner handles.
green.setFill()
for corner in [
    NSPoint(x: marquee.minX, y: marquee.minY), NSPoint(x: marquee.maxX, y: marquee.minY),
    NSPoint(x: marquee.minX, y: marquee.maxY), NSPoint(x: marquee.maxX, y: marquee.maxY),
] {
    NSBezierPath(rect: NSRect(x: corner.x - 14, y: corner.y - 14, width: 28, height: 28)).fill()
}

NSGraphicsContext.restoreGraphicsState()

let out = assets.appendingPathComponent("logo_1024.png")
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("Wrote \(out.path)")
