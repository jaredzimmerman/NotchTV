// Renders App/AppIcon.icns: a dark rounded square with a white play/pause glyph.
// Usage: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(starting: NSColor(white: 0.20, alpha: 1), ending: NSColor(white: 0.04, alpha: 1))!
        .draw(in: path, angle: -90)
    // The notch: a small black tab hanging from the top edge.
    let notchW = tile.width * 0.36, notchH = tile.height * 0.075
    let notch = NSBezierPath(roundedRect: NSRect(x: tile.midX - notchW / 2, y: tile.maxY - notchH,
                                                 width: notchW, height: notchH * 2),
                             xRadius: notchH * 0.7, yRadius: notchH * 0.7)
    NSGraphicsContext.current?.saveGraphicsState()
    path.addClip()
    NSColor.black.setFill()
    notch.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    // Play/pause drawn from plain shapes: SF Symbols' license doesn't allow them in app icons.
    NSColor.white.setFill()
    let h = tile.height * 0.30                    // glyph height
    let cy = tile.midY - s * 0.02                 // optical centre, nudged below the notch
    let triW = h * 0.88, barW = h * 0.25, gap = h * 0.17, barGap = h * 0.16
    let total = triW + gap + barW * 2 + barGap
    let x0 = tile.midX - total / 2
    let r = h * 0.09                              // corner rounding

    let tri = NSBezierPath()
    let a = NSPoint(x: x0, y: cy + h / 2), b = NSPoint(x: x0, y: cy - h / 2), c = NSPoint(x: x0 + triW, y: cy)
    tri.move(to: NSPoint(x: a.x, y: a.y - r))
    tri.line(to: NSPoint(x: b.x, y: b.y + r))
    tri.curve(to: NSPoint(x: b.x + r * 0.9, y: b.y + r * 0.45), controlPoint1: b, controlPoint2: b)
    tri.line(to: NSPoint(x: c.x - r * 0.9, y: c.y - r * 0.5))
    tri.curve(to: NSPoint(x: c.x - r * 0.9, y: c.y + r * 0.5), controlPoint1: c, controlPoint2: c)
    tri.line(to: NSPoint(x: a.x + r * 0.9, y: a.y - r * 0.45))
    tri.curve(to: NSPoint(x: a.x, y: a.y - r), controlPoint1: a, controlPoint2: a)
    tri.close()
    tri.fill()

    let bx = x0 + triW + gap
    for i in 0..<2 {
        let bar = NSRect(x: bx + CGFloat(i) * (barW + barGap), y: cy - h / 2, width: barW, height: h)
        NSBezierPath(roundedRect: bar, xRadius: r, yRadius: r).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: out.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: out.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
