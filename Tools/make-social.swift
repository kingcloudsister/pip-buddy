// Builds docs/social-preview.png (1280×640), the image link previews show for the repo.
// Upload it on GitHub: Settings → General → Social preview.
//   swift Tools/make-social.swift
import AppKit

let W: CGFloat = 1280, H: CGFloat = 640
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Warm sand to soft blush, Pip's palette.
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor(red: 0.97, green: 0.93, blue: 0.87, alpha: 1).cgColor,
                             NSColor(red: 0.94, green: 0.87, blue: 0.89, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])

let ink = NSColor(white: 0.11, alpha: 1), muted = NSColor(red: 0.50, green: 0.45, blue: 0.40, alpha: 1)
let rose = NSColor(red: 0.84, green: 0.33, blue: 0.43, alpha: 1)

// Left: icon, name, tagline.
if let icon = NSImage(contentsOfFile: "Tools/icon-preview.png") { icon.draw(in: NSRect(x: 64, y: 330, width: 240, height: 240)) }
func text(_ s: String, _ font: NSFont, _ color: NSColor, _ rect: NSRect, spacing: CGFloat = 0) {
    let p = NSMutableParagraphStyle(); p.lineSpacing = spacing
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p]).draw(in: rect)
}
text("Pip", .systemFont(ofSize: 96, weight: .bold), ink, NSRect(x: 84, y: 200, width: 520, height: 120))
text("Never lose track of your AI agents.", .systemFont(ofSize: 34, weight: .semibold), ink, NSRect(x: 88, y: 128, width: 600, height: 80))
text("A tiny Mac sidebar that tells you when your agents finish,\nand takes you back to them.", .systemFont(ofSize: 22, weight: .regular),
     muted, NSRect(x: 88, y: 52, width: 620, height: 80), spacing: 4)
text("Free & open source for macOS", .systemFont(ofSize: 18, weight: .semibold), rose, NSRect(x: 88, y: 24, width: 600, height: 30))

// Right: the panel screenshot, cropped to Pip itself.
if let shot = NSImage(contentsOfFile: "docs/pip-panel-clear.png"), let cg = shot.cgImage(forProposedRect: nil, context: nil, hints: nil) {
    let px = CGFloat(cg.width) / 880                        // the screenshot is drawn at 2×
    let crop = CGRect(x: 515 * px, y: 40 * px, width: 365 * px, height: 500 * px)
    if let part = cg.cropping(to: crop) {
        let h: CGFloat = 600, w = h * crop.width / crop.height
        ctx.saveGState()
        ctx.draw(part, in: CGRect(x: W - w - 12, y: 20, width: w, height: h))
        ctx.restoreGState()
    }
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "docs/social-preview.png"))
print("Wrote docs/social-preview.png")
