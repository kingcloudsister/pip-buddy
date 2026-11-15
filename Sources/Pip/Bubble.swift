import SwiftUI

/// What slides out of the strip right now: a hover label, or the card of a chat that just finished.
struct BubbleContent {
    var key: String
    var icon: NSImage?
    var title: String
    var badge: Badge?
    var detail: String?
    var cta: String?
    var tapID: String?
    var tapChat: String?        // the chat to open in that app
    var centerY: CGFloat    // from the top of the pill window

    @MainActor
    static func current(_ store: Store) -> BubbleContent? {
        // Confirms an app you just added, next to ⊕.
        if let a = store.added, let t = store.app(a.id) {
            let addRow = store.visibleApps.count + (store.axTrusted ? 0 : 1) + (store.update == nil ? 0 : 1)
            return BubbleContent(key: "added:" + a.id, icon: t.icon, title: "Watching \(t.name)",
                                 badge: ("ADDED", Theme.workingBg, Theme.workingFg),
                                 detail: a.open ? "It's on the strip now." : "It'll show up here whenever it's open.",
                                 cta: a.open ? nil : "Open \(t.name)", tapID: a.open ? nil : a.id,
                                 centerY: store.collapsed ? Theme.mascotCenter : Theme.rowCenter(addRow))
        }
        if let h = store.hovered {
            switch h {
            case "pip:mascot":
                let ready = store.visibleApps.reduce(0) { $0 + $1.waiting.filter { !$0.read }.count }
                let turn = store.visibleApps.reduce(0) { $0 + $1.waiting.filter(\.read).count }
                let working = store.visibleApps.reduce(0) { $0 + ($1.isWorking ? max(1, $1.sessions.count) : 0) }
                var parts: [String] = []
                if ready > 0 { parts.append("\(ready) ready") }
                if turn > 0 { parts.append("\(turn) waiting on you") }
                if working > 0 { parts.append("\(working) working") }
                return BubbleContent(key: h, title: "Pip", detail: parts.isEmpty ? "All quiet… zzz" : parts.joined(separator: " · "),
                                     cta: "Click to see all chats", centerY: Theme.mascotCenter)
            case "pip:update":
                let i = store.visibleApps.count + (store.axTrusted ? 0 : 1)
                return BubbleContent(key: h, title: store.updating ? "Updating…" : "Update available",
                                     badge: ("NEW", Theme.workingBg, Theme.workingFg),
                                     detail: "Pip \(store.update ?? "") · you have \(Updater.shared.current)",
                                     cta: store.updating ? nil : "Click to install", centerY: Theme.rowCenter(i))
            case "pip:access":
                return BubbleContent(key: h, title: "Let Pip see your chats", badge: ("SETUP", Theme.readyBg, Theme.readyFg),
                                     detail: "Allow Pip in Accessibility settings", cta: "Click to allow",
                                     centerY: Theme.rowCenter(store.visibleApps.count))
            default:
                let shown = store.visibleApps
                guard let i = shown.firstIndex(where: { $0.id == h }) else { return nil }
                let t = shown[i]
                return BubbleContent(key: h, icon: t.icon, title: store.cardTitle(t), badge: store.badge(t),
                                     detail: store.cardDetail(t), centerY: Theme.rowCenter(i))
            }
        }
        let shown = store.visibleApps
        if let a = store.announcing, let i = shown.firstIndex(where: { $0.id == a }) {
            let t = shown[i]
            // Minimized, the card comes out of the face.
            let title = store.announceTitle ?? store.cardTitle(t)
            let w = t.waiting.last { $0.title == title }
            return BubbleContent(key: (store.announceNudge ? "nudge:" : "done:") + a + title, icon: t.icon,
                                 title: store.announceNudge ? "Still waiting on you" : title,
                                 badge: store.announceNudge ? Store.turnBadge : ("READY", Theme.readyBg, Theme.readyFg),
                                 detail: store.announceNudge ? title + (w?.last.map { " · Last: " + $0 } ?? "")
                                                             : (w.map(store.waitingDetail) ?? store.cardDetail(t)),
                                 cta: "Tap back", tapID: a, tapChat: title,
                                 centerY: store.collapsed ? Theme.mascotCenter : Theme.rowCenter(i))
        }
        return nil
    }
}

/// One card from the panel on its own. Its edge next to the strip tucks under it, so it slides out from behind.
struct PopCard: View {
    static let shadowPad: CGFloat = 12

    let content: BubbleContent
    let edge: PipEdge           // the strip's edge; the card slides out away from it
    var wrapWidth: CGFloat?     // set when the text is too long for one line
    let onTap: () -> Void
    @State private var shown = false

    var body: some View {
        let c = content
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        HStack(alignment: .top, spacing: 10) {
            if let icon = c.icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 22, height: 22).padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(c.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    if wrapWidth != nil { Spacer(minLength: 0) }
                    if let b = c.badge { BadgeLabel(badge: b) }
                }
                if let d = c.detail, !d.isEmpty {
                    // Several running chats list one per line.
                    Text(d).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(d.contains("\n") ? 6 : 2)
                        .lineSpacing(2)
                }
                if let cta = c.cta {
                    Text(cta).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.tapBackInk)
                        .underline(true, color: Theme.tapBackInk.opacity(0.5)).padding(.top, 1)
                }
            }
            .frame(width: wrapWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .padding(edge == .top ? .top : edge == .right ? .trailing : .leading, Theme.tuck)
        .background(
            shape.fill(Color.white)
                .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.13), radius: 8, y: 3)
        )
        .padding(Self.shadowPad)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .offset(x: shown || edge == .top ? 0 : (edge == .right ? 40 : -40), y: shown || edge != .top ? 0 : -40)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: c.tapID == nil ? 0.9 : 0.68)) { shown = true }
        }
    }
}
