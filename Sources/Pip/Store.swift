import AppKit
import ServiceManagement
import UniformTypeIdentifiers

enum Status: Equatable {
    case idle
    case working(since: Date)
    case done(at: Date)
}

enum Mood { case sleepy, busy, happy }

/// A conversation an app lists as running, like a session in Claude's sidebar.
struct Session: Equatable {
    var title: String
    var since = Date()
    var step: String?           // what it is doing now, when it is the one on screen
}

struct Tracked: Identifiable, Equatable {
    let id: String              // bundle ID, or "hook:<name>" for apps that report through the local hook
    var name: String
    var bundleID: String?
    var openBundleID: String?   // hook entries: the app to bring forward on click
    var icon: NSImage
    var status: Status = .idle
    var unseen = false          // finished while you were elsewhere and you have not looked yet
    var title: String?          // front window title, usually the conversation name
    var note: String?           // message sent with a hook
    var sessions: [Session] = []    // conversations the app lists as running, when it shows them (Claude's sidebar)
    var step: String?               // what the app says it is doing, when it is not tied to a listed conversation
    var lastDone: String?       // the conversation that finished most recently
}

extension Tracked {
    var isWorking: Bool { if case .working = status { return true }; return false }
}

/// Everything the pill and bubble show. Main thread only.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var apps: [Tracked] = []
    @Published var announcing: String?
    @Published var hovered: String?
    @Published var panelOpen = false
    @Published var axTrusted = AXIsProcessTrusted()
    @Published var runningChanged = 0
    @Published var soundOn = UserDefaults.standard.object(forKey: "sound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundOn, forKey: "sound") }
    }

    private var misses: [String: Int] = [:]
    private var sessionMisses: [String: Int] = [:]   // "<app id>\n<title>": polls a running conversation has been missing
    private var badges: [String: String] = [:]
    private var hideAnnouncement: DispatchWorkItem?

    nonisolated static let defaultAppNames = ["Claude", "Amp", "Grok", "Grok Bot", "ChatGPT"]

    init() {
        let d = UserDefaults.standard
        var saved = d.stringArray(forKey: "tracked") ?? Self.discoverDefaults()
        // Apps added to the default list after first launch are offered once, so existing setups pick them up
        // without bringing back apps the user removed.
        let offered = Set(d.stringArray(forKey: "offeredDefaults") ?? ["Claude", "Amp", "Grok", "ChatGPT"])
        for id in Self.discoverDefaults(Self.defaultAppNames.filter { !offered.contains($0) }) where !saved.contains(id) {
            saved.append(id)
        }
        d.set(Self.defaultAppNames, forKey: "offeredDefaults")
        apps = saved.compactMap(Self.makeTracked)
        persist()

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { Store.shared.appActivated(bundleID) }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { Store.shared.runningChanged += 1 }
            }
        }
    }

    // MARK: Tracked apps

    nonisolated static func defaultBundleIDs() -> [String] { discoverDefaults() }

    nonisolated static func discoverDefaults(_ names: [String] = defaultAppNames) -> [String] {
        let dirs = ["/Applications", NSHomeDirectory() + "/Applications"]
        return names.compactMap { name in
            for dir in dirs {
                if let id = Bundle(path: "\(dir)/\(name).app")?.bundleIdentifier { return id }
            }
            return nil
        }
    }

    static func makeTracked(_ bundleID: String) -> Tracked? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        return Tracked(id: bundleID, name: name, bundleID: bundleID, icon: NSWorkspace.shared.icon(forFile: url.path))
    }

    func app(_ id: String) -> Tracked? { apps.first { $0.id == id } }

    func add(_ bundleID: String) {
        guard app(bundleID) == nil, let t = Self.makeTracked(bundleID) else { return }
        apps.append(t)
        persist()
    }

    func remove(_ id: String) {
        apps.removeAll { $0.id == id }
        if announcing == id { announcing = nil }
        if hovered == id { hovered = nil }
        persist()
    }

    func move(_ id: String, by delta: Int) {
        guard let i = apps.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard apps.indices.contains(j) else { return }
        apps.swapAt(i, j)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(apps.compactMap(\.bundleID), forKey: "tracked")
    }

    /// Regular apps that are running now and not in the pill yet, for the + menu.
    var addableApps: [NSRunningApplication] {
        _ = runningChanged
        let tracked = Set(apps.compactMap(\.bundleID))
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { app in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                      !tracked.contains(id), seen.insert(id).inserted else { return false }
                return true
            }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    var mood: Mood {
        if apps.contains(where: \.unseen) { return .happy }
        if apps.contains(where: { if case .working = $0.status { return true }; return false }) { return .busy }
        return .sleepy
    }

    // MARK: Switching

    func open(_ id: String) {
        guard let t = app(id) else { return }
        if let bundle = t.bundleID ?? t.openBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        }
        markSeen(id)
        panelOpen = false
    }

    /// Opens the app that finished most recently and is still unread.
    func openLatestDone() {
        let latest = apps.filter(\.unseen).max { a, b in doneDate(a) < doneDate(b) }
        if let latest { open(latest.id) }
    }

    private func doneDate(_ t: Tracked) -> Date {
        if case .done(let at) = t.status { return at }
        return .distantPast
    }

    func markSeen(_ id: String) {
        guard let i = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[i].unseen = false
        if announcing == id { announcing = nil }
    }

    private func appActivated(_ bundleID: String?) {
        guard let bundleID else { return }
        for t in apps where t.bundleID == bundleID || t.openBundleID == bundleID { markSeen(t.id) }
    }

    private func isFrontmost(_ t: Tracked) -> Bool {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return front != nil && (front == t.bundleID || front == t.openBundleID)
    }

    // MARK: Status updates

    /// Called by the watcher with what it saw in each running tracked app.
    func ingest(_ probes: [String: Probe]) {
        for i in apps.indices where apps[i].bundleID != nil {
            let id = apps[i].id
            guard let p = probes[id] else {
                // Not running: drop a stale working state.
                if case .working = apps[i].status { apps[i].status = .idle }
                continue
            }
            if var title = p.title, !title.isEmpty {
                // Browsers append their own name: "Fix the login bug - Google Chrome".
                for sep in [" - ", " — ", " – "] where title.hasSuffix(sep + apps[i].name) {
                    title = String(title.dropLast(sep.count + apps[i].name.count))
                }
                if apps[i].title != title { apps[i].title = title }
            }

            let ended = p.sessions.map { updateSessions(i, $0) } ?? []
            if p.sessions != nil || p.step != nil { placeStep(i, p.step, focused: p.focused) }
            if p.working || !apps[i].sessions.isEmpty {
                misses[id] = 0
                if case .working = apps[i].status {} else { apps[i].status = .working(since: Date()) }
                // One conversation finished while others are still going.
                if let last = ended.last { finishSession(i, last) }
            } else if case .working = apps[i].status {
                if let last = ended.last {
                    apps[i].lastDone = last
                    finish(id, note: nil)
                } else {
                    // Two quiet polls in a row so a brief flicker of the stop button is not a false "done".
                    misses[id, default: 0] += 1
                    if misses[id]! >= 2 { finish(id, note: nil) }
                }
            }
            if !apps[i].isWorking, apps[i].step != nil { apps[i].step = nil }

            // A new or bigger Dock badge also means something finished.
            let badge = p.badge ?? ""
            if let old = badges[id], !badge.isEmpty, badge != old, (Int(badge) ?? 1) > (Int(old) ?? 0) {
                finish(id, note: nil)
            }
            badges[id] = badge
        }
    }

    /// Takes the conversations the app lists as running now; returns the ones that have finished.
    /// A conversation must be missing from two reads in a row, so a list that redraws is not a false "done".
    private func updateSessions(_ i: Int, _ now: [String]) -> [String] {
        let id = apps[i].id
        let old = apps[i].sessions
        var keep: [Session] = now.map { title in old.first { $0.title == title } ?? Session(title: title) }
        var ended: [String] = []
        for title in now { sessionMisses[id + "\n" + title] = nil }
        for s in old where !now.contains(s.title) {
            let key = id + "\n" + s.title
            sessionMisses[key, default: 0] += 1
            if sessionMisses[key]! >= 2 { sessionMisses[key] = nil; ended.append(s.title) } else { keep.append(s) }
        }
        if apps[i].sessions != keep { apps[i].sessions = keep }
        return ended
    }

    /// Puts the app's current step on the conversation that is open on screen, or on the app itself.
    private func placeStep(_ i: Int, _ step: String?, focused: String?) {
        if let k = apps[i].sessions.firstIndex(where: { $0.title == focused }) ?? (apps[i].sessions.count == 1 ? 0 : nil) {
            if apps[i].sessions[k].step != step { apps[i].sessions[k].step = step }
            if apps[i].step != nil { apps[i].step = nil }
        } else if apps[i].step != step {
            apps[i].step = step
        }
    }

    private func finishSession(_ i: Int, _ title: String) {
        apps[i].lastDone = title
        guard !isFrontmost(apps[i]) else { return }
        apps[i].unseen = true
        announce(apps[i].id)
    }

    /// Local hook: GET /done, /working, /idle with ?app=Name[&note=...][&open=bundle.id]
    func hook(_ path: String, _ q: [String: String]) -> Bool {
        guard let raw = q["app"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return false }
        let name = String(raw.prefix(40))
        let id = findOrAddHookApp(name: name, openBundleID: q["open"])
        guard let i = apps.firstIndex(where: { $0.id == id }) else { return false }
        switch path {
        case "/working":
            apps[i].status = .working(since: Date())
            apps[i].note = q["note"]
        case "/done":
            finish(id, note: q["note"])
        case "/idle":
            apps[i].status = .idle
            apps[i].unseen = false
            if announcing == id { announcing = nil }
        default:
            return false
        }
        return true
    }

    private func findOrAddHookApp(name: String, openBundleID: String?) -> String {
        let lower = name.lowercased()
        if let t = apps.first(where: { $0.name.lowercased() == lower }) { return t.id }
        let icon: NSImage
        if let openBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: openBundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = Self.sparkleIcon
        }
        let t = Tracked(id: "hook:" + lower, name: name, openBundleID: openBundleID, icon: icon)
        apps.append(t)
        return t.id
    }

    private static let sparkleIcon: NSImage = {
        let size = NSSize(width: 64, height: 64)
        return NSImage(size: size, flipped: false) { rect in
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 6, dy: 6), xRadius: 14, yRadius: 14)
            NSColor.white.setFill()
            box.fill()
            NSColor(Theme.ink).setStroke()
            box.lineWidth = 3
            box.stroke()
            let config = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
                .applying(.init(paletteColors: [NSColor(Theme.ink)]))
            if let symbol = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = symbol.size
                symbol.draw(in: NSRect(x: (rect.width - s.width) / 2, y: (rect.height - s.height) / 2, width: s.width, height: s.height))
            }
            return true
        }
    }()

    private func finish(_ id: String, note: String?) {
        guard let i = apps.firstIndex(where: { $0.id == id }) else { return }
        misses[id] = 0
        apps[i].status = .done(at: Date())
        if let note { apps[i].note = note }
        // Stay quiet when you are already looking at it.
        guard !isFrontmost(apps[i]) else { return }
        apps[i].unseen = true
        announce(id)
    }

    private func announce(_ id: String) {
        announcing = id
        if soundOn { NSSound(named: "Pop")?.play() }
        hideAnnouncement?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { if self?.announcing == id { self?.announcing = nil } }
        }
        hideAnnouncement = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 9, execute: work)
    }

    // MARK: UI helpers

    func setHover(_ id: String, _ inside: Bool) {
        if inside { hovered = id } else if hovered == id { hovered = nil }
    }

    func requestAccess(openSettings: Bool) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options), openSettings,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Add to Pip"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier { add(id) }
    }

    // MARK: Settings

    var openAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
            objectWillChange.send()
        }
    }

    /// What the strip and panel show: apps that are open, and script-reported rows while they have news.
    var visibleApps: [Tracked] {
        _ = runningChanged
        return apps.filter { t in t.bundleID == nil ? (t.isWorking || t.unseen) : isRunning(t) }
    }

    func isRunning(_ t: Tracked) -> Bool {
        guard let b = t.bundleID else { return true }
        _ = runningChanged
        return !NSRunningApplication.runningApplications(withBundleIdentifier: b).isEmpty
    }

    func statusText(_ t: Tracked) -> String {
        switch t.status {
        case .working: return "working…"
        case .done(let at):
            if t.unseen { return "done · tap to see" }
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            return "done " + f.localizedString(for: at, relativeTo: Date())
        case .idle:
            return isRunning(t) ? "idle" : "not open"
        }
    }

    // MARK: Monitor panel

    func badge(_ t: Tracked) -> Badge {
        if t.unseen { return ("READY", Theme.readyBg, Theme.readyFg) }
        switch t.status {
        case .working: return ("WORKING", Theme.workingBg, Theme.workingFg)
        case .done: return ("DONE", Theme.quietBg, Theme.quietFg)
        case .idle: return (isRunning(t) ? "IDLE" : "NOT OPEN", Theme.quietBg, Theme.quietFg)
        }
    }

    var activeSummary: String {
        let n = visibleApps.reduce(0) { n, t in n + max(t.sessions.count + (t.unseen ? 1 : 0), t.unseen || t.isWorking ? 1 : 0) }
        return n == 0 ? "ALL QUIET" : n == 1 ? "1 CHAT ACTIVE" : "\(n) CHATS ACTIVE"
    }

    /// The conversation's name: the one that just finished, the ones running, or the window title.
    func cardTitle(_ t: Tracked) -> String {
        if t.unseen, let done = t.lastDone { return done }
        if t.sessions.count == 1 { return t.sessions[0].title }
        if t.sessions.count > 1 { return "\(t.name) · \(t.sessions.count) chats" }
        if case .done = t.status, let done = t.lastDone { return done }
        if let title = t.title, !title.isEmpty, title != t.name { return title }
        return t.name
    }

    /// "Now: Running the tests · 4 min", or "Working for 4 min" when the step is not known.
    func sessionDetail(_ s: Session) -> String {
        let minutes = Int(Date().timeIntervalSince(s.since) / 60)
        if let step = s.step { return "Now: " + step + (minutes >= 1 ? " · \(minutes) min" : "") }
        return minutes < 1 ? "Working on it…" : "Working for \(minutes) min"
    }

    func cardDetail(_ t: Tracked) -> String {
        if let note = t.note, !note.isEmpty { return note }
        let what: String
        switch t.status {
        case .working where t.unseen && !t.sessions.isEmpty:
            what = t.sessions.count == 1 ? "\(t.sessions[0].title) still running" : "\(t.sessions.count) more still running"
        case .working where t.sessions.count > 1:
            return t.sessions.map { "• " + $0.title + ($0.step.map { " — " + $0 } ?? "") }.joined(separator: "\n")
        case .working where t.sessions.count == 1:
            return sessionDetail(t.sessions[0])
        case .working(let since) where t.step != nil:
            what = "now: " + t.step! + (Date().timeIntervalSince(since) >= 60 ? " · \(Int(Date().timeIntervalSince(since) / 60)) min" : "")
        case .working(let since):
            let minutes = Int(Date().timeIntervalSince(since) / 60)
            what = minutes < 1 ? "working on it…" : "working for \(minutes) min"
        case .done(let at):
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            what = "finished " + f.localizedString(for: at, relativeTo: Date())
        case .idle:
            what = isRunning(t) ? "waiting for you" : "not open"
        }
        return cardTitle(t) == t.name ? what.prefix(1).uppercased() + what.dropFirst() : "\(t.name) · \(what)"
    }
}
