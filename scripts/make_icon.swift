// Generates the app icon PNGs for Widen from a square master image.
// Usage: swift scripts/make_icon.swift Widen/Assets.xcassets/AppIcon.appiconset [master.png]
import AppKit

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Widen/Assets.xcassets/AppIcon.appiconset"
let sourcePath = CommandLine.arguments.count > 2
    ? CommandLine.arguments[2]
    : "\(outDir)/icon_1024.png"
let sizes = [16, 32, 64, 128, 256, 512, 1024]

guard let source = NSImage(contentsOfFile: sourcePath) else {
    fatalError("Could not read master icon at \(sourcePath)")
}

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
    ctx.imageInterpolation = .high

    let rect = NSRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size))
    ctx.cgContext.clear(rect)
    source.draw(in: rect, from: .zero, operation: .copy, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("Could not encode PNG for size \(size)")
    }

    let url = URL(fileURLWithPath: "\(outDir)/icon_\(size).png")
    try! png.write(to: url)
    print("Wrote \(url.path)")
}
