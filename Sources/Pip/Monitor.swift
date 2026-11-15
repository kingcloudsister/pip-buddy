import SwiftUI

typealias Badge = (text: String, bg: Color, fg: Color)

/// Layout values the controller sets while the panel is open.
@MainActor
final class MonitorLayout: ObservableObject {
    @Published var listHeight: CGFloat = 200
    @Published var opensLeft = true     // Pip sits on the right edge, so the panel grows to the left
}

/// The panel that slides out from behind the strip when you click Pip: one card per app with its state.
/// The strip next to it is its face and toolbar, so the panel only holds the summary and the cards.
struct MonitorView: View {
    @ObservedObject var store: Store
    @ObservedObject var layout: MonitorLayout
    @State private var shown = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView(.vertical, showsIndicators: false) { ChatList(store: store) }
                .frame(height: layout.listHeight)
        }
        .frame(width: Theme.monitorWidth)
        .overlay(alignment: .bottom) { notice }
        // The edge next to the strip reaches under it, so the two read as one piece.
        .padding(layout.opensLeft ? .trailing : .leading, Theme.tuck)
        .background(Theme.sand)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.hairline, lineWidth: 1))
        .background(shape.fill(Theme.sand).shadow(color: .black.opacity(0.14), radius: 16, y: 6))
        .padding(Theme.monitorMargin)
        .offset(x: shown ? 0 : (layout.opensLeft ? 60 : -60))
        .opacity(shown ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: store.announcing)
        .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { shown = true } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pip").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                Text(store.activeSummary).font(.system(size: 10.5, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(Theme.caption)
            }
            Spacer()
            Button { store.openLatestDone() } label: { HeaderIcon(symbol: "location.north.fill", primary: true) }
                .buttonStyle(.plain)
                .help("Hop to the newest finished chat")
            Menu { PipMenu(store: store) } label: { HeaderIcon(symbol: "gearshape", primary: false) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Settings")
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.monitorHeader)
    }

    @ViewBuilder private var notice: some View {
        if let id = store.announcing, let t = store.app(id) {
            ToastView(icon: t.icon, title: store.cardTitle(t) + " is ready!", note: t.note) { store.open(id) }
                .padding(12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// The cards. Also measured on its own to size the panel.
struct ChatList: View {
    @ObservedObject var store: Store

    var body: some View {
        // Redraws now and then so "finished 2 minutes ago" stays true.
        TimelineView(.periodic(from: .now, by: 20)) { _ in
            VStack(spacing: 10) {
                if !store.axTrusted {
                    Card(title: "Let Pip see your chats", detail: "Allow Pip in Accessibility settings",
                         badge: ("SETUP", Theme.readyBg, Theme.readyFg)) { store.requestAccess(openSettings: true) }
                }
                ForEach(store.visibleApps) { t in
                    Group {
                        if t.sessions.count > 1 {
                            // One card per running chat, plus the one that just finished.
                            if t.unseen, let done = t.lastDone {
                                Card(title: done, detail: "\(t.name) · finished", icon: t.icon,
                                     badge: ("READY", Theme.readyBg, Theme.readyFg)) { store.open(t.id) }
                            }
                            ForEach(t.sessions, id: \.title) { s in
                                Card(title: s.title, detail: store.sessionDetail(s), icon: t.icon,
                                     badge: ("WORKING", Theme.workingBg, Theme.workingFg)) { store.open(t.id) }
                            }
                        } else {
                            Card(title: store.cardTitle(t), detail: store.cardDetail(t), icon: t.icon,
                                 badge: store.badge(t)) { store.open(t.id) }
                        }
                    }
                    .contextMenu {
                        Button("Open \(t.name)") { store.open(t.id) }
                        Button("Move Up") { store.move(t.id, by: -1) }
                        Button("Move Down") { store.move(t.id, by: 1) }
                        Divider()
                        Button("Remove from Pip") { store.remove(t.id) }
                    }
                }
                if store.visibleApps.isEmpty {
                    Text(store.apps.isEmpty ? "Add an app with ⊕ and Pip will watch it for you."
                                            : "None of your apps are open. Pip shows them here when they are.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
            }
            .padding(14)
            // Room for the "ready" notice so it never covers the last card.
            .padding(.bottom, store.announcing == nil ? 0 : 58)
        }
        .frame(width: Theme.monitorWidth)
    }

}

private struct Card: View {
    let title: String
    let detail: String
    var icon: NSImage?
    let badge: Badge
    var dimmed = false
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 4)
                BadgeLabel(badge: badge)
            }
            HStack(alignment: .top, spacing: 5) {
                if let icon {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 13, height: 13).padding(.top, 1)
                }
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white)
                .shadow(color: .black.opacity(hovered ? 0.09 : 0.03), radius: hovered ? 6 : 2, y: 1)
        )
        .opacity(dimmed ? 0.6 : 1)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onTap)
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

private struct HeaderIcon: View {
    let symbol: String
    let primary: Bool
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .frame(width: 30, height: 30)
            .background(shape.fill(primary ? Color.white : Theme.workingBg))
            .overlay(shape.strokeBorder(Theme.ink, lineWidth: primary ? 1.6 : 0))
            .scaleEffect(hovered ? 1.06 : 1)
            .contentShape(shape)
            .onHover { hovered = $0 }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
    }
}

struct BadgeLabel: View {
    let badge: Badge
    var body: some View {
        Text(badge.text).font(.system(size: 9.5, weight: .bold)).tracking(0.6).foregroundStyle(badge.fg)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(badge.bg))
            .fixedSize()
    }
}

/// The dark "X is ready! Tap back" notice, in the panel and beside the pill.
struct ToastView: View {
    let icon: NSImage?
    let title: String
    let note: String?
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).frame(width: 20, height: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                if let note, !note.isEmpty {
                    Text(note).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("Tap back").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.tapBack)
                .underline(true, color: Theme.tapBack)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.toast))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
