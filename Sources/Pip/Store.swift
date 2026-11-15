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

/// A finished chat that still needs you: "ready" until you have looked at it, then "your turn" until you
/// reply (it runs again), dismiss it, or it gets old.
struct Waiting: Equatable {
    var title: String
    var last: String?           // the last thing it was doing, so you remember where it stood
    var at = Date()             // when it finished
    var read = false            // you spent a real look at it (not just a glance)
    var since: Date?            // when you left it after reading: the clock for the nudge
    var nudged = false
}

struct Tracked: Identifiable, Equatable {
    let id: String              // bundle ID, or "hook:<name>" for apps that report through the local hook
    var name: String
    var bundleID: String?
    var openBundleID: String?   // hook entries: the app to bring forward on click
    var icon: NSImage
    var status: Status = .idle
    var waiting: [Waiting] = [] // finished chats that still need you, oldest first
    var listsChats = false      // the app names its running chats (Claude's sidebar), so finishes are per chat
    var fromRoster = false      // followed through the app's own list (Grok Bot), not its window
    var focused: String?        // the chat open on screen in that app, when it says
    var title: String?          // front window title, usually the conversation name
    var note: String?           // message sent with a hook
    var sessions: [Session] = []    // conversations the app lists as running, when it shows them (Claude's sidebar)
    var step: String?               // what the app says it is doing, when it is not tied to a listed conversation
}

extension Tracked {
    var isWorking: Bool { if case .working = status { return true }; return false }
    /// Finished and not looked at yet.
    var unseen: Bool { waiting.contains { !$0.read } }
    /// Looked at, but you have not picked it back up.
    var yourTurn: Bool { !waiting.isEmpty && !unseen }
    var newestUnread: Waiting? { waiting.last { !$0.read } }
}

