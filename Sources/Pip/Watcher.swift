import AppKit
import ApplicationServices

struct Probe {
    var working: Bool
    var title: String?
    var badge: String? = nil
    /// Titles of conversations the app lists as running (Claude's sidebar marks them "Running").
    /// nil when this poll did not look, so the previous list still stands.
    var sessions: [String]? = nil
    /// What the app says it is doing right now, like Claude's "Running tests" step row.
    var step: String? = nil
    /// The conversation open on screen, so `step` can be put on the right one.
    var focused: String? = nil
    /// Pip couldn't read the app's windows this time (say, a full-screen window on another desktop it hasn't
    /// found yet). Nothing about the app changed; it just couldn't look.
    var unknown = false
}

/// Polls tracked apps through the Accessibility API.
///
/// An app counts as working while its window shows a "Stop" button (Claude, ChatGPT, Grok and most
/// chat apps show one while they generate), and as done when that button goes away. A new Dock badge
/// on the app also counts as done.
@MainActor
final class Watcher {
    private let store: Store
    private let worker = Worker()
    private var timer: Timer?
    private var busy = false

    init(store: Store) { self.store = store }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
    }

    private func targets() -> [Worker.Target] {
        store.apps.compactMap { t in
            guard let id = t.bundleID,
                  let running = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return nil }
            return Worker.Target(id: id, name: running.localizedName ?? t.name, pid: running.processIdentifier)
        }
    }

    private func tick() {
        let trusted = AXIsProcessTrusted()
        if store.axTrusted != trusted { store.axTrusted = trusted }
        guard trusted, !busy else { return }
        busy = true
        let targets = targets()
        let readBots = targets.contains { $0.id == GrokRoster.bundleID }
        discoveryTick += 1
        let candidates = store.findAgents && discoveryTick % 2 == 0 ? nextCandidates() : []
        worker.queue.async { [worker] in
            let probes = worker.probeAll(targets)
            let bots = readBots ? GrokRoster.read() : nil
            let found = worker.discover(candidates)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if let bots { self.store.ingestBots(bots) }
                    for id in found { self.store.discovered(id) }
                    self.store.ingest(probes)
                    self.busy = false
                }
            }
        }
    }

    private var nextCandidate = 0
    private var discoveryTick = 0

    /// Two running apps Pip doesn't watch yet, taking turns, so any app with an agent at work gets noticed
    /// within a few seconds without reading every app on every poll.
    private func nextCandidates() -> [Worker.Target] {
        let tracked = Set(store.apps.compactMap(\.bundleID))
        let pool = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier
            else { return false }
            return !tracked.contains(id) && !store.ignored.contains(id) && !Worker.neverAgents.contains(id)
        }
        guard !pool.isEmpty else { return [] }
        return (0..<min(2, pool.count)).map { k in
            let app = pool[(nextCandidate + k) % pool.count]
            return Worker.Target(id: app.bundleIdentifier!, name: app.localizedName ?? "", pid: app.processIdentifier)
        }.also { nextCandidate = (nextCandidate + 2) % max(pool.count, 1) }
    }

    /// Brings a chat on screen in an app that lists its chats, by pressing its row in the sidebar.
    func openChat(bundleID: String, title: String) {
        guard let r = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return }
        let pid = r.processIdentifier
        worker.queue.async { [worker] in
            // An app opened from the Dock may need a moment to bring its window back.
            var ok = false
            for attempt in 0..<4 where !ok {
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
                ok = worker.pressChat(pid: pid, title: title)
            }
            Store.log("open chat \"\(title)\": \(ok ? "pressed its row" : "row not found, opened the app only")")
        }
    }

    /// Text describing what Pip sees in each tracked app, for when detection misses an app.
    func diagnostics(_ completion: @escaping (String) -> Void) {
        let targets = targets()
        let trusted = store.axTrusted
        worker.queue.async { [worker] in
            let text = worker.diagnostics(targets, trusted: trusted)
            DispatchQueue.main.async { completion(text) }
        }
    }
}

