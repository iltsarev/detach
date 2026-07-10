// Renders the Detach app icon into an .iconset directory.
// Usage: swift render-icon.swift <output.iconset>

import AppKit

let variants: [(pixels: Int, name: String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

func draw(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024.0

    // Squircle plate with a soft shadow, macOS-style margins.
    let plateRect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let plate = NSBezierPath(roundedRect: plateRect, xRadius: 184 * s, yRadius: 184 * s)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.shadowBlurRadius = 22 * s
    NSGraphicsContext.current?.saveGraphicsState()
    shadow.set()
    NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1).setFill()
    plate.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.132, green: 0.149, blue: 0.188, alpha: 1),
        ending: NSColor(srgbRed: 0.047, green: 0.055, blue: 0.075, alpha: 1))!
    gradient.draw(in: plate, angle: -90)

    // Subtle top rim highlight.
    let rim = NSBezierPath(roundedRect: plateRect.insetBy(dx: 3 * s, dy: 3 * s),
                           xRadius: 181 * s, yRadius: 181 * s)
    rim.lineWidth = 4 * s
    NSColor.white.withAlphaComponent(0.06).setStroke()
    rim.stroke()

    // Ghost "detached" pane, top-right.
    let ghost = NSBezierPath(roundedRect: NSRect(x: 596 * s, y: 608 * s,
                                                 width: 224 * s, height: 148 * s),
                             xRadius: 30 * s, yRadius: 30 * s)
    ghost.lineWidth = 13 * s
    NSColor.white.withAlphaComponent(0.30).setStroke()
    ghost.stroke()

    let green = NSColor(srgbRed: 0.188, green: 0.820, blue: 0.345, alpha: 1)

    // Prompt chevron.
    let chevron = NSBezierPath()
    chevron.lineWidth = 96 * s
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    chevron.move(to: NSPoint(x: 342 * s, y: 668 * s))
    chevron.line(to: NSPoint(x: 540 * s, y: 508 * s))
    chevron.line(to: NSPoint(x: 342 * s, y: 348 * s))
    green.setStroke()
    chevron.stroke()

    // Cursor underscore.
    let cursor = NSBezierPath(roundedRect: NSRect(x: 612 * s, y: 324 * s,
                                                  width: 178 * s, height: 50 * s),
                              xRadius: 25 * s, yRadius: 25 * s)
    green.withAlphaComponent(0.60).setFill()
    cursor.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render-icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for variant in variants {
    let rep = draw(size: variant.pixels)
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: outDir.appendingPathComponent("\(variant.name).png"))
}
print("Rendered \(variants.count) images into \(outDir.path)")
