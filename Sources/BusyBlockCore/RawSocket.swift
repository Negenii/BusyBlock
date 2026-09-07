import Foundation

/// Blocking TCP socket with per-call deadlines, built on poll(). Call off the
/// main thread. Nothing here touches CFNetwork or Network.framework.
public final class RawSocket {
    public enum Error: Swift.Error, CustomStringConvertible {
        case badHost(String), resolve(String), connect(String), timeout, io(String), closed
        public var description: String {
            switch self {
            case .badHost(let h): return "bad host: \(h)"
            case .resolve(let m): return "resolve failed: \(m)"
            case .connect(let m): return "connect failed: \(m)"
            case .timeout: return "timed out"
            case .io(let m): return "io: \(m)"
            case .closed: return "connection closed"
            }
        }
    }

    private var fd: Int32

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

    public init(host: String, port: Int, timeout: TimeInterval) throws {
        var hints = addrinfo(ai_flags: AI_ADDRCONFIG, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &info)
        guard rc == 0, let first = info else { throw Error.resolve(String(cString: gai_strerror(rc))) }
        defer { freeaddrinfo(info) }

        fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { throw Error.connect(String(cString: strerror(errno))) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        if connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) != 0 {
            guard errno == EINPROGRESS else { let e = errno; close(fd); throw Error.connect(String(cString: strerror(e))) }
            do { try wait(POLLOUT, deadline: Date().addingTimeInterval(timeout)) } catch { close(fd); throw error }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else { close(fd); throw Error.connect(String(cString: strerror(err))) }
        }
    }

    deinit { shutdown() }

    public func shutdown() {
        if fd >= 0 { close(fd); fd = -1 }
    }

    private func wait(_ events: Int32, deadline: Date) throws {
        guard fd >= 0 else { throw Error.closed }
        var p = pollfd(fd: fd, events: Int16(events), revents: 0)
        let ms = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        let n = poll(&p, 1, ms)
        if n == 0 { throw Error.timeout }
        if n < 0 { throw Error.io(String(cString: strerror(errno))) }
        if p.revents & Int16(POLLNVAL) != 0 { throw Error.closed }
    }

    public func write(_ data: Data, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var out = Array(data)
        while !out.isEmpty {
            try wait(POLLOUT, deadline: deadline)
            let n = out.withUnsafeBufferPointer { send(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 { if errno == EAGAIN { continue }; throw Error.io(String(cString: strerror(errno))) }
            out.removeFirst(n)
        }
    }

    /// Reads whatever is available (up to `max`); empty Data means EOF.
    public func read(max: Int = 16384, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var chunk = [UInt8](repeating: 0, count: max)
        while true {
            try wait(POLLIN, deadline: deadline)
            let n = chunk.withUnsafeMutableBufferPointer { recv(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 { if errno == EAGAIN { continue }; throw Error.io(String(cString: strerror(errno))) }
            return Data(chunk[0..<n])
        }
    }
}
