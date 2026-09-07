import Foundation
import Compression

/// One binary message from `/api/status/ws`: `BSB_State.State`.
public struct BarStateMessage: Equatable {
    /// Bar clock at send time, ms since epoch.
    public var timestampMs: Int?
    public var timer: BusySnapshot?
    public var frames: [BarFrame]
    public var resourceLimit: Bool

    public init(timestampMs: Int? = nil, timer: BusySnapshot? = nil, frames: [BarFrame] = [], resourceLimit: Bool = false) {
        self.timestampMs = timestampMs
        self.timer = timer
        self.frames = frames
        self.resourceLimit = resourceLimit
    }

    public static func decode(_ data: Data) throws -> BarStateMessage {
        var msg = BarStateMessage()
        for f in try Protobuf.fields(data) {
            switch (f.number, f.value) {
            case (1, .fixed64(let ts)): msg.timestampMs = Int(ts)
            case (2, .bytes(let upd)):
                for u in try Protobuf.fields(upd) {
                    switch (u.number, u.value) {
                    case (10, .bytes(let fr)):
                        if let frame = try? BarFrame.decode(fr) { msg.frames.append(frame) }
                    case (12, .bytes(let timer)):
                        if let json = try? jsonPayload(timer) {
                            // The bar's own timestamp isn't inside; the envelope carries it.
                            var snap = try BusySnapshot.decode(json)
                            if snap.timestampMs == nil { snap.timestampMs = msg.timestampMs }
                            msg.timer = snap
                        }
                    default: break
                    }
                }
            case (3, .bytes(let err)):
                // Error{cause=1 (RESOURCE_LIMIT=0), severity=2 (FATAL=0)}: absent fields = 0.
                let fields = try Protobuf.fields(err)
                var cause: UInt64 = 0
                if let f = fields.first(where: { $0.number == 1 }), case .varint(let v) = f.value { cause = v }
                if cause == 0 { msg.resourceLimit = true }
            default: break
            }
        }
        return msg
    }

    /// BSB_Util.Json{compression=1, data=2}.
    static func jsonPayload(_ timer: Data) throws -> Data {
        var compression: UInt64 = 0
        var payload = Data()
        for f in try Protobuf.fields(timer) where f.number == 1 {
            guard case .bytes(let json) = f.value else { continue }
            for j in try Protobuf.fields(json) {
                switch (j.number, j.value) {
                case (1, .varint(let c)): compression = c
                case (2, .bytes(let d)): payload = d
                default: break
                }
            }
        }
        return compression == 1 ? try Gzip.decompress(payload) : payload
    }
}

/// A front/back panel frame, decoded to plain pixels.
public struct BarFrame: Equatable {
    public enum Screen: Int { case front = 0, back = 1 }
    public enum Encoding: Int { case plain = 0, runLength = 1, deflate = 2, deflateRunLength = 3 }
    public enum PixelFormat: Int { case rgb888 = 0, l8 = 1, l4 = 2 }

    public var screen: Screen
    public var width: Int
    public var height: Int
    /// Always RGB888, width*height*3 bytes.
    public var rgb: Data

    public enum Error: Swift.Error { case unsupported, sizeMismatch }

    public static func decode(_ data: Data) throws -> BarFrame {
        var screen = Screen.front, width = 0, height = 0
        var encoding = Encoding.plain, format = PixelFormat.rgb888
        var payload = Data()
        for f in try Protobuf.fields(data) {
            switch (f.number, f.value) {
            case (1, .varint(let v)): screen = Screen(rawValue: Int(v)) ?? .front
            case (2, .varint(let v)): width = Int(v)
            case (3, .varint(let v)): height = Int(v)
            case (4, .varint(let v)): encoding = Encoding(rawValue: Int(v)) ?? .plain
            case (5, .varint(let v)): format = PixelFormat(rawValue: Int(v)) ?? .rgb888
            case (6, .bytes(let d)): payload = d
            default: break
            }
        }
        let bytesPerPixel: Int
        switch format {
        case .rgb888: bytesPerPixel = 3
        case .l8: bytesPerPixel = 1
        case .l4: throw Error.unsupported
        }
        var raw = payload
        switch encoding {
        case .plain: break
        case .runLength: raw = RLE.decode(payload, blockSize: bytesPerPixel)
        case .deflate, .deflateRunLength:
            raw = try Inflate.raw(payload)
            if encoding == .deflateRunLength { raw = RLE.decode(raw, blockSize: bytesPerPixel) }
        }
        let expected = width * height * bytesPerPixel
        guard raw.count >= expected, expected > 0 else { throw Error.sizeMismatch }
        raw = raw.prefix(expected)
        if format == .l8 {
            var rgb = Data(capacity: expected * 3)
            for b in raw { rgb.append(contentsOf: [b, b, b]) }
            raw = rgb
        }
        return BarFrame(screen: screen, width: width, height: height, rgb: Data(raw))
    }
}

/// Firmware toolbox/rle_encode: opcode byte, high bit set = N verbatim blocks
/// follow, clear = one block repeated N times.
public enum RLE {
    public static func decode(_ src: Data, blockSize: Int) -> Data {
        var out = Data()
        var i = src.startIndex
        while i < src.endIndex {
            let op = src[i]; i += 1
            let n = Int(op & 0x7f)
            if op & 0x80 != 0 {
                let len = n * blockSize
                guard src.endIndex - i >= len else { out.append(src[i...]); break }
                out.append(src[i..<i + len]); i += len
            } else {
                guard src.endIndex - i >= blockSize else { break }
                let block = src[i..<i + blockSize]; i += blockSize
                for _ in 0..<n { out.append(block) }
            }
        }
        return out
    }
}

enum Inflate {
    /// Raw deflate (no zlib/gzip header).
    static func raw(_ data: Data, capacity: Int = 1 << 16) throws -> Data {
        var out = Data(count: capacity)
        let n = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { throw BarFrame.Error.sizeMismatch }
        return out.prefix(n)
    }
}

enum Gzip {
    static func decompress(_ data: Data) throws -> Data {
        // 10-byte header, then optional fields per flags; then raw deflate; 8-byte trailer.
        guard data.count > 18, data[0] == 0x1f, data[1] == 0x8b else { throw BarFrame.Error.unsupported }
        let flags = data[3]
        var i = 10
        if flags & 0x04 != 0 { let xlen = Int(data[i]) | Int(data[i + 1]) << 8; i += 2 + xlen }
        if flags & 0x08 != 0 { while i < data.count, data[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < data.count, data[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < data.count - 8 else { throw BarFrame.Error.unsupported }
        return try Inflate.raw(data[i..<(data.count - 8)])
    }
}
