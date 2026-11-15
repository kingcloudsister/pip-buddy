import SwiftUI

/// The strip on the screen edge: the mockup's tan side column, with Pip's face first and one tile per app
/// that is busy or has news. Along the top of the screen it lies flat. Minimized, it is just the face.
struct PillView: View {
    @ObservedObject var store: Store

    var body: some View {
        let flat = store.edge.horizontal
        let stack = flat ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        let rows = flat ? AnyLayout(HStackLayout(spacing: Theme.rowGap)) : AnyLayout(VStackLayout(spacing: Theme.rowGap))
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        stack {
            face
            if !store.collapsed {
                Capsule().fill(Theme.tanEdge.opacity(0.7))
                    .frame(width: flat ? 1.5 : 18, height: flat ? 18 : 1.5)
                    .frame(width: flat ? Theme.gap : nil, height: flat ? nil : Theme.gap)
                rows {
                    ForEach(store.visibleApps) { AppRow(app: $0, store: store) }
                    if !store.axTrusted { AccessRow(store: store) }
                    if store.update != nil { UpdateRow(store: store) }
                    AddButton(store: store)
                }
            }
            Handle(store: store)
        }
        .padding(flat ? .horizontal : .vertical, Theme.pad)
        .frame(width: flat ? nil : Theme.pillWidth, height: flat ? Theme.pillWidth : nil)
        .background(
            shape.fill(Theme.tan)
                .overlay(shape.strokeBorder(Theme.tanEdge.opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        )
        .contentShape(shape)
        // Drag from anywhere on the strip; it snaps to the nearest edge (left, right or top) when let go.
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { _ in AppDelegate.shared.pill.dragChanged() }
            .onEnded { _ in AppDelegate.shared.pill.dragEnded() })
        .contextMenu { PipMenu(store: store) }
        .padding(Theme.margin)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: store.visibleApps.map(\.id))
    }

    private var face: some View {
        let ready = store.collapsed && store.apps.contains(where: \.unseen)
        let turn = store.collapsed && !ready && store.apps.contains(where: \.yourTurn)
        return Mascot(mood: store.mood, excited: store.announcing != nil)
            .frame(width: Theme.mascot, height: Theme.mascot)
            .overlay(alignment: .topTrailing) {
                // Minimized, the face carries the "something finished" dot.
                if ready {
                    Circle().fill(Theme.rose).frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Theme.tan, lineWidth: 2).padding(-2))
                        .offset(x: 3, y: -3)
                        .transition(.scale.combined(with: .opacity))
                } else if turn {
                    TurnRing().offset(x: 3, y: -3).transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(store.hovered == "pip:mascot" ? 1.05 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: store.hovered == "pip:mascot")
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: ready)
            .frame(width: store.edge.horizontal ? Theme.mascot : Theme.pillWidth,
                   height: store.edge.horizontal ? Theme.pillWidth : Theme.mascot)
            .contentShape(Rectangle())
            .onHover { store.setHover("pip:mascot", $0) }
            .onTapGesture { store.panelOpen.toggle() }
    }
}

/// The small chevron at the end of the strip: folds it down to the face, or opens it back up.
private struct Handle: View {
    @ObservedObject var store: Store
    var body: some View {
        let flat = store.edge.horizontal
        let hovered = store.hovered == "pip:handle"
        let symbol = flat ? (store.collapsed ? "chevron.compact.right" : "chevron.compact.left")
                          : (store.collapsed ? "chevron.compact.down" : "chevron.compact.up")
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(hovered ? Theme.ink : Theme.workingFg.opacity(0.7))
            .frame(width: flat ? Theme.handle : Theme.pillWidth, height: flat ? Theme.pillWidth : Theme.handle)
            .contentShape(Rectangle())
            .onHover { store.setHover("pip:handle", $0) }
            .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.collapsed.toggle() } }
            .help(store.collapsed ? "Show apps" : "Minimize to the face")
    }
}

/// A cream rounded square, the button shape from the mockup's side column.
private struct Tile: View {
    var fill = Theme.tile
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill).frame(width: 36, height: 36)
    }
}

private struct AppRow: View {
    let app: Tracked
    @ObservedObject var store: Store

    var body: some View {
        let hovered = store.hovered == app.id
        ZStack {
            Tile().opacity(hovered ? 1 : 0)
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .offset(y: app.isWorking ? -3 : 0)
            if app.isWorking {
                WorkingDots().offset(y: 14)
            }
            if app.sessions.count > 1 {
                // Several chats running in this app at once.
                Text("\(app.sessions.count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.workingFg)
                    .frame(minWidth: 14, minHeight: 14)
                    .background(Circle().fill(Theme.tile))
                    .overlay(Circle().strokeBorder(Theme.tan, lineWidth: 1.5).padding(-1.5))
                    .offset(x: -13, y: -12)
                    .transition(.scale.combined(with: .opacity))
            }
            if app.yourTurn && !app.isWorking {
                // Waiting on you: a dashed outline around the tile and a hollow ring.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.workingFg.opacity(0.55), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2.5]))
                    .frame(width: 36, height: 36)
                TurnRing().offset(x: 12, y: -12).transition(.scale.combined(with: .opacity))
            }
            if app.unseen {
                Circle().fill(Theme.rose)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Theme.tan, lineWidth: 2).padding(-2))
                    .offset(x: 12, y: -12)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: store.edge.horizontal ? Theme.row : Theme.pillWidth, height: store.edge.horizontal ? Theme.pillWidth : Theme.row)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: hovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: app.unseen)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: app.sessions.count)
        .onHover { store.setHover(app.id, $0) }
        .onTapGesture { store.open(app.id, chat: store.chatToOpen(app)) }
        .contextMenu {
            Button("Open \(app.name)") { store.open(app.id) }
            if !app.waiting.isEmpty { Button("Done with This") { store.dismiss(app.id) } }
            Button("Move Up") { store.move(app.id, by: -1) }
            Button("Move Down") { store.move(app.id, by: 1) }
            Divider()
            Button("Don't Watch This App") { store.remove(app.id) }
        }
    }
}

