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
        worker.queue.async { [worker] in
            let probes = worker.probeAll(targets)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.store.ingest(probes)
                    self.busy = false
                }
            }
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
        polls += 1
        var result: [String: Probe] = [:]
        for t in targets {
            var p = probe(t.pid)
            p.badge = badges[t.name]
            result[t.id] = p
        }
        return result
    }

    private func appElement(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        if !enhanced.contains(pid) {
            // Electron apps (Claude among them) and Chrome only build the page's accessibility tree when asked.
            // Electron takes AXManualAccessibility; browsers that reject it take AXEnhancedUserInterface.
            if AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) != .success {
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
            enhanced.insert(pid)
        }
        return app
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
            return Probe(working: false, title: title, sessions: nil)
        }
        cachedStop[pid] = nil
        var found: AXUIElement?
        var sessions: [String] = []
        var step: String?
        var focused: String?
        walk(app) { el, role, label in
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
        return Probe(working: found != nil, title: title, sessions: sessionApps.contains(pid) ? sessions : nil,
                     step: step, focused: focused)
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
    private func walk(_ app: AXUIElement, _ visit: (AXUIElement, String, String) -> Bool) -> Int {
        guard let windows: [AXUIElement] = attr(app, kAXWindowsAttribute) else { return 0 }
        var stack = Array(windows.reversed())
        var count = 0
        while let el = stack.popLast(), count < Self.maxNodes {
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
        try? text.write(to: out, atomically: true, encoding: .utf8)
        return true
    }
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
