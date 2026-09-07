import Foundation

/// What the helper is doing right now. Served as JSON to the extension.
public struct BlockState: Codable, Equatable {
    public var isBlocking: Bool
    /// nil = infinite timer or unknown.
    public var endsAt: Date?
    public var paused: Bool
    public var barConnected: Bool
    /// "work" | "rest" | "idle" | "offline"
    public var phase: String
    /// Configured domains; only enforced while `isBlocking`.
    public var domains: [String]

    public init(isBlocking: Bool, endsAt: Date?, paused: Bool, barConnected: Bool,
                phase: String, domains: [String]) {
        self.isBlocking = isBlocking
        self.endsAt = endsAt
        self.paused = paused
        self.barConnected = barConnected
        self.phase = phase
        self.domains = domains
    }

    public static func offline(domains: [String]) -> BlockState {
        BlockState(isBlocking: false, endsAt: nil, paused: false, barConnected: false,
                   phase: "offline", domains: domains)
    }

    /// Wire format for the extension: `endsAt` in ms since epoch, 0 when nil.
    public func wireJSON() -> Data {
        let obj: [String: Any] = [
            "isBlocking": isBlocking,
            "endsAt": endsAt.map { Int($0.timeIntervalSince1970 * 1000) } ?? 0,
            "paused": paused,
            "barConnected": barConnected,
            "phase": phase,
            "domains": domains,
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
