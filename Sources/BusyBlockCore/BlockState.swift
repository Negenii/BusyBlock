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
    /// Extension should mirror the bar's screen instead of its own countdown.
    public var showScreen: Bool

    public init(isBlocking: Bool, endsAt: Date?, paused: Bool, barConnected: Bool,
                phase: String, domains: [String], showScreen: Bool = true) {
        self.isBlocking = isBlocking
        self.endsAt = endsAt
        self.paused = paused
        self.barConnected = barConnected
        self.phase = phase
        self.domains = domains
        self.showScreen = showScreen
    }

    public static func offline(domains: [String], showScreen: Bool = true) -> BlockState {
        BlockState(isBlocking: false, endsAt: nil, paused: false, barConnected: false,
                   phase: "offline", domains: domains, showScreen: showScreen)
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
            "showScreen": showScreen,
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}
