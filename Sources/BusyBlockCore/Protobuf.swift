import Foundation

/// Just enough protobuf wire-format decoding for the bar's state stream.
public enum Protobuf {
    public enum Value: Equatable {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(Data)
    }
    public struct Field: Equatable {
        public let number: Int
        public let value: Value
    }
    public enum Error: Swift.Error { case truncated, badWireType(Int) }

    public static func fields(_ data: Data) throws -> [Field] {
        var out: [Field] = []
        var i = data.startIndex
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard i < data.endIndex else { throw Error.truncated }
                let b = data[i]; i += 1
                result |= UInt64(b & 0x7f) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { throw Error.truncated }
            }
        }
        while i < data.endIndex {
            let tag = try varint()
            let number = Int(tag >> 3)
            let wire = Int(tag & 7)
            switch wire {
            case 0: out.append(Field(number: number, value: .varint(try varint())))
            case 1:
                guard data.endIndex - i >= 8 else { throw Error.truncated }
                var v: UInt64 = 0
                for k in 0..<8 { v |= UInt64(data[i + k]) << (8 * UInt64(k)) }
                i += 8
                out.append(Field(number: number, value: .fixed64(v)))
            case 2:
                let len = Int(try varint())
                guard data.endIndex - i >= len else { throw Error.truncated }
                out.append(Field(number: number, value: .bytes(Data(data[i..<i + len]))))
                i += len
            case 5:
                guard data.endIndex - i >= 4 else { throw Error.truncated }
                var v: UInt32 = 0
                for k in 0..<4 { v |= UInt32(data[i + k]) << (8 * UInt32(k)) }
                i += 4
                out.append(Field(number: number, value: .fixed32(v)))
            default: throw Error.badWireType(wire)
            }
        }
        return out
    }

    // Encoding helpers, used by tests to build messages.
    public static func encodeVarint(_ v: UInt64) -> Data {
        var v = v; var d = Data()
        repeat { var b = UInt8(v & 0x7f); v >>= 7; if v != 0 { b |= 0x80 }; d.append(b) } while v != 0
        return d
    }
    public static func field(_ n: Int, varint v: UInt64) -> Data { encodeVarint(UInt64(n << 3)) + encodeVarint(v) }
    public static func field(_ n: Int, bytes d: Data) -> Data { encodeVarint(UInt64(n << 3 | 2)) + encodeVarint(UInt64(d.count)) + d }
    public static func field(_ n: Int, fixed64 v: UInt64) -> Data {
        var d = encodeVarint(UInt64(n << 3 | 1))
        for k in 0..<8 { d.append(UInt8((v >> (8 * UInt64(k))) & 0xff)) }
        return d
    }
}