/// Everything the pill and bubble show. Main thread only.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var apps: [Tracked] = []
    @Published var announcing: String?
    @Published var announceTitle: String?   // the chat the card is about
    @Published var announceNudge = false    // "still waiting on you" rather than "ready"
    @Published var hovered: String?
    @Published var panelOpen = false
    @Published var update: String?          // a newer Pip version is available
    @Published var updating = false
    @Published var axTrusted = AXIsProcessTrusted()
    @Published var runningChanged = 0
    /// The edge the strip sits on. Older settings only knew left or right.
    @Published var edge: PipEdge = PipEdge(rawValue: UserDefaults.standard.string(forKey: "pillEdge") ?? "")
        ?? ((UserDefaults.standard.object(forKey: "pillOnRight") as? Bool ?? true) ? .right : .left) {
        didSet { UserDefaults.standard.set(edge.rawValue, forKey: "pillEdge") }
    }
    /// Folded down to just the face.
    @Published var collapsed = UserDefaults.standard.bool(forKey: "collapsed") {
        didSet { UserDefaults.standard.set(collapsed, forKey: "collapsed") }
    }
    @Published var soundOn = UserDefaults.standard.object(forKey: "sound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundOn, forKey: "sound") }
    }

    private var misses: [String: Int] = [:]
    private var visitStart: [String: Date] = [:]
    // Shorter visits do not count as having looked; away this long with a chat waiting on you: one reminder.
    // Both can be shortened for testing: defaults write dev.pipbuddy.pip glanceSeconds/nudgeSeconds <n>.
    static var glance: TimeInterval { UserDefaults.standard.object(forKey: "glanceSeconds") as? Double ?? 15 }
    static var nudgeAfter: TimeInterval { UserDefaults.standard.object(forKey: "nudgeSeconds") as? Double ?? 10 * 60 }
    static let forgetAfter: TimeInterval = 8 * 3600
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

    /// Brings the app forward and, for apps that list their chats (Claude), opens `chat` itself.
    func open(_ id: String, chat: String? = nil) {
        guard let t = app(id) else { return }
        if let bundle = t.bundleID ?? t.openBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
            if let chat, t.listsChats, let b = t.bundleID {
                // A moment for the window to come forward before pressing the chat's row.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    MainActor.assumeIsolated { AppDelegate.shared.openChat(bundleID: b, title: chat) }
                }
            }
        }
        // Opening is not reading: the chat counts as looked at after a real visit (see `tickVisits`).
        if announcing == id { announcing = nil }
        panelOpen = false
    }

    /// Opens the newest unread finished chat, or else the newest one waiting on you.
    func openLatestDone() {
        let unread = apps.compactMap { t in t.newestUnread.map { (t.id, $0.at) } }
        let waiting = apps.compactMap { t in t.waiting.last.map { (t.id, $0.at) } }
        if let latest = (unread.isEmpty ? waiting : unread).max(by: { $0.1 < $1.1 }) {
            open(latest.0, chat: chatToOpen(app(latest.0)!))
        }
    }

    /// The chat a click on the app's tile means: the newest one waiting on you, or the one running.
    func chatToOpen(_ t: Tracked) -> String? {
        t.newestUnread?.title ?? t.waiting.last?.title ?? (t.sessions.count == 1 ? t.sessions[0].title : nil)
    }

    /// Done with a waiting chat: it leaves the strip. `title` nil clears all of the app's.
    func dismiss(_ id: String, title: String? = nil) {
        guard let i = apps.firstIndex(where: { $0.id == id }) else { return }
        apps[i].waiting.removeAll { title == nil || $0.title == title }
        if announcing == id, apps[i].waiting.isEmpty { announcing = nil }
    }

    private func appActivated(_ bundleID: String?) {
        guard let bundleID else { return }
        for t in apps where (t.bundleID == bundleID || t.openBundleID == bundleID) && announcing == t.id { announcing = nil }
    }

    /// Runs every poll. Time spent in an app turns its finished chats from "ready" into "your turn";
    /// leaving starts the clock for one reminder; old ones are let go.
    private func tickVisits() {
        let now = Date()
        for i in apps.indices {
            let id = apps[i].id
            let here = isFrontmost(apps[i])
            if here {
                let start = visitStart[id] ?? now
                visitStart[id] = start
                if now.timeIntervalSince(start) >= Self.glance {
                    for k in apps[i].waiting.indices where !apps[i].waiting[k].read {
                        // In an app that lists chats, only the chat on screen counts as looked at.
                        if apps[i].listsChats, let f = apps[i].focused, apps[i].waiting[k].title != f { continue }
                        apps[i].waiting[k].read = true
                        Self.log("\(apps[i].name): looked at \"\(apps[i].waiting[k].title)\" (your turn)")
                    }
                }
                for k in apps[i].waiting.indices where apps[i].waiting[k].since != nil { apps[i].waiting[k].since = nil }
            } else if visitStart.removeValue(forKey: id) != nil {
                for k in apps[i].waiting.indices where apps[i].waiting[k].read && apps[i].waiting[k].since == nil {
                    apps[i].waiting[k].since = now
                }
            }
            for k in apps[i].waiting.indices.reversed() {
                let w = apps[i].waiting[k]
                if now.timeIntervalSince(w.at) > Self.forgetAfter { apps[i].waiting.remove(at: k); continue }
                if w.read, !w.nudged, !here, let s = w.since, now.timeIntervalSince(s) >= Self.nudgeAfter {
                    apps[i].waiting[k].nudged = true
                    Self.log("\(apps[i].name): nudge for \"\(w.title)\"")
                    announce(id, title: w.title, nudge: true)
                }
            }
        }
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
            // Apps followed through their own list (Grok Bot) get their state from `ingestBots`.
            if apps[i].fromRoster { continue }
            if var title = p.title, !title.isEmpty {
                // Browsers append their own name: "Fix the login bug - Google Chrome".
                for sep in [" - ", " — ", " – "] where title.hasSuffix(sep + apps[i].name) {
                    title = String(title.dropLast(sep.count + apps[i].name.count))
                }
                if apps[i].title != title { apps[i].title = title }
            }

            if p.sessions != nil, !apps[i].listsChats { apps[i].listsChats = true }
            if apps[i].focused != p.focused, p.sessions != nil { apps[i].focused = p.focused }
            let ended = p.sessions.map { updateSessions(i, $0) } ?? []
            if p.sessions != nil || p.step != nil { placeStep(i, p.step, focused: p.focused) }
            // A chat that runs again has been picked back up.
            for s in apps[i].sessions { apps[i].waiting.removeAll { $0.title == s.title } }
            if p.working || !apps[i].sessions.isEmpty {
                misses[id] = 0
                if case .working = apps[i].status {} else {
                    apps[i].status = .working(since: Date())
                    if !apps[i].listsChats { apps[i].waiting.removeAll() }
                }
                // One conversation finished while others are still going.
                for s in ended { finishSession(i, s) }
            } else if case .working = apps[i].status {
                if !ended.isEmpty {
                    for s in ended.dropLast() { finishSession(i, s) }
                    finish(id, note: nil, chat: ended.last)
                } else {
                    // Two quiet polls in a row so a brief flicker of the stop button is not a false "done".
                    misses[id, default: 0] += 1
                    if misses[id]! >= 2 { finish(id, note: nil) }
                }
            }
            if !apps[i].isWorking, apps[i].step != nil { apps[i].step = nil }
            logChange(apps[i], p)

            // A new or bigger Dock badge also means something finished.
            let badge = p.badge ?? ""
            if let old = badges[id], !badge.isEmpty, badge != old, (Int(badge) ?? 1) > (Int(old) ?? 0) {
                finish(id, note: nil)
            }
            badges[id] = badge
        }
        tickVisits()
    }

    private var bots: [String: BotState] = [:]

    /// Grok Bot's bots, read from its local list: which are working, which replied, which you've read.
    func ingestBots(_ list: [BotState]) {
        guard let i = apps.firstIndex(where: { $0.bundleID == GrokRoster.bundleID }) else { return }
        let id = apps[i].id
        if !apps[i].fromRoster { apps[i].fromRoster = true; apps[i].listsChats = true }
        let now = list.filter(\.working).map(\.name)
        let keep = now.map { name in apps[i].sessions.first { $0.title == name } ?? Session(title: name) }
        if apps[i].sessions != keep { apps[i].sessions = keep }
        for name in now { apps[i].waiting.removeAll { $0.title == name } }
        for b in list {
            defer { bots[b.name] = b }
            guard let old = bots[b.name] else { continue }   // first read: just learn the current state
            if b.lastReply != old.lastReply, !b.lastReply.isEmpty, b.unread > 0 {
                addWaiting(i, Waiting(title: b.name, last: b.needsAnswer ? "Needs your answer" : "Replied"))
            } else if b.unread == 0, old.unread > 0, let k = apps[i].waiting.firstIndex(where: { $0.title == b.name }) {
                // You read it in Grok Bot.
                apps[i].waiting[k].read = true
            }
        }
        if !now.isEmpty {
            if case .working = apps[i].status {} else { apps[i].status = .working(since: Date()) }
        } else if apps[i].isWorking {
            apps[i].status = .done(at: Date())
        }
        logBots(apps[i], id)
    }

    private func logBots(_ t: Tracked, _ id: String) {
        let key = "working=[\(t.sessions.map(\.title).joined(separator: "; "))] waiting=\(t.waiting.map { "\($0.title)\($0.read ? "(read)" : "")" })"
        guard lastLogged[id] != key else { return }
        lastLogged[id] = key
        Self.log("\(t.name) (list): \(key)")
    }

    // MARK: Log

    private var lastLogged: [String: String] = [:]

    /// One line per change in what Pip sees, in ~/Library/Logs/Pip.log, for finding out why something was missed.
    /// Stays on this Mac; holds app names, chat titles and states, no message text.
    private func logChange(_ t: Tracked, _ p: Probe) {
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let state = "\(t.isWorking ? "working" : t.unseen ? "ready" : "quiet") stop=\(p.working ? 1 : 0) "
            + "chats=[\(t.sessions.map(\.title).joined(separator: "; "))] read=\(p.sessions == nil ? "quick" : "full")"
        let key = state.replacingOccurrences(of: " read=quick", with: "").replacingOccurrences(of: " read=full", with: "")
        guard lastLogged[t.id] != key else { return }
        lastLogged[t.id] = key
        Self.log("\(t.name): \(state) front=\(front)")
    }

    nonisolated static func log(_ line: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Pip.log")
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullTime, .withFullDate, .withSpaceBetweenDateAndTime])
        let data = Data((stamp + "  " + line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            if (try? h.seekToEnd()) ?? 0 > 2_000_000 { try? h.truncate(atOffset: 0) }
            try? h.write(contentsOf: data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Takes the conversations the app lists as running now; returns the ones that have finished.
    /// A conversation must be missing from two reads in a row, so a list that redraws is not a false "done".
    private func updateSessions(_ i: Int, _ now: [String]) -> [Session] {
        let id = apps[i].id
        let old = apps[i].sessions
        var keep: [Session] = now.map { title in old.first { $0.title == title } ?? Session(title: title) }
        var ended: [Session] = []
        for title in now { sessionMisses[id + "\n" + title] = nil }
        for s in old where !now.contains(s.title) {
            let key = id + "\n" + s.title
            sessionMisses[key, default: 0] += 1
            if sessionMisses[key]! >= 2 { sessionMisses[key] = nil; ended.append(s) } else { keep.append(s) }
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

    /// One chat finished while the app may still be busy with others.
    private func finishSession(_ i: Int, _ s: Session) {
        addWaiting(i, Waiting(title: s.title, last: s.step))
    }

    /// Adds a finished chat. Announced unless you are already in that app, where you will see it yourself;
    /// either way it stays until you have really looked and then picked it back up.
    private func addWaiting(_ i: Int, _ w: Waiting) {
        apps[i].waiting.removeAll { $0.title == w.title }
        apps[i].waiting.append(w)
        Self.log("\(apps[i].name): finished \"\(w.title)\"\(w.last.map { " (last: \($0))" } ?? "")")
        guard !isFrontmost(apps[i]) else { return }
        announce(apps[i].id, title: w.title, nudge: false)
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
            apps[i].waiting.removeAll()
        case "/done":
            finish(id, note: q["note"])
        case "/idle":
            apps[i].status = .idle
            apps[i].waiting.removeAll()
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

    private func finish(_ id: String, note: String?, chat: Session? = nil) {
        guard let i = apps.firstIndex(where: { $0.id == id }) else { return }
        misses[id] = 0
        let step = chat?.step ?? apps[i].step
        apps[i].status = .done(at: Date())
        if let note { apps[i].note = note }
        let title = chat?.title ?? workingTitle(apps[i])
        addWaiting(i, Waiting(title: title, last: note ?? step))
    }

    private func announce(_ id: String, title: String?, nudge: Bool) {
        announcing = id
        announceTitle = title
        announceNudge = nudge
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

    /// What the strip and panel show: only apps in the middle of something, or that just finished and
    /// you have not looked at yet. Open but quiet apps stay out of the way.
    var visibleApps: [Tracked] {
        apps.filter { $0.isWorking || !$0.waiting.isEmpty }
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
            if t.yourTurn { return "your turn" }
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
        if t.isWorking { return ("WORKING", Theme.workingBg, Theme.workingFg) }
        if t.yourTurn { return Self.turnBadge }
        switch t.status {
        case .working: return ("WORKING", Theme.workingBg, Theme.workingFg)
        case .done: return ("DONE", Theme.quietBg, Theme.quietFg)
        case .idle: return (isRunning(t) ? "IDLE" : "NOT OPEN", Theme.quietBg, Theme.quietFg)
        }
    }

    var activeSummary: String {
        let n = visibleApps.reduce(0) { n, t in n + t.waiting.count + max(t.sessions.count, t.isWorking ? 1 : 0) }
        return n == 0 ? "ALL QUIET" : n == 1 ? "1 CHAT ACTIVE" : "\(n) CHATS ACTIVE"
    }

    /// The conversation's name: the one that just finished, the ones running, or the window title.
    func cardTitle(_ t: Tracked) -> String {
        if let w = t.newestUnread { return w.title }
        if t.isWorking { return workingTitle(t) }
        if let w = t.waiting.last { return w.title }
        return workingTitle(t)
    }

    /// The running chat's name, "Claude · 2 chats", the window title, or the app's name.
    func workingTitle(_ t: Tracked) -> String {
        if t.sessions.count == 1 { return t.sessions[0].title }
        if t.sessions.count > 1 { return "\(t.name) · \(t.sessions.count) chats" }
        if let title = t.title, !title.isEmpty, title != t.name { return title }
        return t.name
    }

    /// "Now: Running the tests · 4 min", or "Working for 4 min" when the step is not known.
    func sessionDetail(_ s: Session) -> String {
        let minutes = Int(Date().timeIntervalSince(s.since) / 60)
        if let step = s.step { return "Now: " + step + (minutes >= 1 ? " · \(minutes) min" : "") }
        return minutes < 1 ? "Working on it…" : "Working for \(minutes) min"
    }

    func workingDetail(_ t: Tracked) -> String {
        if t.sessions.count > 1 {
            return t.sessions.map { "• " + $0.title + ($0.step.map { " — " + $0 } ?? "") }.joined(separator: "\n")
        }
        if t.sessions.count == 1 { return sessionDetail(t.sessions[0]) }
        if let note = t.note, !note.isEmpty { return note }
        guard case .working(let since) = t.status else { return "" }
        let minutes = Int(Date().timeIntervalSince(since) / 60)
        if let step = t.step { return "Now: " + step + (minutes >= 1 ? " · \(minutes) min" : "") }
        return minutes < 1 ? "Working on it…" : "Working for \(minutes) min"
    }

    /// Where a finished chat stood, and how long it has waited: "Last: Pushed the fix · waiting 12 min".
    func waitingDetail(_ w: Waiting) -> String {
        var parts: [String] = []
        if w.nudged { parts.append("Still waiting on you") }
        parts.append(w.last.map { "Last: " + $0 } ?? (w.read ? "Your turn" : "Finished"))
        let from = w.since ?? w.at
        let minutes = Int(Date().timeIntervalSince(from) / 60)
        if !w.read { parts.append(minutes < 1 ? "just now" : "\(minutes) min ago") }
        else if w.since != nil { parts.append(minutes < 1 ? "waiting" : "waiting \(minutes) min") }
        return parts.joined(separator: " · ")
    }

    static let turnBadge: Badge = ("YOUR TURN", Theme.tile, Theme.workingFg)

    /// One line for the hover card; a short list when the app has several chats going.
    func cardDetail(_ t: Tracked) -> String {
        let count = t.waiting.count + max(t.sessions.count, t.isWorking ? 1 : 0)
        if count > 1 {
            var lines = t.waiting.reversed().map { "• \($0.title) — \($0.read ? "your turn" : "ready")" }
            if t.sessions.isEmpty, t.isWorking { lines.append("• \(workingTitle(t)) — working") }
            lines += t.sessions.map { "• " + $0.title + " — " + ($0.step ?? "working") }
            return lines.joined(separator: "\n")
        }
        if let w = t.newestUnread { return waitingDetail(w) }
        if t.isWorking { return workingDetail(t) }
        if let w = t.waiting.last { return waitingDetail(w) }
        return isRunning(t) ? "Waiting for you" : "Not open"
    }
}
