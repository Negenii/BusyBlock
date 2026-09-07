import Foundation
import Network
import BusyBlockCore

/// Tiny loopback HTTP server the browser extension polls.
/// GET /state -> BlockState JSON, GET /health -> {"ok":true}.
final class LocalServer {
    private let port: UInt16
    private let stateProvider: () -> BlockState
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "me.negenii.BusyBlock.server")
    private let log: (String) -> Void

    init(port: UInt16, log: @escaping (String) -> Void = { print($0) }, stateProvider: @escaping () -> BlockState) {
        self.port = port
        self.log = log
        self.stateProvider = stateProvider
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
