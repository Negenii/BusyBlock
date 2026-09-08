import Foundation
import BusyBlockCore

/// Persistent connection to the bar's `/api/status/ws`. The bar pushes timer
/// changes and front-panel frames; we answer pings and reconnect with backoff.
/// Runs on its own thread over RawSocket; callbacks arrive on the main queue.
final class BarStream {
    var onMessage: ((BarStateMessage, Date) -> Void)?
    var onStatus: ((Bool, String?) -> Void)?

    private var host: String
    private var token: String?
    private let log: (String) -> Void
    private let lock = NSLock()
    private var running = false
    private var generation = 0
    private var socket: RawSocket?

    init(host: String, token: String?, log: @escaping (String) -> Void) {
        self.host = host
        self.token = token
        self.log = log
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        running = true
        generation += 1
        let gen = generation
        Thread.detachNewThread { [weak self] in self?.loop(generation: gen) }
    }

    func stop() {
        lock.lock()
        running = false
        generation += 1
        let s = socket
        lock.unlock()
        s?.shutdown()
    }

    func update(host: String, token: String?) {
        lock.lock()
        let changed = host != self.host || token != self.token
        self.host = host
        self.token = token
        lock.unlock()
        if changed { stop(); start() }
    }

    private func alive(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running && generation == gen
    }

    private func loop(generation gen: Int) {
        var backoff: TimeInterval = 1
        while alive(gen) {
            do {
                try session(gen)
                backoff = 1
            } catch {
                report(false, String(describing: error))
                if !alive(gen) { break }
                Thread.sleep(forTimeInterval: backoff)
                backoff = min(10, backoff * 2)
            }
        }
    }

    private func report(_ connected: Bool, _ error: String?) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(connected, error) }
    }

    private func session(_ gen: Int) throws {
        lock.lock()
        let host = self.host, token = self.token
        lock.unlock()
        guard let (h, port) = RawSocket.parseHost(host) else { throw RawSocket.Error.badHost(host) }
        let sock = try RawSocket(host: h, port: port, timeout: 3)
        lock.lock(); socket = sock; lock.unlock()
        defer { lock.lock(); if socket === sock { socket = nil }; lock.unlock(); sock.shutdown() }

        var path = "/api/status/ws"
        if let token, !token.isEmpty {
            path += "?X-API-Token=" + (token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token)
        }
        let key = WebSocketCodec.randomKey()
        try sock.write(Data(WebSocketCodec.handshakeRequest(host: h, path: path, key: key).utf8), timeout: 3)

        var buffer = Data()
        let deadline = Date().addingTimeInterval(4)
        while buffer.range(of: Data("\r\n\r\n".utf8)) == nil {
            let chunk = try sock.read(timeout: max(0.1, deadline.timeIntervalSinceNow))
            if chunk.isEmpty { throw RawSocket.Error.closed }
            buffer.append(chunk)
            if Date() > deadline { throw RawSocket.Error.timeout }
        }
        let headEnd = buffer.range(of: Data("\r\n\r\n".utf8))!
        let head = String(decoding: buffer[..<headEnd.lowerBound], as: UTF8.self)
        if let problem = WebSocketCodec.checkHandshake(responseHead: head, key: key) {
            throw StreamError.handshake(problem)
        }
        buffer = Data(buffer[headEnd.upperBound...])

        try send(sock, .text, #"{"enable":true}"#)
        try send(sock, .text, #"{"send":"all"}"#)
        log("bar stream connected to \(host)")
        report(true, nil)

        var lastPing = Date()
        var lastData = Date()
        while alive(gen) {
            // Server pings every 10 s; our own ping every 5 s doubles as keepalive.
            if Date().timeIntervalSince(lastPing) > 5 {
                try send(sock, .ping, "")
                lastPing = Date()
            }
            // A yanked USB cable doesn't close the socket, it just goes quiet.
            // The bar answers pings within milliseconds, so 12 s of nothing is dead.
            if Date().timeIntervalSince(lastData) > 12 { throw StreamError.silent }
            let chunk: Data
            do { chunk = try sock.read(timeout: 2) } catch RawSocket.Error.timeout { continue }
            if chunk.isEmpty { throw RawSocket.Error.closed }
            lastData = Date()
            buffer.append(chunk)
            while let (frame, used) = try WebSocketCodec.decode(buffer) {
                buffer.removeFirst(used)
                switch frame.opcode {
                case .ping: try send(sock, .pong, frame.payload)
                case .close: throw StreamError.closedByPeer
                case .binary:
                    let received = Date()
                    if let msg = try? BarStateMessage.decode(frame.payload) {
                        if msg.resourceLimit { throw StreamError.resourceLimit }
                        DispatchQueue.main.async { [weak self] in self?.onMessage?(msg, received) }
                    }
                default: break
                }
            }
            if buffer.count > 4_000_000 { throw StreamError.overflow }
        }
    }

    private func send(_ sock: RawSocket, _ op: WebSocketCodec.Opcode, _ text: String) throws {
        try send(sock, op, Data(text.utf8))
    }

    private func send(_ sock: RawSocket, _ op: WebSocketCodec.Opcode, _ payload: Data) throws {
        try sock.write(WebSocketCodec.encode(.init(opcode: op, payload: payload)), timeout: 3)
    }

    enum StreamError: Error, CustomStringConvertible {
        case handshake(String), closedByPeer, resourceLimit, overflow, silent
        var description: String {
            switch self {
            case .handshake(let s): return "ws handshake: \(s)"
            case .closedByPeer: return "closed by bar"
            case .resourceLimit: return "bar has no free stream slots (max 4 clients)"
            case .overflow: return "stream buffer overflow"
            case .silent: return "no data for 12 s"
            }
        }
    }
}
