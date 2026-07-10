// Renders the Detach app icon into an .iconset directory.
// Design: clean white plate, gradient chevron (teal → indigo → coral),
// gray ghost "detached" pane, coral cursor underscore.
// Usage: swift render-icon.swift <output.iconset>

import AppKit

let variants: [(pixels: Int, name: String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

let teal = NSColor(srgbRed: 0.05, green: 0.72, blue: 0.62, alpha: 1)
let indigo = NSColor(srgbRed: 0.33, green: 0.36, blue: 0.88, alpha: 1)
let coral = NSColor(srgbRed: 1.00, green: 0.45, blue: 0.30, alpha: 1)

func draw(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024.0

    // White squircle plate with a soft shadow, macOS-style margins.
    let plateRect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let plate = NSBezierPath(roundedRect: plateRect, xRadius: 184 * s, yRadius: 184 * s)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowBlurRadius = 24 * s
    NSGraphicsContext.current?.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    plate.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Barely-there vertical tint so white does not look flat.
    NSGradient(starting: NSColor.white,
               ending: NSColor(srgbRed: 0.945, green: 0.953, blue: 0.969, alpha: 1))!
        .draw(in: plate, angle: -90)

    // Hairline border.
    let border = NSBezierPath(roundedRect: plateRect.insetBy(dx: 2 * s, dy: 2 * s),
                              xRadius: 182 * s, yRadius: 182 * s)
    border.lineWidth = 4 * s
    NSColor.black.withAlphaComponent(0.08).setStroke()
    border.stroke()

    // Ghost "detached" pane.
    let ghost = NSBezierPath(roundedRect: NSRect(x: 596 * s, y: 608 * s,
                                                 width: 224 * s, height: 148 * s),
                             xRadius: 30 * s, yRadius: 30 * s)
    ghost.lineWidth = 14 * s
    NSColor.black.withAlphaComponent(0.16).setStroke()
    ghost.stroke()

    // Gradient chevron: clip to the stroked path, then pour a linear gradient.
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: 342 * s, y: 668 * s))
    chevron.line(to: NSPoint(x: 540 * s, y: 508 * s))
    chevron.line(to: NSPoint(x: 342 * s, y: 348 * s))

    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState()
    ctx.addPath(chevron.cgPath)
    ctx.setLineWidth(100 * s)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [teal.cgColor, indigo.cgColor, coral.cgColor] as CFArray,
        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 292 * s, y: 700 * s),
        end: CGPoint(x: 590 * s, y: 320 * s),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Cursor underscore — coral.
    let cursor = NSBezierPath(roundedRect: NSRect(x: 612 * s, y: 324 * s,
                                                  width: 178 * s, height: 52 * s),
                              xRadius: 26 * s, yRadius: 26 * s)
    coral.setFill()
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
