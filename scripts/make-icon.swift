// Erzeugt das App-Icon (Resources/AppIcon.icns) im CTW-Design.
// Aufruf: swift scripts/make-icon.swift <Zielordner für das .iconset>
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let teal900: UInt32 = 0x17383E, teal700: UInt32 = 0x3A666D, teal500: UInt32 = 0x8AC2CD
let teal200: UInt32 = 0xD9ECEF, red600: UInt32 = 0xC53637, sand50: UInt32 = 0xF5F1EA

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s, y: s)

    // macOS-Icon-Raster: 824 × 824 Fläche, mittig, Radius ~185.
    let plate = NSRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.28)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(teal900).setFill()
    platePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    platePath.addClip()
    NSGradient(colors: [color(teal700), color(teal900)])!.draw(in: plate, angle: -90)
    // Ein Licht von oben.
    NSGradient(colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)])!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Glas-Briefumschlag.
    let env = NSRect(x: 232, y: 300, width: 520, height: 370)
    let envPath = NSBezierPath(roundedRect: env, xRadius: 44, yRadius: 44)
    NSGraphicsContext.saveGraphicsState()
    let glassShadow = NSShadow()
    glassShadow.shadowColor = color(0x0B1317, 0.35)
    glassShadow.shadowBlurRadius = 30
    glassShadow.shadowOffset = NSSize(width: 0, height: -14)
    glassShadow.set()
    color(sand50, 0.96).setFill()
    envPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    color(0xFFFFFF, 0.9).setStroke()
    envPath.lineWidth = 4
    envPath.stroke()

    // Klappe des Umschlags.
    let flap = NSBezierPath()
    flap.move(to: NSPoint(x: env.minX + 40, y: env.maxY - 34))
    flap.line(to: NSPoint(x: env.midX, y: env.midY - 10))
    flap.line(to: NSPoint(x: env.maxX - 40, y: env.maxY - 34))
    flap.lineWidth = 34
    flap.lineCapStyle = .round
    flap.lineJoinStyle = .round
    color(teal700).setStroke()
    flap.stroke()

    // Sortierlinien – Ordnung schaffen.
    for (i, w) in [CGFloat(210), 150].enumerated() {
        let line = NSBezierPath(roundedRect: NSRect(x: env.minX + 70, y: env.minY + 70 + CGFloat(i) * 48, width: w, height: 22),
                                xRadius: 11, yRadius: 11)
        color(teal500).setFill()
        line.fill()
    }

    // CTW-Pixelmotiv in Red 600 / Teal.
    let squares: [(NSRect, UInt32)] = [
        (NSRect(x: 690, y: 690, width: 96, height: 96), red600),
        (NSRect(x: 800, y: 760, width: 56, height: 56), teal200),
        (NSRect(x: 800, y: 640, width: 40, height: 40), teal500),
        (NSRect(x: 620, y: 800, width: 44, height: 44), teal500),
    ]
    for (r, c) in squares {
        color(c).setFill()
        NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = render(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    }
}
print("Iconset: \(out.path)")
