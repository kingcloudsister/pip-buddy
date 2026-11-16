import AppKit
import SwiftUI

/// Settings for drawing Pip into images instead of on screen.
enum Render {
    /// Views start fully shown, so a picture isn't caught mid-animation.
    nonisolated(unsafe) static var still = false
}

/// `Pip --render-shots <folder>`: draws Pip's real strip, cards and panel with made-up example chats onto a
/// desktop-like background, for the README. Nothing from your own chats or settings ends up in the images.
@MainActor
enum Screenshots {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let k = args.firstIndex(of: "--render-shots"), k + 1 < args.count else { return false }
        Render.still = true
        let folder = URL(fileURLWithPath: (args[k + 1] as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, scene) in [("ready", Scene.ready), ("panel", Scene.panel), ("chats", Scene.chats)] {
            let store = sampleStore(scene)
            if let png = shot(store, scene) { try? png.write(to: folder.appendingPathComponent("pip-\(name).png")) }
        }
        return true
    }

    enum Scene { case ready, panel, chats }

    private static func icon(_ bundleID: String, fallback: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: fallback, accessibilityDescription: nil) ?? NSImage()
    }

    /// Example apps and chats. Every name here is invented.
    private static func sampleStore(_ scene: Scene) -> Store {
        let s = Store()
        let ago = { (m: Double) in Date().addingTimeInterval(-m * 60) }
        var claude = Tracked(id: "claude", name: "Claude", bundleID: nil, icon: icon("com.anthropic.claudefordesktop", fallback: "sparkles"))
        claude.status = .working(since: ago(6))
        claude.sessions = [Session(title: "Refactor the parser", since: ago(6), step: "Running the tests"),
                           Session(title: "Draft release notes", since: ago(2))]
        var term = Tracked(id: "terminal", name: "Terminal", bundleID: nil, icon: icon("com.apple.Terminal", fallback: "terminal"))
        term.status = .done(at: ago(0))
        term.waiting = [Waiting(title: "Fix the login bug", last: "All 42 tests pass", at: ago(0))]
        var grok = Tracked(id: "grok", name: "Grok Bot", bundleID: nil, icon: icon("com.anysphere.sand", fallback: "bubble.left"))
        grok.status = .done(at: ago(25))
        grok.waiting = [Waiting(title: "Market research", last: "Replied", at: ago(25), read: true, since: ago(12))]
        var amp = Tracked(id: "amp", name: "Amp", bundleID: nil, icon: icon("com.ampcode.amp.macos", fallback: "bolt"))
        amp.status = .working(since: ago(1))
        s.apps = scene == .ready ? [claude, term, grok] : [claude, term, grok, amp]
        s.axTrusted = true
        switch scene {
        case .ready:
            s.announcing = "terminal"; s.announceTitle = "Fix the login bug"
        case .panel:
            s.panelOpen = true
        case .chats:
            s.hovered = "claude"
        }
        return s
    }

    private static func image<V: View>(_ v: V) -> CGImage? {
        let r = ImageRenderer(content: v.environment(\.colorScheme, .light))
        r.scale = 2
        return r.cgImage
    }

    /// Lays the pieces out the way Pip's windows sit on screen: the strip on the right edge, cards and the
    /// panel tucked under it.
    private static func shot(_ store: Store, _ scene: Scene) -> Data? {
        let W: CGFloat = 880, H: CGFloat = scene == .panel ? 640 : 520
        let strip = PillView(store: store)
        let stripSize = measure(strip)
        let stripOrigin = CGPoint(x: W - stripSize.width + 6, y: 56)      // top-left, y down
        var pieces: [(CGImage, CGRect)] = []

        switch scene {
        case .panel:
            let layout = MonitorLayout()
            layout.listHeight = min(max(measure(ChatList(store: store)).height, 150), 420)
            layout.edge = .right
            let m = Theme.monitorMargin
            let size = CGSize(width: Theme.monitorWidth + Theme.tuck + 2 * m, height: Theme.monitorHeader + 1 + layout.listHeight + 2 * m)
            let view = MonitorView(store: store, layout: layout).frame(width: size.width, height: size.height)
            let x = stripOrigin.x + stripSize.width / 2 + m - size.width
            let y = stripOrigin.y + Theme.margin - m
            if let img = image(view) { pieces.append((img, CGRect(x: x, y: y, width: size.width, height: size.height))) }
        case .ready, .chats:
            if let c = BubbleContent.current(store) {
                var card = PopCard(content: c, edge: .right) {}
                var size = measure(card)
                if size.width > 340 { card = PopCard(content: c, edge: .right, wrapWidth: 230) {}; size = measure(card) }
                let x = stripOrigin.x + stripSize.width / 2 + PopCard.shadowPad - size.width
                let y = stripOrigin.y + c.centerY - size.height / 2
                if let img = image(card.frame(width: size.width, height: size.height)) {
                    pieces.append((img, CGRect(x: x, y: y, width: size.width, height: size.height)))
                }
            }
        }
        if let img = image(strip.frame(width: stripSize.width, height: stripSize.height)) {
            pieces.append((img, CGRect(origin: stripOrigin, size: stripSize)))
        }
        return compose(W, H, pieces)
    }

    /// A soft desktop with a blurred app window behind Pip.
    private static func compose(_ W: CGFloat, _ H: CGFloat, _ pieces: [(CGImage, CGRect)]) -> Data? {
        let s: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(W * s), height: Int(H * s), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: s, y: s)
        // Background: warm sand to soft blush, matching Pip's palette.
        let colors = [CGColor(red: 0.96, green: 0.92, blue: 0.86, alpha: 1), CGColor(red: 0.93, green: 0.86, blue: 0.88, alpha: 1)]
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
        // A stand-in app window: title bar dots and a few grey lines of "content".
        let win = CGRect(x: 44, y: 40, width: 470, height: H - 96)      // y measured from the bottom here
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: 0.18))
        ctx.addPath(CGPath(roundedRect: win, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.92)); ctx.fillPath()
        ctx.restoreGState()
        for (i, c) in [(0.99, 0.37, 0.34), (0.99, 0.74, 0.18), (0.16, 0.79, 0.25)].enumerated() {
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: win.minX + 18 + CGFloat(i) * 20, y: win.maxY - 26, width: 12, height: 12))
        }
        ctx.setFillColor(CGColor(gray: 0.88, alpha: 1))
        for (k, w) in [300.0, 380, 260, 340, 220, 370, 280, 330, 240, 350].enumerated()
            where win.maxY - 90 - CGFloat(k) * 46 > win.minY + 30 {
            ctx.addPath(CGPath(roundedRect: CGRect(x: win.minX + 40, y: win.maxY - 90 - CGFloat(k) * 46, width: w, height: 14),
                               cornerWidth: 7, cornerHeight: 7, transform: nil))
            ctx.fillPath()
        }
        for (img, rect) in pieces {
            ctx.draw(img, in: CGRect(x: rect.minX, y: H - rect.maxY, width: rect.width, height: rect.height))
        }
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }
}