/// The "your turn" mark: a hollow ring, quieter than the pink "ready" dot.
private struct TurnRing: View {
    var body: some View {
        Circle().fill(Theme.tile).frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(Theme.workingFg, lineWidth: 1.5))
            .overlay(Circle().strokeBorder(Theme.tan, lineWidth: 2).padding(-2))
    }
}

/// Three dots taking turns to hop, under an app that is working.
private struct WorkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 10)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2.5) {
                ForEach(0..<3) { i in
                    Circle().fill(Theme.workingFg)
                        .frame(width: 3.2, height: 3.2)
                        .offset(y: -max(0, sin(t * 6 - Double(i) * 0.9)) * 2)
                }
            }
        }
    }
}

private struct AccessRow: View {
    @ObservedObject var store: Store
    var body: some View {
        ZStack {
            Tile(fill: Theme.readyBg)
            Image(systemName: "exclamationmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.readyFg)
        }
        .scaleEffect(store.hovered == "pip:access" ? 1.06 : 1)
        .frame(width: store.edge.horizontal ? Theme.row : Theme.pillWidth, height: store.edge.horizontal ? Theme.pillWidth : Theme.row)
        .contentShape(Rectangle())
        .onHover { store.setHover("pip:access", $0) }
        .onTapGesture { store.requestAccess(openSettings: true) }
    }
}

/// Shown when a newer Pip is out: click to download, check, and install it.
private struct UpdateRow: View {
    @ObservedObject var store: Store
    var body: some View {
        let flat = store.edge.horizontal
        ZStack {
            Tile(fill: Theme.workingBg)
            if store.updating {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.down").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.ink)
            }
        }
        .scaleEffect(store.hovered == "pip:update" ? 1.06 : 1)
        .frame(width: flat ? Theme.row : Theme.pillWidth, height: flat ? Theme.pillWidth : Theme.row)
        .contentShape(Rectangle())
        .onHover { store.setHover("pip:update", $0) }
        .onTapGesture { Updater.shared.install() }
    }
}

private struct AddButton: View {
    @ObservedObject var store: Store
    var body: some View {
        Menu {
            AddMenuItems(store: store)
        } label: {
            AddLabel(hovered: store.hovered == "pip:add")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: store.edge.horizontal ? Theme.row : Theme.pillWidth, height: store.edge.horizontal ? Theme.pillWidth : Theme.row)
        .onHover { store.setHover("pip:add", $0) }
        .help("Add an app to Pip")
    }
}

/// The mockup's ⊕, quiet until pointed at.
private struct AddLabel: View {
    let hovered: Bool
    var body: some View {
        ZStack {
            Tile().opacity(hovered ? 1 : 0)
            Image(systemName: "plus.circle").font(.system(size: 16, weight: .medium))
                .foregroundStyle(hovered ? Theme.ink : Theme.workingFg)
        }
        .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

/// Running apps not in Pip yet, plus a file picker.
struct AddMenuItems: View {
    @ObservedObject var store: Store
    var body: some View {
        let addable = store.addableApps
        if addable.isEmpty { Text("No other apps open") }
        ForEach(addable, id: \.processIdentifier) { app in
            Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                if let id = app.bundleIdentifier { store.addFromMenu(id) }
            }
        }
        Divider()
        Button("Choose App…") { store.chooseApp() }
    }
}

struct PipMenu: View {
    @ObservedObject var store: Store
    var body: some View {
        Button("Hop to Latest Finished") { store.openLatestDone() }
        Divider()
        Toggle("Minimize to Face", isOn: $store.collapsed)
        Menu("Move To") {
            ForEach(PipEdge.allCases, id: \.self) { e in
                Button(e.label + (store.edge == e ? " ✓" : "")) { AppDelegate.shared.pill.move(to: e) }
            }
        }
        Divider()
        Toggle("Pop Sound", isOn: $store.soundOn)
        Toggle("Find Agents Automatically", isOn: $store.findAgents)
        Toggle("Open at Login", isOn: Binding(get: { store.openAtLogin }, set: { store.openAtLogin = $0 }))
        if !store.axTrusted {
            Button("Allow Accessibility…") { store.requestAccess(openSettings: true) }
        }
        Divider()
        if let v = store.update {
            Button("Update to Pip \(v)") { Updater.shared.install() }
        }
        Button("Check for Updates…") { Task { await Updater.shared.check(quietly: false) } }
        Toggle("Check for Updates Automatically", isOn: Binding(get: { Updater.shared.automatic },
                                                                set: { Updater.shared.automatic = $0 }))
        Divider()
        Button("Copy Detection Report") { AppDelegate.shared.copyDiagnostics() }
        Button("Copy Hook Example") { AppDelegate.shared.copyHookExample() }
        Divider()
        Button("Quit Pip") { NSApp.terminate(nil) }
    }
}
