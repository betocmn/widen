// Generates the placeholder app icon PNGs for Widen.
// Usage: swift scripts/make_icon.swift Widen/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let sizes = [16, 32, 64, 128, 256, 512, 1024]

for size in sizes {
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: size,
            pixelsHigh: size,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
    else {
        fatalError("Could not create bitmap for size \(size)")
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    let s = CGFloat(size)
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let inset = rect.insetBy(dx: s * 0.06, dy: s * 0.06)
    let path = NSBezierPath(roundedRect: inset, xRadius: s * 0.2, yRadius: s * 0.2)
    let gradient = NSGradient(
        colors: [
            NSColor(calibratedRed: 0.13, green: 0.25, blue: 0.62, alpha: 1),
            NSColor(calibratedRed: 0.10, green: 0.62, blue: 0.86, alpha: 1),
        ]
    )!
    gradient.draw(in: path, angle: -60)

    let title = "W" as NSString
    let font = NSFont.systemFont(ofSize: s * 0.52, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white,
    ]
    let ts = title.size(withAttributes: attrs)
    title.draw(
        at: NSPoint(x: (s - ts.width) / 2, y: (s - ts.height) / 2),
        withAttributes: attrs
    )

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG for size \(size)")
    }
    let url = URL(fileURLWithPath: "\(outDir)/icon_\(size).png")
    try! png.write(to: url)
    print("Wrote \(url.path)")
}
