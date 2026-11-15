import Foundation
import Network

/// Tiny HTTP endpoint on 127.0.0.1 so scripts and CLI agents (for example a Claude Code Stop hook)
/// can tell Pip they finished: `curl -s "http://127.0.0.1:47321/done?app=Claude%20Code"`.
///
/// Only programs on this Mac can connect. Web pages can send requests to 127.0.0.1 too, so any request a
/// browser sends is refused: browsers always add Origin, Referer, or Sec-Fetch headers, and a page that
/// points its own domain at 127.0.0.1 (DNS rebinding) still sends its own name as Host.
final class HookServer {
    static let port: UInt16 = 47321
    private var listener: NWListener?
    private let handle: (String, [String: String]) -> Bool

    init(handle: @escaping (String, [String: String]) -> Bool) { self.handle = handle }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else { return }
        listener.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                return Self.reply(conn, 400, "bad request\n")
            }
            let lines = request.components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let fromBrowser = ["origin", "referer", "sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest"].contains { headers[$0] != nil }
            let host = headers["host"] ?? ""
            guard !fromBrowser, ["127.0.0.1:\(Self.port)", "localhost:\(Self.port)"].contains(host) else {
                return Self.reply(conn, 403, "forbidden\n")
            }
            let parts = lines[0].split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET", let comps = URLComponents(string: "http://pip" + parts[1]) else {
                return Self.reply(conn, 400, "bad request\n")
            }
            var q: [String: String] = [:]
            for item in comps.queryItems ?? [] { q[item.name] = String((item.value ?? "").prefix(200)) }
            let ok = comps.path == "/ping" || self.handle(comps.path, q)
            Self.reply(conn, ok ? 200 : 400, ok ? "ok\n" : "usage: /done|/working|/idle?app=Name[&note=text][&open=bundle.id]\n")
        }
    }

    private static func reply(_ conn: NWConnection, _ code: Int, _ body: String) {
        let status = [200: "OK", 400: "Bad Request", 403: "Forbidden"][code] ?? ""
        let response = "HTTP/1.1 \(code) \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }
}
