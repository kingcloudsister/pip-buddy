// Draws Pip's app icon (the square face from the strip) and builds AppIcon.icns.
//   swift Tools/make-icon.swift            → AppIcon.icns and Tools/icon-preview.png
import AppKit

let tan = NSColor(red: 0.902, green: 0.827, blue: 0.690, alpha: 1)
let tanLight = NSColor(red: 0.945, green: 0.890, blue: 0.784, alpha: 1)
let tanEdge = NSColor(red: 0.80, green: 0.71, blue: 0.56, alpha: 1)
let ink = NSColor(white: 0.11, alpha: 1)
let rose = NSColor(red: 0.91, green: 0.42, blue: 0.51, alpha: 1)
let blush = NSColor(red: 0.96, green: 0.64, blue: 0.69, alpha: 1)

/// Draws on a 1024 grid (y down). Small sizes get bolder lines so the face still reads.
func drawIcon(_ size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let g = NSGraphicsContext.current!.cgContext
    g.translateBy(x: 0, y: CGFloat(size)); g.scaleBy(x: CGFloat(size) / 1024, y: -CGFloat(size) / 1024)
    let small = size <= 64
    let line: CGFloat = small ? 44 : 30

    // macOS icon shape: rounded square on the standard 824 grid, soft shadow below.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    g.addPath(tilePath); g.setFillColor(tan.cgColor); g.fillPath()
    g.restoreGState()
    g.saveGState()
    g.addPath(tilePath); g.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [tanLight.cgColor, tan.cgColor] as CFArray, locations: [0, 1])!
    g.drawLinearGradient(grad, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    g.restoreGState()
    g.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
    g.setStrokeColor(tanEdge.withAlphaComponent(0.55).cgColor); g.setLineWidth(4); g.strokePath()

    g.setLineCap(.round); g.setLineJoin(.round)

    // Antenna with the pink "ready" dot on top.
    g.move(to: CGPoint(x: 668, y: 312)); g.addLine(to: CGPoint(x: 724, y: 232))
    g.setStrokeColor(ink.cgColor); g.setLineWidth(line); g.strokePath()
    let dot = CGRect(x: 724 - 40, y: 232 - 40, width: 80, height: 80)
    g.setFillColor(rose.cgColor); g.fillEllipse(in: dot)
    g.setLineWidth(line * 0.8); g.strokeEllipse(in: dot)

    // The face: a white rounded square in ink, with a soft shadow.
    let face = CGRect(x: 252, y: 304, width: 520, height: 500)
    let facePath = CGPath(roundedRect: face, cornerWidth: 158, cornerHeight: 158, transform: nil)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: NSColor(red: 0.45, green: 0.33, blue: 0.18, alpha: 0.25).cgColor)
    g.addPath(facePath); g.setFillColor(NSColor.white.cgColor); g.fillPath()
    g.restoreGState()
    g.addPath(facePath); g.setStrokeColor(ink.cgColor); g.setLineWidth(line); g.strokePath()

    // Cheeks.
    if !small {
        g.setFillColor(blush.withAlphaComponent(0.55).cgColor)
        g.fillEllipse(in: CGRect(x: 318, y: 588, width: 96, height: 52))
        g.fillEllipse(in: CGRect(x: 610, y: 588, width: 96, height: 52))
    }

    // Happy ^ ^ eyes.
    g.setStrokeColor(ink.cgColor); g.setLineWidth(line)
    for x: CGFloat in [414, 610] {
        g.move(to: CGPoint(x: x - 44, y: 540))
        g.addQuadCurve(to: CGPoint(x: x + 44, y: 540), control: CGPoint(x: x, y: 470))
        g.strokePath()
    }

    // Open smile with a little tongue.
    let mouth = CGMutablePath()
    mouth.move(to: CGPoint(x: 452, y: 612))
    mouth.addQuadCurve(to: CGPoint(x: 572, y: 612), control: CGPoint(x: 512, y: 728))
    mouth.closeSubpath()
    g.addPath(mouth); g.setFillColor(ink.cgColor); g.fillPath()
    if !small {
        g.saveGState(); g.addPath(mouth); g.clip()
        g.setFillColor(rose.cgColor); g.fillEllipse(in: CGRect(x: 478, y: 646, width: 68, height: 50))
        g.restoreGState()
    }
    g.addPath(mouth); g.setStrokeColor(ink.cgColor); g.setLineWidth(line * 0.55); g.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try drawIcon(base * scale).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
    }
}
try drawIcon(1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("Tools/icon-preview.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote AppIcon.icns and Tools/icon-preview.png" : "iconutil failed")
