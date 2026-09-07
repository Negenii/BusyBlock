import Foundation
import CryptoKit

/// RFC 6455 client-side framing, no extensions.
public enum WebSocketCodec {
    public enum Opcode: UInt8 { case continuation = 0, text = 1, binary = 2, close = 8, ping = 9, pong = 10 }
    public struct Frame: Equatable {
        public var opcode: Opcode
        public var payload: Data
        public var fin: Bool
        public init(opcode: Opcode, payload: Data, fin: Bool = true) { self.opcode = opcode; self.payload = payload; self.fin = fin }
    }

    public static func handshakeRequest(host: String, path: String, key: String) -> String {
        "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        + "Sec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
    }

    public static func randomKey() -> String {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    }

    public static func expectedAccept(for key: String) -> String {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        return Data(Insecure.SHA1.hash(data: Data(magic.utf8))).base64EncodedString()
    }

    /// Validates the 101 response head. Returns nil with a reason on failure.
    public static func checkHandshake(responseHead: String, key: String) -> String? {
        let lines = responseHead.split(separator: "\r\n").map(String.init)
        guard let status = lines.first, status.contains(" 101 ") else { return "expected 101, got: \(lines.first ?? "")" }
        let accept = lines.dropFirst().first { $0.lowercased().hasPrefix("sec-websocket-accept:") }
            .map { $0.drop { $0 != ":" }.dropFirst().trimmingCharacters(in: .whitespaces) }
        guard accept == expectedAccept(for: key) else { return "bad Sec-WebSocket-Accept" }
        return nil
    }

    /// Client frames must be masked.
    public static func encode(_ frame: Frame) -> Data {
        var out = Data()
        out.append((frame.fin ? 0x80 : 0) | frame.opcode.rawValue)
        let n = frame.payload.count
        if n < 126 { out.append(0x80 | UInt8(n)) }
        else if n < 65536 { out.append(0x80 | 126); out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xff)) }
        else { out.append(0x80 | 127); for k in (0..<8).reversed() { out.append(UInt8((n >> (8 * k)) & 0xff)) } }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        out.append(contentsOf: mask)
        var i = 0
        for b in frame.payload { out.append(b ^ mask[i & 3]); i += 1 }
        return out
    }

    /// Parses one frame from the front of `buffer`; nil if incomplete.
    /// Returns the frame and the number of bytes consumed.
    public static func decode(_ buffer: Data) throws -> (Frame, Int)? {
        guard buffer.count >= 2 else { return nil }
        let b0 = buffer[buffer.startIndex], b1 = buffer[buffer.startIndex + 1]
        let fin = b0 & 0x80 != 0
        guard let opcode = Opcode(rawValue: b0 & 0x0f) else { throw Error.badOpcode }
        let masked = b1 & 0x80 != 0
        var len = Int(b1 & 0x7f)
        var i = buffer.startIndex + 2
        if len == 126 {
            guard buffer.count >= 4 else { return nil }
            len = Int(buffer[i]) << 8 | Int(buffer[i + 1]); i += 2
        } else if len == 127 {
            guard buffer.count >= 10 else { return nil }
            len = 0
            for k in 0..<8 { len = len << 8 | Int(buffer[i + k]) }
            i += 8
        }
        var mask: [UInt8] = []
        if masked {
            guard buffer.endIndex - i >= 4 else { return nil }
            mask = Array(buffer[i..<i + 4]); i += 4
        }
        guard buffer.endIndex - i >= len else { return nil }
        var payload = Data(buffer[i..<i + len])
        if masked { for k in 0..<payload.count { payload[k] ^= mask[k & 3] } }
        return (Frame(opcode: opcode, payload: payload, fin: fin), i + len - buffer.startIndex)
    }

    public enum Error: Swift.Error { case badOpcode }
}
