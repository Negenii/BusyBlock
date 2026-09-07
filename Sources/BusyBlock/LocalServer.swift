import Foundation
import Network
import BusyBlockCore

/// Tiny loopback HTTP server the browser extension talks to.
/// GET /state -> BlockState JSON, GET /health -> {"ok":true},
/// GET /events -> Server-Sent Events: `state` and `frame` messages.
final class LocalServer {
    private let port: UInt16
    private let stateProvider: () -> BlockState
    /// Events to send to a freshly connected SSE client (current state, last frame).
    var initialEvents: () -> [(String, Data)] = { [] }
    /// `POST /domains` with {"add": host} or {"remove": host}. Returns the new state JSON.
    var onDomainChange: ((_ add: String?, _ remove: String?) -> Data)?
    /// `GET /favicon?host=x` → PNG bytes (nil = 404). Async: the loader may hit the network.
    var faviconProvider: ((_ host: String, _ done: @escaping (Data?) -> Void) -> Void)?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "me.negenii.BusyBlock.server")
    private let log: (String) -> Void
    private var sseClients: [ObjectIdentifier: NWConnection] = [:]
    private var lastPollLog: [String: Date] = [:]

    init(port: UInt16, log: @escaping (String) -> Void = { print($0) }, stateProvider: @escaping () -> BlockState) {
        self.port = port
        self.log = log
        self.stateProvider = stateProvider
    }

    var sseClientCount: Int { queue.sync { sseClients.count } }

    /// Push one event to every SSE client. Safe from any thread.
    func broadcast(event: String, data: Data) {
        queue.async { [weak self] in
            guard let self, !self.sseClients.isEmpty else { return }
            let payload = Self.sseFrame(event: event, data: data)
            for (id, conn) in self.sseClients {
                conn.send(content: payload, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.dropSSE(id) }
                })
            }
        }
    }

    private static func sseFrame(event: String, data: Data) -> Data {
        Data("event: \(event)\ndata: ".utf8) + data + Data("\n\n".utf8)
    }

    private func dropSSE(_ id: ObjectIdentifier) {
        if let c = sseClients.removeValue(forKey: id) {
            c.cancel()
            log("sse client gone (\(sseClients.count) left)")
        }
    }

    private func beginSSE(_ conn: NWConnection) {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: keep-alive\r\n\r\n"
        var body = Data(head.utf8)
        body.append(Data("retry: 2000\n\n".utf8))
        for (event, data) in initialEvents() { body.append(Self.sseFrame(event: event, data: data)) }
        let id = ObjectIdentifier(conn)
        sseClients[id] = conn
        conn.send(content: body, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.dropSSE(id) }
        })
        // A pending receive is how we learn the browser went away.
        func watch() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
                if isComplete || error != nil { self?.dropSSE(id) } else { watch() }
            }
        }
        watch()
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let l = try NWListener(using: params)
        l.stateUpdateHandler = { [log, port] st in
            switch st {
            case .ready: log("local server listening on 127.0.0.1:\(port)")
            case .failed(let e): log("local server failed: \(e)")
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        l.start(queue: queue)
        listener = l
    }

    func stop() { listener?.cancel(); listener = nil }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        var buffer = Data()
        func readMore() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
                guard let self else { conn.cancel(); return }
                if let data { buffer.append(data) }
                if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                    let wanted = Self.contentLength(head)
                    let body = buffer[range.upperBound...]
                    if body.count >= wanted {
                        self.respond(conn, requestHead: head, body: Data(body.prefix(wanted)))
                    } else if isComplete || error != nil {
                        conn.cancel()
                    } else {
                        readMore()
                    }
                } else if isComplete || error != nil || buffer.count > 65536 {
                    conn.cancel()
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    private static func contentLength(_ head: String) -> Int {
        header(head, "content-length").flatMap(Int.init) ?? 0
    }

    private static func header(_ head: String, _ name: String) -> String? {
        for line in head.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].lowercased() == name {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func respond(_ conn: NWConnection, requestHead: String, body reqBody: Data) {
        let line = requestHead.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : "GET"
        var path = parts.count > 1 ? String(parts[1]) : "/"
        var query: [String: String] = [:]
        if let q = path.firstIndex(of: "?") {
            for pair in path[path.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if kv.count == 2 { query[kv[0]] = kv[1] }
            }
            path = String(path[..<q])
        }
        let origin = Self.header(requestHead, "origin")
        let fromExtension = OriginPolicy.isExtension(origin)

        if method == "GET" && path == "/favicon", let provider = faviconProvider {
            let host = Domain.normalize(query["host"] ?? "").split(separator: "/").first.map(String.init) ?? ""
            provider(host) { [weak self] png in
                self?.queue.async {
                    var head = png == nil ? "HTTP/1.1 404 Not Found\r\n" : "HTTP/1.1 200 OK\r\n"
                    head += "Content-Type: \(png == nil ? "application/json" : "image/png")\r\n"
                    head += "Access-Control-Allow-Origin: *\r\nCache-Control: max-age=3600\r\n"
                    let body = png ?? Data(#"{"error":"no icon"}"#.utf8)
                    head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
                }
            }
            return
        }

        if method == "GET" && path == "/go" {
            // Safari's redirect lands here; the extension's content script hops on
            // to blocked.html. Shown only if the extension is missing.
            let html = """
            <!doctype html><meta charset="utf-8"><title>BusyBlock</title>
            <body style="margin:0;background:#0e0c0c;color:#9a9a96;font:15px -apple-system,sans-serif;display:grid;place-items:center;height:100vh">
            <p>Blocked while the BUSY Bar is busy. If this page stays, the BusyBlock extension is not enabled in this browser.</p>
            """
            let body = Data(html.utf8)
            var head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n"
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        if method == "GET" && path == "/events" {
            let ua = Self.header(requestHead, "user-agent") ?? "?"
            let n = sseClients.count + 1
            log("sse client connected (\(n) total)\(n > 4 ? " — browsers cap ~6 connections per host, background tabs should have let go" : ""): \(ua.prefix(60))")
            beginSSE(conn)
            return
        }

        var status = "200 OK"
        var body = Data()
        if method == "OPTIONS" {
            // Preflight: only extension pages get to send a POST.
            status = (path == "/domains" && !fromExtension) ? "403 Forbidden" : "204 No Content"
        } else if method == "POST" && path == "/log" {
            // Diagnostics from the extension worker (extension origins only).
            if fromExtension, let obj = try? JSONSerialization.jsonObject(with: reqBody) as? [String: Any] {
                let ua = Self.header(requestHead, "user-agent") ?? ""
                let kind = ua.contains("Chrome") ? "chrome" : ua.contains("Safari") ? "safari" : "other"
                log("[\(kind) worker] \(obj["msg"] as? String ?? "")")
                body = Data(#"{"ok":true}"#.utf8)
            } else {
                status = "403 Forbidden"
            }
        } else if method == "POST" && path == "/domains" {
            if !fromExtension {
                status = "403 Forbidden"
                body = Data(#"{"error":"only the browser extension may change the list"}"#.utf8)
            } else if let obj = try? JSONSerialization.jsonObject(with: reqBody) as? [String: Any],
                      let handler = onDomainChange {
                body = handler(obj["add"] as? String, obj["remove"] as? String)
            } else {
                status = "400 Bad Request"
                body = Data(#"{"error":"expected {\"add\":host} or {\"remove\":host}"}"#.utf8)
            }
        } else if method != "GET" {
            status = "405 Method Not Allowed"
            body = Data(#"{"error":"GET only"}"#.utf8)
        } else if path == "/state" {
            let ua = Self.header(requestHead, "user-agent") ?? "?"
            let kind = ua.contains("Chrome") ? "chrome" : ua.contains("Safari") ? "safari" : ua.contains("Firefox") ? "firefox" : "other"
            if Date().timeIntervalSince(lastPollLog[kind] ?? .distantPast) > 10 {
                lastPollLog[kind] = Date()
                log("state polled by \(kind) worker")
            }
            body = stateProvider().wireJSON()
        } else if path == "/health" {
            body = Data(#"{"ok":true}"#.utf8)
        } else {
            status = "404 Not Found"
            body = Data(#"{"error":"not found"}"#.utf8)
        }
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        // Reads are open to any origin; writes echo only an extension origin.
        head += "Access-Control-Allow-Origin: \(fromExtension ? origin! : "*")\r\n"
        head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        head += "Access-Control-Allow-Headers: Content-Type\r\n"
        head += "Vary: Origin\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
