import AppKit
import Combine
import SwiftUI

/// Hosting view that takes the first click even while Pip is not the active app.
/// Pip sets the window frames itself, so the view does not resize its window.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Natural size of a SwiftUI view, measured off screen.
@MainActor
func measure<V: View>(_ view: V) -> NSSize { NSHostingView(rootView: view).fittingSize }

@MainActor
func makeFloatingPanel() -> NSPanel {
    let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isFloatingPanel = true
    p.level = .floating
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    p.backgroundColor = .clear
    p.isOpaque = false
    p.hasShadow = false
    p.hidesOnDeactivate = false
    p.becomesKeyOnlyIfNeeded = true
    p.appearance = NSAppearance(named: .aqua)
    return p
}

/// The floating pill: Pip on top, one row per app.
@MainActor
final class PillController {
    let panel = makeFloatingPanel()
    private let store: Store
    private let hosting: FirstClickHostingView<PillView>
    private let bubble: BubbleController
    private let monitor: MonitorController
    private var watch: AnyCancellable?
    private var layoutQueued = false
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?

    init(store: Store) {
        self.store = store
        hosting = FirstClickHostingView(rootView: PillView(store: store))
        bubble = BubbleController(store: store)
        monitor = MonitorController(store: store)
        panel.contentView = hosting
        // The strip sits above the cards and panel that slide out from behind it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)

        let size = measure(PillView(store: store))
        let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let d = UserDefaults.standard
        let onRight = d.object(forKey: "pillOnRight") as? Bool ?? true
        let top = d.object(forKey: "pillTop") as? Double ?? Double(vf.minY + vf.height * 0.72)
        panel.setFrame(Self.snapped(NSRect(origin: .zero, size: size), onRight: onRight, top: top, in: vf), display: true)
        panel.orderFrontRegardless()

        watch = store.objectWillChange.sink { [weak self] _ in self?.queueLayout() }
        queueLayout()
    }

    private func queueLayout() {
        guard !layoutQueued else { return }
        layoutQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.layoutQueued = false
                self?.layout()
            }
        }
    }

    /// Resize to fit the rows, keeping the top edge and the screen edge Pip sits against.
    private func layout() {
        let size = measure(PillView(store: store))
        var f = panel.frame
        if f.size != size {
            let onRight = f.midX > (panel.screen ?? NSScreen.main)!.frame.midX
            f = NSRect(x: onRight ? f.maxX - size.width : f.minX, y: f.maxY - size.height, width: size.width, height: size.height)
            panel.setFrame(f, display: true)
        }
        bubble.update(pill: f)
        monitor.update(pill: f)
    }

    func dragChanged() {
        let mouse = NSEvent.mouseLocation
        if dragStart == nil {
            dragStart = (mouse, panel.frame.origin)
            store.hovered = nil
            store.panelOpen = false
        }
        guard let s = dragStart else { return }
        panel.setFrameOrigin(NSPoint(x: s.origin.x + mouse.x - s.mouse.x, y: s.origin.y + mouse.y - s.mouse.y))
        bubble.update(pill: panel.frame)
    }

    func dragEnded() {
        dragStart = nil
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? panel.screen ?? NSScreen.main!
        let onRight = panel.frame.midX > screen.frame.midX
        let f = Self.snapped(panel.frame, onRight: onRight, top: panel.frame.maxY, in: screen.visibleFrame)
        panel.setFrame(f, display: true, animate: true)
        UserDefaults.standard.set(onRight, forKey: "pillOnRight")
        UserDefaults.standard.set(Double(f.maxY), forKey: "pillTop")
        bubble.update(pill: f)
    }

    /// Hugs the left or right edge of the screen, kept fully on screen.
    private static func snapped(_ f: NSRect, onRight: Bool, top: Double, in vf: NSRect) -> NSRect {
        let inset = Theme.margin - 6
        let x = onRight ? vf.maxX - f.width + inset : vf.minX - inset
        let maxTop = vf.maxY + Theme.margin
        let minTop = vf.minY + f.height - Theme.margin
        let t = min(max(CGFloat(top), minTop), maxTop)
        return NSRect(x: x, y: t - f.height, width: f.width, height: f.height)
    }
}

