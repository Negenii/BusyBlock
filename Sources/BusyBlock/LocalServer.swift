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
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "me.negenii.BusyBlock.server")
    private let log: (String) -> Void
    private var sseClients: [ObjectIdentifier: NWConnection] = [:]

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
        if let c = sseClients.removeValue(forKey: id) { c.cancel() }
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
                    self.respond(conn, requestHead: head)
                } else if isComplete || error != nil || buffer.count > 65536 {
                    conn.cancel()
                } else {
                    readMore()
                }
            }
        }
        readMore()
    }

    private func respond(_ conn: NWConnection, requestHead: String) {
        let line = requestHead.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : "GET"
        var path = parts.count > 1 ? String(parts[1]) : "/"
        if let q = path.firstIndex(of: "?") { path = String(path[..<q]) }

        if method == "GET" && path == "/events" {
            beginSSE(conn)
            return
        }

        var status = "200 OK"
        var body = Data()
        if method == "OPTIONS" {
            status = "204 No Content"
        } else if method != "GET" {
            status = "405 Method Not Allowed"
            body = Data(#"{"error":"GET only"}"#.utf8)
        } else if path == "/state" {
            body = stateProvider().wireJSON()
        } else if path == "/health" {
            body = Data(#"{"ok":true}"#.utf8)
        } else {
            status = "404 Not Found"
            body = Data(#"{"error":"not found"}"#.utf8)
        }
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Headers: *\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
