import Foundation

/// Minimal HTTP/1.1 GET over POSIX sockets.
///
/// URLSession in a long-running menu-bar process was seen returning
/// NSURLErrorDomain -1009 ("offline") for the bar forever after the USB
/// interface flapped, while curl from the same machine worked. Plain sockets
/// skip CFNetwork's path evaluation and connection cache entirely, and every
/// poll is a fresh connect with a hard timeout, so nothing can stick.
public enum RawHTTPClient {
    public enum Error: Swift.Error, CustomStringConvertible {
        case badHost(String)
        case resolve(String)
        case connect(String)
        case timeout
        case io(String)
        case badResponse
        case status(Int)

        public var description: String {
            switch self {
            case .badHost(let h): return "bad host: \(h)"
            case .resolve(let m): return "resolve failed: \(m)"
            case .connect(let m): return "connect failed: \(m)"
            case .timeout: return "timed out"
            case .io(let m): return "io: \(m)"
            case .badResponse: return "malformed response"
            case .status(let s): return "HTTP \(s)"
            }
        }
    }

    /// "host", "host:port", or "http://host:port/" → (host, port).
    public static func parseHost(_ raw: String, defaultPort: Int = 80) -> (String, Int)? {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        guard !h.isEmpty else { return nil }
        if let colon = h.lastIndex(of: ":"), !h.contains("[") {
            let port = Int(h[h.index(after: colon)...]) ?? defaultPort
            let host = String(h[..<colon])
            return host.isEmpty ? nil : (host, port)
        }
        return (h, defaultPort)
    }

    /// Blocking GET. Call off the main thread. Returns the body on 2xx.
    public static func get(host rawHost: String, path: String, headers: [String: String] = [:],
                           timeout: TimeInterval = 3) throws -> Data {
        guard let (host, port) = parseHost(rawHost) else { throw Error.badHost(rawHost) }

        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &info)
        guard rc == 0, let first = info else { throw Error.resolve(String(cString: gai_strerror(rc))) }
        defer { freeaddrinfo(info) }

        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { throw Error.connect(String(cString: strerror(errno))) }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let deadline = Date().addingTimeInterval(timeout)
        func remainingMs() -> Int32 { Int32(max(0, deadline.timeIntervalSinceNow * 1000)) }
        func wait(_ events: Int16) throws {
            var p = pollfd(fd: fd, events: events, revents: 0)
            let n = poll(&p, 1, remainingMs())
            if n == 0 { throw Error.timeout }
            if n < 0 { throw Error.io(String(cString: strerror(errno))) }
            if p.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 && p.revents & events == 0 {
                throw Error.io("socket closed")
            }
        }

        if connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) != 0 {
            guard errno == EINPROGRESS else { throw Error.connect(String(cString: strerror(errno))) }
            try wait(Int16(POLLOUT))
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { throw Error.connect(String(cString: strerror(err))) }
        }

        var req = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\nAccept: application/json\r\n"
        for (k, v) in headers { req += "\(k): \(v)\r\n" }
        req += "\r\n"
        var out = Array(req.utf8)
        while !out.isEmpty {
            try wait(Int16(POLLOUT))
            let n = out.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 { if errno == EAGAIN { continue }; throw Error.io(String(cString: strerror(errno))) }
            out.removeFirst(n)
        }

        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            try wait(Int16(POLLIN))
            let n = chunk.withUnsafeMutableBufferPointer { recv(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 { if errno == EAGAIN { continue }; throw Error.io(String(cString: strerror(errno))) }
            if n == 0 { break }
            buf.append(contentsOf: chunk[0..<n])
            if let end = headerEnd(buf), let len = contentLength(buf[..<end]), buf.count >= end + len { break }
            if buf.count > 1_000_000 { throw Error.badResponse }
        }
        return try parse(buf)
    }

    static func headerEnd(_ d: Data) -> Int? {
        d.range(of: Data("\r\n\r\n".utf8)).map { $0.upperBound }
    }

    static func contentLength(_ head: Data) -> Int? {
        let text = String(decoding: head, as: UTF8.self)
        for line in text.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Splits status line + headers from the body; only Content-Length or
    /// close-delimited bodies (what the bar and busybar-manager send).
    public static func parse(_ raw: Data) throws -> Data {
        guard let end = headerEnd(raw) else { throw Error.badResponse }
        let head = String(decoding: raw[..<end], as: UTF8.self)
        guard let statusLine = head.split(separator: "\r\n").first,
              let code = Int(statusLine.split(separator: " ").dropFirst().first ?? "") else { throw Error.badResponse }
        guard (200..<300).contains(code) else { throw Error.status(code) }
        var body = raw[end...]
        if let len = contentLength(raw[..<end]), body.count > len { body = body.prefix(len) }
        return Data(body)
    }
}