/// Runs on its own queue: Accessibility calls into other apps can block.
final class Worker: @unchecked Sendable {
    struct Target { let id: String; let name: String; let pid: pid_t }

    let queue = DispatchQueue(label: "pip.watcher", qos: .utility)
    private var enhanced = Set<pid_t>()
    private var cachedStop: [pid_t: AXUIElement] = [:]
    private var sessionApps = Set<pid_t>()   // apps that list running conversations by name
    private var polls = 0
    private static let maxNodes = 3000  // the walk starts at the bottom, where the composer is
    private static let attrs = [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                                kAXHelpAttribute, kAXIdentifierAttribute, kAXChildrenAttribute] as CFArray

    func probeAll(_ targets: [Target]) -> [String: Probe] {
        let badges = dockBadges()
        refreshWindowCounts()
        polls += 1
        var result: [String: Probe] = [:]
        for t in targets {
            var p = Self.terminals.contains(t.id) ? terminalProbe(t.pid) : probe(t.pid)
            p.badge = badges[t.name]
            result[t.id] = p
        }
        return result
    }

    private func appElement(_ pid: pid_t, enhance: Bool = true) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        if enhance, !enhanced.contains(pid) {
            // Electron apps (Claude among them) and Chrome only build the page's accessibility tree when asked.
            // Electron takes AXManualAccessibility; browsers that reject it take AXEnhancedUserInterface.
            if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) != .success {
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
            enhanced.insert(pid)
        }
        return app
    }

    // MARK: Finding agents in any app

    /// Terminal apps: agents there are found by their "esc to interrupt" line, one card per window.
    static let terminals: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                                         "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty",
                                         "co.zeit.hyper", "com.github.wez.wezterm"]
    /// Apps whose "Stop" means something else (playing, recording, running a build), and system apps.
    static let neverAgents: Set<String> = ["com.apple.finder", "com.apple.dock", "com.apple.systempreferences",
        "com.apple.ActivityMonitor", "com.apple.Console", "com.spotify.client", "com.apple.Music", "com.apple.TV",
        "com.apple.QuickTimePlayerX", "org.videolan.vlc", "com.apple.Photos", "com.apple.Preview",
        "com.apple.VoiceMemos", "com.apple.dt.Xcode", "com.apple.iphonesimulator", "us.zoom.xos",
        "com.apple.FaceTime", "com.apple.Podcasts", "com.apple.garageband10", "com.apple.iMovieApp"]
    /// Browsers, where web agents (ChatGPT, Claude, Manus…) run in a tab.
    static let browsers: Set<String> = ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser",
        "company.thebrowser.dia", "com.brave.Browser", "com.microsoft.edgemac", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi", "org.mozilla.firefox"]
    /// Lines agents print while busy, in a terminal or an app.
    static let busyHints = ["esc to interrupt", "esc to cancel", "ctrl+c to interrupt", "ctrl-c to interrupt",
                            "esc to stop", "press esc to stop"]

    /// Which of these not-yet-watched apps has an agent at work right now. Uses only strong signals:
    /// a short "Stop generating"-style button, a conversation marked "Running", or an "esc to interrupt" line.
    func discover(_ candidates: [Target]) -> [String] {
        candidates.filter { t in
            if Self.terminals.contains(t.id) { return !terminalAgents(t.pid).isEmpty }
            // Ask an app for its full tree only when it looks like an AI tool or a browser; making every
            // Electron app build one would cost them memory for nothing.
            let enhance = Self.browsers.contains(t.id)
                || (t.id + " " + t.name).range(of: #"(?i)(claude|cursor|copilot|codex|gpt|chat|grok|gemini|\bamp\b|agent|windsurf|perplexity|manus|devin|\bai\b|bot|code|zed)"#,
                                              options: .regularExpression) != nil
            var hit = false
            walk(appElement(t.pid, enhance: enhance), maxNodes: 1000) { el, role, label in
                let text = label.trimmingCharacters(in: .whitespaces)
                if role == kAXButtonRole, Self.isAgentStop(text) || Self.runningSession(el, text) != nil { hit = true }
                else if role == kAXStaticTextRole, let v: String = attr(el, kAXValueAttribute), v.count < 120,
                        Self.busyHints.contains(where: v.lowercased().contains) { hit = true }
                return !hit
            }
            if hit { Store.log("found an agent at work in \(t.name)") }
            return hit
        }.map(\.id)
    }

    /// Stricter than `isStopLabel`: only the buttons chat and agent apps show while generating.
    static func isAgentStop(_ label: String) -> Bool {
        var s = label.lowercased()
        // Title and description often repeat: "Stop Stop".
        let half = s.split(separator: " ", omittingEmptySubsequences: true)
        if half.count % 2 == 0, half.count >= 2,
           half[..<(half.count / 2)].elementsEqual(half[(half.count / 2)...]) { s = half[..<(half.count / 2)].joined(separator: " ") }
        return s.range(of: #"^(stop( generating| response| responding| streaming| the response| run| agent| this task| task)?|interrupt( agent)?|cancel (generation|run|response))$"#,
                       options: .regularExpression) != nil
    }

    /// A terminal's windows: the ones whose visible text shows an agent's "esc to interrupt" line, as a list
    /// of conversations named after the window. Pip reads only the visible part, only to look for that line.
    private func terminalProbe(_ pid: pid_t) -> Probe {
        let app = appElement(pid, enhance: false)
        let focused = (attr(app, kAXFocusedWindowAttribute) as AXUIElement?).flatMap { w in
            (attr(w, kAXTitleAttribute) as String?).map(Self.cleanWindowTitle)
        }
        let agents = terminalAgents(pid)
        return Probe(working: !agents.isEmpty, title: focused, sessions: agents, focused: focused)
    }

    private func terminalAgents(_ pid: pid_t) -> [String] {
        let windows = allWindows(pid)
        var names: [String] = []
        for w in windows {
            var busy = false
            for area in descendants(of: w, role: kAXTextAreaRole, max: 400) {
                if let text = visibleText(area)?.lowercased(), Self.busyHints.contains(where: text.contains) { busy = true; break }
            }
            guard busy else { continue }
            let title = Self.cleanWindowTitle(attr(w, kAXTitleAttribute) ?? "")
            names.append(title.isEmpty || names.contains(title) ? "Terminal window \(names.count + 1)" : title)
        }
        return names
    }

    /// For the report: each terminal window's title and how much visible text Pip could read.
    func terminalReport(_ pid: pid_t) -> String {
        let windows = allWindows(pid)
        if windows.isEmpty { return "none readable" }
        return windows.map { w in
            let areas = descendants(of: w, role: kAXTextAreaRole, max: 400)
            let text = areas.compactMap(visibleText).joined()
            let busy = Self.busyHints.contains(where: text.lowercased().contains)
            return "[\"\(Self.cleanWindowTitle(attr(w, kAXTitleAttribute) ?? ""))\" text areas: \(areas.count), visible chars: \(text.count), busy line: \(busy ? "yes" : "no")]"
        }.joined(separator: " ")
    }

    private var otherSpaceWindows: [pid_t: (Date, [AXUIElement])] = [:]

    /// An app's windows on every desktop. macOS's window list covers only the current desktop (a full-screen
    /// app is a desktop of its own), so windows elsewhere are also looked up one by one by their element
    /// number, the way window switchers do it. That lookup is cached for 15 seconds.
    func allWindows(_ pid: pid_t) -> [AXUIElement] {
        let app = appElement(pid, enhance: false)
        var windows: [AXUIElement] = attr(app, kAXWindowsAttribute) ?? []
        // macOS's own window count says whether some are elsewhere; only then look them up.
        let expected = windowCounts[pid] ?? windows.count
        guard windows.count < expected else { return windows }
        // Reuse the last lookup for 30 seconds, even when it found nothing (some apps, like Dia, show
        // nothing at all while their window is on another desktop), so the scan doesn't repeat every poll.
        if let (at, cached) = otherSpaceWindows[pid], Date().timeIntervalSince(at) < 30 {
            for w in cached where !windows.contains(where: { CFEqual($0, w) }) { windows.append(w) }
            return windows
        }
        let found = remoteWindows(pid, known: windows, want: expected)
        otherSpaceWindows[pid] = (Date(), found)
        for w in found where !windows.contains(where: { CFEqual($0, w) }) { windows.append(w) }
        return windows
    }

    private func remoteWindows(_ pid: pid_t, known: [AXUIElement], want: Int) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(0x636f636f)) { Data($0) })
        // Element numbers can run into the thousands in browsers; stop once every window is found.
        for id in UInt64(0)..<4000 where known.count + found.count < want {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
            guard let el = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(el, 0.05)
            if (attr(el, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole,
               !known.contains(where: { CFEqual($0, el) }) { found.append(el) }
        }
        return found
    }

    /// For the report: macOS's count of the app's windows, what Accessibility lists, and what the lookup finds.
    func windowReport(_ pid: pid_t) -> String {
        let ax: [AXUIElement] = attr(appElement(pid, enhance: false), kAXWindowsAttribute) ?? []
        var subroles: [String: Int] = [:]
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: UInt32(0x636f636f)) { Data($0) })
        var firstWindowID: UInt64?
        for id in UInt64(0)..<4000 {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
            guard let el = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(el, 0.05)
            guard let role: String = attr(el, kAXRoleAttribute) else { continue }
            let key = role + "/" + ((attr(el, kAXSubroleAttribute) as String?) ?? "-")
            subroles[key, default: 0] += 1
            if role == kAXWindowRole, firstWindowID == nil { firstWindowID = id }
        }
        return "macOS says \(windowCounts[pid] ?? 0), Accessibility lists \(ax.count), all-desktop lookup sees \(allWindows(pid).count); "
            + "elements by number: \(subroles.sorted { $0.key < $1.key }.prefix(8).map { "\($0.key)×\($0.value)" }.joined(separator: ", ")); first window at #\(firstWindowID.map(String.init) ?? "none")"
    }

    private var windowCounts: [pid_t: Int] = [:]

    /// How many real windows each app has, on any desktop (not toolbars, popovers or hidden helpers).
    private func refreshWindowCounts() {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        var counts: [pid_t: Int] = [:]
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, let b = w[kCGWindowBounds as String] as? [String: Any],
                  let width = b["Width"] as? CGFloat, let height = b["Height"] as? CGFloat, width >= 200, height >= 200 else { continue }
            counts[pid, default: 0] += 1
        }
        windowCounts = counts
    }

    /// A terminal title like "user — ✳ Fix the login bug — claude — 80×24" → "Fix the login bug":
    /// the part the agent set, without the user name, shell or process, size, or spinner.
    static func cleanWindowTitle(_ raw: String) -> String {
        let user = NSUserName().lowercased()
        let parts = raw.components(separatedBy: " — ").map { $0.trimmingCharacters(in: .whitespaces) }
        let useful = parts.filter { p in
            let l = p.lowercased()
            return !l.isEmpty && l != user && !l.contains("◂")
                && l.range(of: #"^\d+×\d+$"#, options: .regularExpression) == nil
                && !["-zsh", "zsh", "-bash", "bash", "fish", "sh", "login", "node"].contains(l)
        }
        // Agents mark their title with a symbol (Claude Code's ✳); prefer that part.
        let pick = useful.first { !($0.first?.isLetter ?? true) && !($0.first?.isNumber ?? true) } ?? useful.first ?? ""
        let t = String(pick.drop { !($0.isLetter || $0.isNumber) })
        return String(t.trimmingCharacters(in: .whitespaces).prefix(80))
    }

    /// The text currently on screen in a text area (not its whole scrollback).
    private func visibleText(_ el: AXUIElement) -> String? {
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXVisibleCharacterRangeAttribute as CFString, &range) == .success, let range {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, range, &out) == .success,
               let s = out as? String { return String(s.suffix(6000)) }
        }
        return (attr(el, kAXValueAttribute) as String?).map { String($0.suffix(6000)) }
    }

    private func descendants(of root: AXUIElement, role: String, max: Int) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var stack = [root]
        var seen = 0
        while let el = stack.popLast(), seen < max {
            seen += 1
            if (attr(el, kAXRoleAttribute) as String?) == role { out.append(el); continue }
            if let kids: [AXUIElement] = attr(el, kAXChildrenAttribute) { stack.append(contentsOf: kids) }
        }
        return out
    }

    /// Brings forward the window whose (cleaned) title is `title`, like a terminal running that agent.
    func raiseWindow(pid: pid_t, title: String) -> Bool {
        guard let w = allWindows(pid).first(where: { Self.cleanWindowTitle(attr($0, kAXTitleAttribute) ?? "") == title }) else { return false }
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        return AXUIElementPerformAction(w, kAXRaiseAction as CFString) == .success
    }

    private func probe(_ pid: pid_t, full: Bool = false) -> Probe {
        let app = appElement(pid)
        var title: String?
        if let win: AXUIElement = attr(app, kAXFocusedWindowAttribute) ?? attr(app, kAXMainWindowAttribute) {
            title = attr(win, kAXTitleAttribute)
        }
        // A full read every other poll (3 s) keeps the conversation list and the current step fresh.
        // In between, a cached Stop button that is still there is enough to say "working".
        if !full, polls % 2 == 1 {
            if let cached = cachedStop[pid], isStopButton(cached) { return Probe(working: true, title: title) }
            // Without a cached Stop button, only a full read can say the app stopped working.
            return Probe(working: false, title: title, sessions: nil, unknown: true)
        }
        cachedStop[pid] = nil
        var found: AXUIElement?
        var sessions: [String] = []
        var step: String?
        var focused: String?
        let nodes = walk(app) { el, role, label in
            guard role == kAXButtonRole else { return true }
            let text = label.trimmingCharacters(in: .whitespaces)
            if found == nil, Self.isStopLabel(text) { found = el }
            if let s = Self.runningSession(el, text) {
                sessions.append(s)
            } else if step == nil, text.hasSuffix(" running"), text.count > 8 {
                // Claude's step rows read "<what it is doing> running"; the walk meets the newest one first.
                step = String(text.dropLast(" running".count).prefix(90))
            }
            // The open chat's header button: "<title>, rename session" (title and description both say it).
            if focused == nil, let r = text.range(of: ", rename session") {
                focused = String(text[..<r.lowerBound])
            }
            return true
        }
        if let found { cachedStop[pid] = found }
        if !sessions.isEmpty { sessionApps.insert(pid) }
        // The app has windows, but none could be read: don't take that as "stopped working".
        if nodes == 0, (windowCounts[pid] ?? 0) > 0 { return Probe(working: false, title: title, unknown: true) }
        return Probe(working: found != nil, title: title, sessions: sessionApps.contains(pid) ? sessions : nil,
                     step: step, focused: focused)
    }

    /// Presses the sidebar row for the chat titled `title`. When the row is not in the current sidebar,
    /// tries the app's other modes (Claude's "Claude" chats and "Code" sessions), and goes back if none has it.
    func pressChat(pid: pid_t, title: String) -> Bool {
        if raiseWindow(pid: pid, title: title) { return true }
        let app = appElement(pid)
        if let row = findChatRow(app, title) { return press(row) }
        let modes = modeButtons(app)
        guard let current = modes.first(where: { (attr($0, kAXValueAttribute) as Int?) == 1 }) else { return false }
        for mode in modes where !CFEqual(mode, current) {
            guard press(mode) else { continue }
            // The sidebar redraws after a mode switch.
            for _ in 0..<8 {
                Thread.sleep(forTimeInterval: 0.15)
                if let row = findChatRow(app, title) { return press(row) }
            }
        }
        _ = press(current)
        return false
    }

    private func press(_ el: AXUIElement) -> Bool { AXUIElementPerformAction(el, kAXPressAction as CFString) == .success }

    /// A sidebar row: a button reading the chat's title, maybe followed by a short status ("Running", "Merged").
    /// Skips the row's "More options" menu and the open chat's rename button.
    private func findChatRow(_ app: AXUIElement, _ title: String) -> AXUIElement? {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        var exact: AXUIElement?
        var withStatus: AXUIElement?
        walk(app) { el, role, label in
            guard role == kAXButtonRole else { return true }
            let text = label.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("More options") || text.contains(", rename session") { return true }
            // Title and description often repeat each other: "Weekly report Weekly report".
            if text == t || text == t + " " + t { exact = el; return false }
            if withStatus == nil, text.hasPrefix(t + " "), !text.dropFirst(t.count + 1).contains(" ") { withStatus = el }
            return true
        }
        return exact ?? withStatus
    }

    /// The options of a "Mode" switch, like Claude's Claude / Code.
    private func modeButtons(_ app: AXUIElement) -> [AXUIElement] {
        var radios: [AXUIElement] = []
        walk(app) { el, role, _ in
            if role == kAXRadioButtonRole, let parent: AXUIElement = attr(el, kAXParentAttribute),
               [kAXTitleAttribute, kAXDescriptionAttribute].contains(where: { ((attr(parent, $0) as String?) ?? "").contains("Mode") }) {
                radios.append(el)
            }
            return true
        }
        return radios
    }

    private static let runningWords: Set<String> = ["running", "working", "thinking", "generating", "in progress"]

    /// A sidebar row like Claude's: a button holding the conversation title and a status text "Running".
    /// Returns the title when the status says it is still going.
    static func runningSession(_ el: AXUIElement, _ label: String) -> String? {
        let lower = label.lowercased().trimmingCharacters(in: .whitespaces)
        guard runningWords.contains(where: { lower.hasSuffix(" " + $0) }) else { return nil }
        var texts: [String] = []
        var stack: [AXUIElement] = attr(el, kAXChildrenAttribute) ?? []
        var budget = 12
        while !stack.isEmpty, budget > 0 {
            let child = stack.removeFirst()
            budget -= 1
            let role: String? = attr(child, kAXRoleAttribute)
            if role == kAXStaticTextRole, let v: String = attr(child, kAXValueAttribute), !v.isEmpty {
                texts.append(v.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if let kids: [AXUIElement] = attr(child, kAXChildrenAttribute) {
                stack.append(contentsOf: kids)
            }
        }
        guard let status = texts.firstIndex(where: { runningWords.contains($0.lowercased()) }) else { return nil }
        texts.remove(at: status)
        let name = texts.joined(separator: " ")
        return name.isEmpty ? nil : String(name.prefix(80))
    }

    /// Depth-first walk of every window, last child first: the composer and its Stop button sit at the
    /// bottom of a chat, so this reaches them before thousands of message nodes in a long conversation.
    /// `visit` returns false to stop. Returns how many nodes it read.
    @discardableResult
    private func walk(_ app: AXUIElement, maxNodes: Int = Worker.maxNodes, _ visit: (AXUIElement, String, String) -> Bool) -> Int {
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        // Every desktop, so a full-screen app or one on another desktop is still seen.
        let windows = allWindows(pid)
        guard !windows.isEmpty else { return 0 }
        var stack = Array(windows.reversed())
        var count = 0
        while let el = stack.popLast(), count < maxNodes {
            count += 1
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(el, Self.attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
                  let v = values as? [Any], v.count == 6 else { continue }
            let role = v[0] as? String ?? ""
            let label = [v[1], v[2], v[3], v[4]].compactMap { $0 as? String }.joined(separator: " ")
            if !visit(el, role, label) { return count }
            if role != kAXStaticTextRole, role != kAXImageRole, let kids = v[5] as? [AXUIElement] {
                stack.append(contentsOf: kids)
            }
        }
        return count
    }

    private func isStopButton(_ el: AXUIElement) -> Bool {
        guard let role: String = attr(el, kAXRoleAttribute), role == kAXButtonRole else { return false }
        let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute]
            .compactMap { attr(el, $0) as String? }.joined(separator: " ")
        return Self.isStopLabel(label)
    }

    static func isStopLabel(_ label: String) -> Bool {
        let s = label.lowercased()
        // Real stop controls are short ("Stop", "Stop response", "Stop this task"). Longer labels that mention
        // stopping are usually lines in a transcript, like "Ran a command, stopped task".
        guard s.count <= 32, s.range(of: #"\b(stop|interrupt)\b"#, options: .regularExpression) != nil else { return false }
        // Voice, recording, and browser page-load controls also say "stop"; they do not mean the model is generating.
        let ignore = ["loading", "record", "dictat", "listen", "voice", "speak", "audio", "video", "screen share", "sharing", "read aloud"]
        return !ignore.contains { s.contains($0) }
    }

    /// Dock badge text keyed by the Dock item's title (the app name).
    private func dockBadges() -> [String: String] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let el = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.5)
        guard let kids: [AXUIElement] = attr(el, kAXChildrenAttribute),
              let list = kids.first(where: { (attr($0, kAXRoleAttribute) as String?) == kAXListRole }),
              let items: [AXUIElement] = attr(list, kAXChildrenAttribute) else { return [:] }
        var out: [String: String] = [:]
        for item in items {
            if let title: String = attr(item, kAXTitleAttribute), let badge: String = attr(item, "AXStatusLabel") {
                out[title] = badge
            }
        }
        return out
    }

    func diagnostics(_ targets: [Target], trusted: Bool) -> String {
        refreshWindowCounts()
        var lines = ["Pip diagnostics", "Accessibility allowed: \(trusted ? "yes" : "no")"]
        let badges = trusted ? dockBadges() : [:]
        for t in targets {
            lines.append("")
            lines.append("== \(t.name) (\(t.id)) Dock badge: \(badges[t.name] ?? "none")")
            guard trusted else { continue }
            var buttons: [String] = []
            var hints: [String] = []
            var sessions: [String] = []
            let nodes = walk(appElement(t.pid)) { el, role, label in
                if role == kAXButtonRole, let s = Self.runningSession(el, label) { sessions.append(s) }
                if role == kAXButtonRole, !label.isEmpty {
                    buttons.append((Self.isStopLabel(label) ? "  STOP  " : "        ") + label.prefix(80))
                } else if label.range(of: #"(?i)\b(stop|cancel|interrupt|working|thinking|running|generating|responding)"#,
                                      options: .regularExpression) != nil {
                    // Other elements that may signal work, in case an app shows it without a Stop button.
                    hints.append("        [\(role)] " + label.prefix(80))
                }
                return true
            }
            lines.append("nodes scanned: \(nodes)\(nodes >= Self.maxNodes ? " (limit reached)" : ""), buttons: \(buttons.count)")
            if !sessions.isEmpty { lines.append("running conversations: " + sessions.joined(separator: "; ")) }
            if Self.terminals.contains(t.id) { lines.append("terminal windows: " + terminalReport(t.pid)) }
            lines.append("windows: " + windowReport(t.pid))
            let live = probe(t.pid, full: true)
            if let f = live.focused { lines.append("on screen: " + f) }
            if let st = live.step { lines.append("current step: " + st) }
            lines.append(contentsOf: buttons.prefix(120))
            if !hints.isEmpty {
                lines.append("other elements that mention work:")
                lines.append(contentsOf: hints.prefix(40))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Indented dump of an app's accessibility tree, bottom of the window first like `walk`.
    /// For working out how a new app signals that it is generating. Stays on this Mac.
    func dumpTree(_ t: Target, maxNodes: Int = 2500) -> String {
        let app = appElement(t.pid)
        var lines = ["== \(t.name) (\(t.id)) pid \(t.pid)"]
        guard let windows: [AXUIElement] = attr(app, kAXWindowsAttribute), !windows.isEmpty else {
            return lines[0] + "\n(no windows: the app has none open, or they are minimized to the Dock)"
        }
        lines[0] += ", \(windows.count) window(s)"
        var stack: [(AXUIElement, Int)] = windows.reversed().map { ($0, 0) }
        var count = 0
        while let (el, depth) = stack.popLast(), count < maxNodes {
            count += 1
            let role: String = attr(el, kAXRoleAttribute) ?? "?"
            let sub: String = attr(el, kAXSubroleAttribute) ?? ""
            var bits = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXIdentifierAttribute]
                .compactMap { (attr(el, $0) as String?) }.filter { !$0.isEmpty }
            // Short text only (status chips like "Running"); message bodies are left out.
            if let v: String = attr(el, kAXValueAttribute), !v.isEmpty, role != kAXStaticTextRole || v.count <= 40 {
                bits.append("value=" + v)
            }
            let label = bits.joined(separator: " | ").replacingOccurrences(of: "\n", with: " ")
            lines.append(String(repeating: "  ", count: min(depth, 30)) + role + (sub.isEmpty ? "" : "/" + sub)
                         + (label.isEmpty ? "" : "  \"" + label.prefix(100) + "\""))
            if role != kAXStaticTextRole, role != kAXImageRole, let kids: [AXUIElement] = attr(el, kAXChildrenAttribute) {
                stack.append(contentsOf: kids.map { ($0, depth + 1) })
            }
        }
        lines.append("(\(count) nodes\(count >= maxNodes ? ", limit reached" : ""))")
        return lines.joined(separator: "\n")
    }

    /// Asks Electron and browser apps to build their accessibility trees before a dump.
    func prepare(_ targets: [Target]) { for t in targets { _ = appElement(t.pid) } }
}

/// `Pip --report <file> [--tree]`: write the detection report (and optionally full trees) for the
/// tracked apps to a file, then quit. Launch it with `open -n -W Pip.app --args --report …` so macOS
/// checks Pip's own Accessibility permission.
enum ReportMode {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        // `--open-chat <bundle id> <title> <result file>`: press that chat's row, for testing chat opening.
        if let k = args.firstIndex(of: "--open-chat"), k + 3 < args.count,
           let r = NSRunningApplication.runningApplications(withBundleIdentifier: args[k + 1]).first {
            let worker = Worker()
            worker.prepare([Worker.Target(id: args[k + 1], name: r.localizedName ?? "", pid: r.processIdentifier)])
            Thread.sleep(forTimeInterval: 0.5)
            let ok = worker.pressChat(pid: r.processIdentifier, title: args[k + 2])
            try? (ok ? "pressed" : "not found").write(toFile: args[k + 3], atomically: true, encoding: .utf8)
            return true
        }
        guard let i = args.firstIndex(of: "--report"), i + 1 < args.count else { return false }
        let out = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        let tree = args.contains("--tree")
        let ids = (UserDefaults.standard.stringArray(forKey: "tracked") ?? []) + Store.defaultBundleIDs()
        var seen = Set<String>()
        let targets: [Worker.Target] = ids.filter { seen.insert($0).inserted }.compactMap { id in
            guard let r = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { return nil }
            return Worker.Target(id: id, name: r.localizedName ?? id, pid: r.processIdentifier)
        }
        let worker = Worker()
        let trusted = AXIsProcessTrusted()
        if trusted { worker.prepare(targets); Thread.sleep(forTimeInterval: 1.5) }
        var text = worker.diagnostics(targets, trusted: trusted)
        if tree, trusted { text += "\n\n" + targets.map { worker.dumpTree($0) }.joined(separator: "\n\n") }
        if args.contains("--discover"), trusted {
            // Every other running app, as discovery would see it.
            let others = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && !ids.contains($0.bundleIdentifier ?? "") }
            text += "\n\nDiscovery:"
            for r in others {
                guard let id = r.bundleIdentifier, id != Bundle.main.bundleIdentifier else { continue }
                let t = Worker.Target(id: id, name: r.localizedName ?? id, pid: r.processIdentifier)
                let skip = Worker.neverAgents.contains(id)
                let hit = skip ? false : !worker.discover([t]).isEmpty
                text += "\n  \(skip ? "skip " : hit ? "AGENT" : "  -  ") \(t.name) (\(id))"
                if Worker.terminals.contains(id) { text += " windows: " + worker.terminalReport(t.pid) }
            }
        }
        try? text.write(to: out, atomically: true, encoding: .utf8)
        return true
    }
}

@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

extension Array {
    func also(_ f: () -> Void) -> Array { f(); return self }
}

private func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
    if T.self == AXUIElement.self {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! T)
    }
    return value as? T
}