/// The card that slides out from behind the strip. Its window is sized to the card so it never blocks clicks elsewhere.
@MainActor
final class BubbleController {
    private let panel = makeFloatingPanel()
    private let store: Store
    private let hosting = FirstClickHostingView(rootView: AnyView(EmptyView()))

    init(store: Store) {
        self.store = store
        panel.contentView = hosting
    }

    func update(pill: NSRect) {
        // The open panel shows everything itself, including the "ready" notice.
        guard !store.panelOpen, let c = BubbleContent.current(store) else {
            panel.orderOut(nil)
            return
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(pill) } ?? NSScreen.main!
        let onRight = pill.midX > screen.frame.midX
        let store = store
        func card(wrap: CGFloat?) -> PopCard {
            PopCard(content: c, onRight: onRight, wrapWidth: wrap) {
                if let id = c.tapID { store.open(id) }
                else if c.key == "pip:access" { store.requestAccess(openSettings: true) }
                else if c.key == "pip:mascot" { store.panelOpen = true }
            }
        }
        var view = card(wrap: nil)
        var size = measure(view)
        // Long titles wrap inside a fixed width instead of making a very wide card.
        if size.width > 340 {
            view = card(wrap: 230)
            size = measure(view)
        }
        hosting.rootView = AnyView(view.id(c.key))
        // The card's edge sits under the middle of the strip.
        let pad = PopCard.shadowPad
        let x = onRight ? pill.midX + pad - size.width : pill.midX - pad
        let cy = pill.maxY - c.centerY
        panel.setFrame(NSRect(x: x, y: cy - size.height / 2, width: size.width, height: size.height), display: true)
        // Hover labels only show text; let clicks fall through to whatever is under them.
        panel.ignoresMouseEvents = c.tapID == nil && c.key != "pip:access"
        panel.orderFrontRegardless()
    }
}

/// The monitor panel. It slides out from behind the strip, joined to it. Clicking anywhere outside Pip closes it.
@MainActor
final class MonitorController {
    private let panel = makeFloatingPanel()
    private let store: Store
    private let layout = MonitorLayout()
    private let hosting = FirstClickHostingView(rootView: AnyView(EmptyView()))
    private var outsideClicks: Any?

    init(store: Store) {
        self.store = store
        panel.contentView = hosting
    }

    func update(pill: NSRect) {
        guard store.panelOpen else { return hide() }
        let screen = NSScreen.screens.first { $0.frame.intersects(pill) } ?? NSScreen.main!
        let onRight = pill.midX > screen.frame.midX
        let natural = measure(ChatList(store: store)).height
        let listHeight = min(max(natural, 150), 420)
        if layout.listHeight != listHeight { layout.listHeight = listHeight }
        if layout.opensLeft != onRight { layout.opensLeft = onRight }

        let m = Theme.monitorMargin
        let size = NSSize(width: Theme.monitorWidth + Theme.tuck + 2 * m, height: Theme.monitorHeader + 1 + listHeight + 2 * m)
        // The panel's edge sits under the middle of the strip, and their tops line up.
        let x = onRight ? pill.midX + m - size.width : pill.midX - m
        let vf = screen.visibleFrame
        let stripTop = pill.maxY - Theme.margin
        let top = min(max(stripTop + m, vf.minY + size.height - m), vf.maxY + m)
        panel.setFrame(NSRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)

        if outsideClicks == nil {
            hosting.rootView = AnyView(MonitorView(store: store, layout: layout))
            panel.orderFrontRegardless()
            // Clicks in other apps close the panel; clicks on Pip's own windows do not reach this monitor.
            outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                MainActor.assumeIsolated { Store.shared.panelOpen = false }
            }
        }
    }

    private func hide() {
        guard let monitor = outsideClicks else { return }
        NSEvent.removeMonitor(monitor)
        outsideClicks = nil
        panel.orderOut(nil)
        hosting.rootView = AnyView(EmptyView())
    }
}
