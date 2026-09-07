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

    public static func parseHost(_ raw: String, defaultPort: Int = 80) -> (String, Int)? {
        RawSocket.parseHost(raw, defaultPort: defaultPort)
    }

    /// Blocking GET. Call off the main thread. Returns the body on 2xx.
    public static func get(host rawHost: String, path: String, headers: [String: String] = [:],
                           timeout: TimeInterval = 3) throws -> Data {
        guard let (host, port) = RawSocket.parseHost(rawHost) else { throw Error.badHost(rawHost) }
        let deadline = Date().addingTimeInterval(timeout)
        let sock: RawSocket
        do { sock = try RawSocket(host: host, port: port, timeout: timeout) } catch let e as RawSocket.Error {
            switch e {
            case .resolve(let m): throw Error.resolve(m)
            case .connect(let m): throw Error.connect(m)
            case .timeout: throw Error.timeout
            default: throw Error.io(e.description)
            }
        }
        defer { sock.shutdown() }

        var req = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\nAccept: application/json\r\n"
        for (k, v) in headers { req += "\(k): \(v)\r\n" }
        req += "\r\n"
        do {
            try sock.write(Data(req.utf8), timeout: max(0, deadline.timeIntervalSinceNow))
            var buf = Data()
            while true {
                let chunk = try sock.read(timeout: max(0, deadline.timeIntervalSinceNow))
                if chunk.isEmpty { break }
                buf.append(chunk)
                if let end = headerEnd(buf), let len = contentLength(buf[..<end]), buf.count >= end + len { break }
                if buf.count > 1_000_000 { throw Error.badResponse }
            }
            return try parse(buf)
        } catch let e as RawSocket.Error {
            switch e {
            case .timeout: throw Error.timeout
            case .closed: throw Error.io("socket closed")
            default: throw Error.io(e.description)
            }
        }
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

    static func isChunked(_ head: Data) -> Bool {
        String(decoding: head, as: UTF8.self).lowercased().contains("transfer-encoding: chunked")
    }

    /// Splits status line + headers from the body. Handles Content-Length,
    /// chunked (Node proxies such as busybar-manager) and close-delimited bodies.
    public static func parse(_ raw: Data) throws -> Data {
        guard let end = headerEnd(raw) else { throw Error.badResponse }
        let head = String(decoding: raw[..<end], as: UTF8.self)
        guard let statusLine = head.split(separator: "\r\n").first,
              let code = Int(statusLine.split(separator: " ").dropFirst().first ?? "") else { throw Error.badResponse }
        guard (200..<300).contains(code) else { throw Error.status(code) }
        var body = Data(raw[end...])
        if isChunked(raw[..<end]) { return try dechunk(body) }
        if let len = contentLength(raw[..<end]), body.count > len { body = body.prefix(len) }
        return body
    }

    /// "<hex-size>\r\n<bytes>\r\n" … "0\r\n\r\n". Tolerates a truncated tail (close-delimited).
    static func dechunk(_ data: Data) throws -> Data {
        var out = Data()
        var i = data.startIndex
        let crlf = Data("\r\n".utf8)
        while i < data.endIndex {
            guard let lineEnd = data[i...].range(of: crlf) else { break }
            let sizeText = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { throw Error.badResponse }
            if size == 0 { break }
            let start = lineEnd.upperBound
            let stop = min(start + size, data.endIndex)
            out.append(data[start..<stop])
            i = min(stop + 2, data.endIndex)
        }
        return out
    }
}
