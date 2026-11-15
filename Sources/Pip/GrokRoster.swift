import Foundation

/// Grok Bot runs its bots remotely and keeps a local list of them, even while its window is closed.
/// Pip reads only each bot's name and a few counters from that list, never message text:
/// a bot is working while your newest message has no reply yet, and has news when its unread count goes up.
struct BotState: Equatable {
    var name: String
    var working: Bool        // your message is the newest entry and the bot hasn't replied yet
    var lastReply: String    // id of the bot's latest message, to notice a new one
    var unread: Int
    var needsAnswer: Bool    // the bot asked you something
}

enum GrokRoster {
    static let bundleID = "com.anysphere.sand"
    private static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence")
    private nonisolated(unsafe) static var cachedFile: URL?
    private nonisolated(unsafe) static var lastRead: (Date, [BotState])?

    /// The bots, or nil when the list can't be found. Re-reads the file only when it changed.
    static func read() -> [BotState]? {
        guard let file = rosterFile(),
              let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        else { return nil }
        if let (at, bots) = lastRead, at == modified { return bots }
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = (json["value"] as? [String: Any])?["rows"] as? [[String: Any]] else { return nil }
        let bots: [BotState] = rows.compactMap { r in
            guard r["isHiddenFromSidebar"] as? Bool != true, r["isRemovedFromSidebar"] as? Bool != true,
                  let name = (r["name"] as? String) ?? (r["title"] as? String), !name.isEmpty else { return nil }
            let newest = r["newestEntryId"] as? String ?? ""
            let reply = r["lastMessageId"] as? String ?? ""
            return BotState(name: String(name.prefix(80)), working: !newest.isEmpty && newest != reply, lastReply: reply,
                            unread: r["unreadCount"] as? Int ?? 0,
                            needsAnswer: !(r["awaitingUserResponse"] is NSNull) && r["awaitingUserResponse"] != nil)
        }
        lastRead = (modified, bots)
        return bots
    }

    /// The list's file name is the base32 of its key, which ends in "roster.last-roster".
    private static func rosterFile() -> URL? {
        if let f = cachedFile, FileManager.default.fileExists(atPath: f.path) { return f }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        for f in names where f.hasSuffix(".blob") {
            if let key = base32(String(f.dropLast(5))), key.hasSuffix("roster.last-roster") {
                cachedFile = folder.appendingPathComponent(f)
                return cachedFile
            }
        }
        return nil
    }

    private static func base32(_ s: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var out = [UInt8]()
        for c in s.uppercased() {
            guard let i = alphabet.firstIndex(of: c) else { return nil }
            value = (value << 5) | i
            bits += 5
            if bits >= 8 { out.append(UInt8((value >> (bits - 8)) & 0xFF)); bits -= 8 }
        }
        return String(bytes: out, encoding: .utf8)
    }
}
