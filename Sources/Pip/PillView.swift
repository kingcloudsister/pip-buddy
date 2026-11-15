import SwiftUI

/// The strip on the screen edge: the mockup's tan side column, with Pip's face on top and one row per app.
struct PillView: View {
    @ObservedObject var store: Store

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(spacing: 0) {
            Mascot(mood: store.mood, excited: store.announcing != nil)
                .frame(width: Theme.mascot, height: Theme.mascot)
                .scaleEffect(store.hovered == "pip:mascot" ? 1.05 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: store.hovered == "pip:mascot")
                .contentShape(Rectangle())
                .onHover { store.setHover("pip:mascot", $0) }
                .onTapGesture { store.panelOpen.toggle() }
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { _ in AppDelegate.shared.pill.dragChanged() }
                    .onEnded { _ in AppDelegate.shared.pill.dragEnded() })
                .contextMenu { PipMenu(store: store) }

            Capsule().fill(Theme.tanEdge.opacity(0.7)).frame(width: 18, height: 1.5)
                .frame(height: Theme.gap)

            VStack(spacing: Theme.rowGap) {
                ForEach(store.visibleApps) { AppRow(app: $0, store: store) }
                if !store.axTrusted { AccessRow(store: store) }
                AddButton(store: store)
            }
        }
        .padding(.vertical, Theme.pad)
        .frame(width: Theme.pillWidth)
        .background(
            shape.fill(Theme.tan)
                .overlay(shape.strokeBorder(Theme.tanEdge.opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        )
        .padding(Theme.margin)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: store.visibleApps.map(\.id))
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
            if app.unseen {
                Circle().fill(Theme.rose)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().strokeBorder(Theme.tan, lineWidth: 2).padding(-2))
                    .offset(x: 12, y: -12)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: Theme.pillWidth, height: Theme.row)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.15), value: hovered)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: app.unseen)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: app.sessions.count)
        .onHover { store.setHover(app.id, $0) }
        .onTapGesture { store.open(app.id) }
        .contextMenu {
            Button("Open \(app.name)") { store.open(app.id) }
            Button("Move Up") { store.move(app.id, by: -1) }
            Button("Move Down") { store.move(app.id, by: 1) }
            Divider()
            Button("Remove from Pip") { store.remove(app.id) }
        }
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
        .frame(width: Theme.pillWidth, height: Theme.row)
        .contentShape(Rectangle())
        .onHover { store.setHover("pip:access", $0) }
        .onTapGesture { store.requestAccess(openSettings: true) }
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
        .frame(width: Theme.pillWidth, height: Theme.row)
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
                if let id = app.bundleIdentifier { store.add(id) }
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
        Toggle("Pop Sound", isOn: $store.soundOn)
        Toggle("Open at Login", isOn: Binding(get: { store.openAtLogin }, set: { store.openAtLogin = $0 }))
        if !store.axTrusted {
            Button("Allow Accessibility…") { store.requestAccess(openSettings: true) }
        }
        Divider()
        Button("Copy Detection Report") { AppDelegate.shared.copyDiagnostics() }
        Button("Copy Hook Example") { AppDelegate.shared.copyHookExample() }
        Divider()
        Button("Quit Pip") { NSApp.terminate(nil) }
    }
}
