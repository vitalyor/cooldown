// Draws Cooldown's app icon and writes Resources/AppIcon.icns.
//   swift scripts/make_icon.swift
// A deep night-blue tile with a gauge ring whose arc runs from Claude's coral through violet to
// Codex's cobalt, and a darkened sector over the spent part, like an ability on cooldown in a game.
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
    NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
            alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t)
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.scaleBy(x: size / canvas, y: size / canvas)
    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)

    // Tile: the macOS icon grid, 824 pt square with continuous corners, centred on 1024.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0x0B1230).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [color(0x1E2C6E), color(0x111A44), color(0x080D24)], atLocations: [0, 0.55, 1],
               colorSpace: .sRGB)!.draw(in: tile, angle: -70)
    // A soft glow behind the ring.
    NSGradient(colors: [color(0x5B6CFF, 0.38), color(0x5B6CFF, 0)])!
        .draw(fromCenter: NSPoint(x: 512, y: 540), radius: 0, toCenter: NSPoint(x: 512, y: 540), radius: 380, options: [])
    NSGraphicsContext.restoreGraphicsState()

    let center = NSPoint(x: 512, y: 512)
    let radius: CGFloat = 268
    let width: CGFloat = 76
    let fraction: CGFloat = 0.72

    // Track.
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = width
    color(0xFFFFFF, 0.09).setStroke()
    track.stroke()

    // The spent part, darkened like a cooldown sweep.
    let sector = NSBezierPath()
    sector.move(to: center)
    sector.appendArc(withCenter: center, radius: radius - width / 2 - 14, startAngle: 90 - 360 * fraction, endAngle: -270, clockwise: true)
    sector.close()
    color(0x000000, 0.28).setFill()
    sector.fill()

    // Inner glass disc.
    let disc = NSBezierPath(ovalIn: NSRect(x: center.x - 196, y: center.y - 196, width: 392, height: 392))
    NSGraphicsContext.saveGraphicsState()
    disc.addClip()
    NSGradient(colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0.03)])!.draw(in: disc.bounds, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    color(0xFFFFFF, 0.18).setStroke()
    disc.lineWidth = 2
    disc.stroke()

    // Progress arc: coral, violet, cobalt, drawn as many short segments for a smooth sweep.
    let stops = [color(0xFF8A5C), color(0xB57BFF), color(0x5B8CFF)]
    let steps = 360
    let sweep = 360 * fraction
    for i in 0..<steps {
        let t0 = CGFloat(i) / CGFloat(steps)
        let t1 = CGFloat(i + 1) / CGFloat(steps)
        let tint = t0 < 0.5 ? mix(stops[0], stops[1], t0 * 2) : mix(stops[1], stops[2], (t0 - 0.5) * 2)
        let segment = NSBezierPath()
        segment.appendArc(withCenter: center, radius: radius, startAngle: 90 - sweep * t0, endAngle: 90 - sweep * t1 - 0.4, clockwise: true)
        segment.lineWidth = width
        segment.lineCapStyle = .butt
        tint.setStroke()
        segment.stroke()
    }
    // Rounded ends.
    for (angle, tint) in [(90.0, stops[0]), (90 - Double(sweep), stops[2])] {
        let rad = CGFloat(angle) * .pi / 180
        let point = NSPoint(x: center.x + radius * cos(rad), y: center.y + radius * sin(rad))
        tint.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - width / 2, y: point.y - width / 2, width: width, height: width)).fill()
    }
    // A bright lead point at the end of the arc.
    let endRad = CGFloat(90 - Double(sweep)) * .pi / 180
    let lead = NSPoint(x: center.x + radius * cos(endRad), y: center.y + radius * sin(endRad))
    NSGradient(colors: [color(0xFFFFFF, 0.95), color(0xFFFFFF, 0)])!
        .draw(fromCenter: lead, radius: 0, toCenter: lead, radius: 34, options: [])

    // Glass sheen across the top of the tile.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let sheen = NSBezierPath(ovalIn: NSRect(x: 40, y: 590, width: 944, height: 520))
    sheen.addClip()
    NSGradient(colors: [color(0xFFFFFF, 0.14), color(0xFFFFFF, 0)])!.draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    // Hairline edge.
    color(0xFFFFFF, 0.14).setStroke()
    let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5, dy: 1.5), xRadius: 185, yRadius: 185)
    edge.lineWidth = 3
    edge.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = drawIcon(size: pixels).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
try drawIcon(size: 1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("build/AppIcon-1024.png"))
print("iconset written to \(iconset.path)")
