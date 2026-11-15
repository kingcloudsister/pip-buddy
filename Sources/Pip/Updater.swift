import AppKit
import Security

/// Keeps Pip current from the GitHub repo named in Info.plist (`PipUpdateRepo`).
///
/// It asks GitHub for the repo's latest release (no account, nothing about you is sent beyond what any web
/// request carries), and when it is newer, offers it on the strip. Installing downloads `Pip.zip` from that
/// release, checks the new app is signed with the same key as this one, swaps it in, and relaunches.
@MainActor
final class Updater {
    static let shared = Updater()

    struct Release: Equatable { let version: String; let zip: URL; let page: URL }

    private(set) var latest: Release?
    private var timer: Timer?
    private let store = Store.shared

    let repo = Bundle.main.object(forInfoDictionaryKey: "PipUpdateRepo") as? String
    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    var automatic: Bool {
        get { UserDefaults.standard.object(forKey: "checkForUpdates") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "checkForUpdates"); store.objectWillChange.send() }
    }

    func start() {
        guard repo != nil else { return }
        if automatic { Task { await check(quietly: true) } }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { if self.automatic { Task { await self.check(quietly: true) } } }
        }
    }

    /// Looks for a newer release. `quietly` skips the "you're up to date" and error messages.
    func check(quietly: Bool) async {
        guard let repo, let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Pip-updater", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
                  let assets = json["assets"] as? [[String: Any]],
                  let zip = assets.first(where: { $0["name"] as? String == "Pip.zip" })?["browser_download_url"] as? String,
                  let zipURL = URL(string: zip), zipURL.host?.hasSuffix("github.com") == true
            else { throw UpdateError("GitHub's answer didn't include a Pip.zip.") }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            if Self.isNewer(version, than: current) {
                latest = Release(version: version, zip: zipURL, page: page)
                store.update = version
                Store.log("update: \(version) is available (have \(current))")
            } else {
                latest = nil
                store.update = nil
                if !quietly { alert("Pip is up to date", "You have the latest version, \(current).") }
            }
        } catch {
            if !quietly { alert("Couldn't check for updates", error.localizedDescription) }
        }
    }

    /// Downloads, verifies, and installs the available release, then relaunches Pip.
    func install() {
        guard let release = latest, !store.updating else { return }
        store.updating = true
        Task {
            do {
                try await installRelease(release)
            } catch {
                store.updating = false
                Store.log("update: failed: \(error.localizedDescription)")
                if alert("Couldn't install the update", error.localizedDescription + "\n\nYou can download it from GitHub instead.",
                         button: "Open Download Page") {
                    NSWorkspace.shared.open(release.page)
                }
            }
        }
    }

    private func installRelease(_ release: Release) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("pip-update-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let (downloaded, response) = try await URLSession.shared.download(from: release.zip)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
        let zip = work.appendingPathComponent("Pip.zip")
        try FileManager.default.moveItem(at: downloaded, to: zip)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])

        let newApp = work.appendingPathComponent("Pip.app")
        guard let bundle = Bundle(url: newApp), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("The download isn't Pip.")
        }
        guard (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) == release.version else {
            throw UpdateError("The download's version doesn't match the release.")
        }
        try Self.verifySameSigner(newApp)

        // Swap: the old copy goes to the Trash, the new one takes its place.
        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateError("Pip can't write to \(target.deletingLastPathComponent().path).")
        }
        try FileManager.default.trashItem(at: target, resultingItemURL: nil)
        try FileManager.default.moveItem(at: newApp, to: target)
        Store.log("update: installed \(release.version), relaunching")

        // Relaunch once this copy has quit.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", target.path]
        try relaunch.run()
        NSApp.terminate(nil)
    }

    /// The new app must be signed by the same key as the running one (the "Pip Buddy" key for released builds),
    /// so a swapped or tampered download is refused. A copy built without that key can't verify updates.
    static func verifySameSigner(_ app: URL) throws {
        var me: SecCode?
        var meStatic: SecStaticCode?
        var requirement: SecRequirement?
        var candidate: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
              SecCodeCopyDesignatedRequirement(meStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate
        else { throw UpdateError("Couldn't read the app signatures.") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess else {
            throw UpdateError("The download isn't signed with Pip's release key. (A copy of Pip you built yourself can't install updates; download the release instead.)")
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("Unpacking the download failed.") }
    }

    @discardableResult
    private func alert(_ title: String, _ text: String, button: String? = nil) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        if let button { a.addButton(withTitle: button); a.addButton(withTitle: "Close") }
        NSApp.activate(ignoringOtherApps: true)
        return a.runModal() == .alertFirstButtonReturn && button != nil
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
