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
        let along = d.object(forKey: "pillAlong") as? Double ?? d.object(forKey: "pillTop") as? Double
            ?? Double(store.edge.horizontal ? vf.midX - size.width / 2 : vf.minY + vf.height * 0.72)
        panel.setFrame(Self.placed(size, store.edge, along: along, in: vf), display: true)
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

    private var screen: NSScreen { panel.screen ?? NSScreen.main ?? NSScreen.screens[0] }

    /// Where along its edge the strip starts: its top for the side edges, its left end along the top.
    private func along(_ f: NSRect) -> Double { Double(store.edge.horizontal ? f.minX : f.maxY) }

    /// Resize to fit the tiles, keeping the strip against its edge and its start where it was.
    private func layout() {
        var f = panel.frame
        if dragStart == nil {
            let size = measure(PillView(store: store))
            let target = Self.placed(size, store.edge, along: along(f), in: screen.visibleFrame)
            if target != f { panel.setFrame(target, display: true); f = target }
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

    /// Snaps to whichever edge the pointer is nearest: left, right, or the top of the screen.
    func dragEnded() {
        dragStart = nil
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? self.screen
        let vf = screen.visibleFrame
        let toLeft = mouse.x - vf.minX, toRight = vf.maxX - mouse.x, toTop = vf.maxY - mouse.y
        let edge: PipEdge = toTop < min(toLeft, toRight) ? .top : (toRight < toLeft ? .right : .left)
        settle(on: edge, near: mouse, in: vf)
    }

    /// Moves the strip to another edge from the menu, keeping it on the same screen.
    func move(to edge: PipEdge) {
        let vf = screen.visibleFrame
        settle(on: edge, near: NSPoint(x: panel.frame.midX, y: panel.frame.maxY - Theme.mascotCenter), in: vf)
    }

    private func settle(on edge: PipEdge, near point: NSPoint, in vf: NSRect) {
        let sameAxis = edge.horizontal == store.edge.horizontal
        let old = panel.frame
        if store.edge != edge { store.edge = edge }
        let size = measure(PillView(store: store))
        // Keep the face under the pointer when the strip turns between standing and lying flat.
        let along: Double = sameAxis ? (edge.horizontal ? Double(old.minX) : Double(old.maxY))
            : (edge.horizontal ? Double(point.x - Theme.mascotCenter) : Double(point.y + Theme.mascotCenter))
        let f = Self.placed(size, edge, along: along, in: vf)
        panel.setFrame(f, display: true, animate: true)
        UserDefaults.standard.set(edge.horizontal ? Double(f.minX) : Double(f.maxY), forKey: "pillAlong")
        bubble.update(pill: f)
    }

    /// Against the chosen edge, kept fully on screen. `along` is the top (side edges) or left end (top edge).
    private static func placed(_ size: NSSize, _ edge: PipEdge, along: Double, in vf: NSRect) -> NSRect {
        let inset = Theme.margin - 6
        switch edge {
        case .left, .right:
            let x = edge == .right ? vf.maxX - size.width + inset : vf.minX - inset
            let t = min(max(CGFloat(along), vf.minY + size.height - Theme.margin), vf.maxY + Theme.margin)
            return NSRect(x: x, y: t - size.height, width: size.width, height: size.height)
        case .top:
            let x = min(max(CGFloat(along), vf.minX - Theme.margin), vf.maxX - size.width + Theme.margin)
            return NSRect(x: x, y: vf.maxY - size.height + inset, width: size.width, height: size.height)
        }
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
        let edge = store.edge
        let store = store
        func card(wrap: CGFloat?) -> PopCard {
            PopCard(content: c, edge: edge, wrapWidth: wrap) {
                if let id = c.tapID { store.open(id, chat: c.tapChat) }
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
        // The card's edge sits under the middle of the strip, level with the tile it talks about.
        let pad = PopCard.shadowPad
        let frame: NSRect
        if edge.horizontal {
            let vf = screen.visibleFrame
            let x = min(max(pill.minX + c.centerY - size.width / 2, vf.minX), vf.maxX - size.width)
            frame = NSRect(x: x, y: pill.midY + pad - size.height, width: size.width, height: size.height)
        } else {
            let x = edge == .right ? pill.midX + pad - size.width : pill.midX - pad
            frame = NSRect(x: x, y: pill.maxY - c.centerY - size.height / 2, width: size.width, height: size.height)
        }
        panel.setFrame(frame, display: true)
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
        let edge = store.edge
        let natural = measure(ChatList(store: store)).height
        let listHeight = min(max(natural, 150), 420)
        if layout.listHeight != listHeight { layout.listHeight = listHeight }
        if layout.edge != edge { layout.edge = edge }

        let m = Theme.monitorMargin
        let vf = screen.visibleFrame
        let frame: NSRect
        if edge.horizontal {
            // Drops down from under the strip, centered on it and kept on screen.
            let size = NSSize(width: Theme.monitorWidth + 2 * m, height: Theme.monitorHeader + 1 + listHeight + Theme.tuck + 2 * m)
            let x = min(max(pill.midX - size.width / 2, vf.minX - m), vf.maxX - size.width + m)
            frame = NSRect(x: x, y: pill.midY + m - size.height, width: size.width, height: size.height)
        } else {
            let size = NSSize(width: Theme.monitorWidth + Theme.tuck + 2 * m, height: Theme.monitorHeader + 1 + listHeight + 2 * m)
            // The panel's edge sits under the middle of the strip, and their tops line up.
            let x = edge == .right ? pill.midX + m - size.width : pill.midX - m
            let stripTop = pill.maxY - Theme.margin
            let top = min(max(stripTop + m, vf.minY + size.height - m), vf.maxY + m)
            frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        }
        panel.setFrame(frame, display: true)

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
