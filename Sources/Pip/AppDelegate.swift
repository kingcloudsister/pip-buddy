import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!
    let store = Store.shared
    private(set) var pill: PillController!
    private var watcher: Watcher!
    private var hooks: HookServer!

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        if !AXIsProcessTrusted() { store.requestAccess(openSettings: false) }
        pill = PillController(store: store)
        watcher = Watcher(store: store)
        watcher.start()
        hooks = HookServer { path, query in
            MainActor.assumeIsolated { Store.shared.hook(path, query) }
        }
        hooks.start()
    }

    func openChat(bundleID: String, title: String) { watcher.openChat(bundleID: bundleID, title: title) }

    func copyDiagnostics() {
        watcher.diagnostics { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    func copyHookExample() {
        let text = """
        # Tell Pip a CLI agent started and finished (spaces in names as %20):
        curl -s "http://127.0.0.1:\(HookServer.port)/working?app=Claude%20Code&open=com.apple.Terminal"
        curl -s "http://127.0.0.1:\(HookServer.port)/done?app=Claude%20Code&note=Refactor%20finished&open=com.apple.Terminal"
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
