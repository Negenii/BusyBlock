import Foundation

/// The bar's `GET /api/busy/snapshot` payload, reduced to what blocking needs.
public struct BusySnapshot: Equatable {
    public enum Kind: String, Decodable {
        case notStarted = "NOT_STARTED"
        case simple = "SIMPLE"
        case infinite = "INFINITE"
        case interval = "INTERVAL"
    }

    public var kind: Kind
    public var isPaused: Bool
    /// SIMPLE only.
    public var timeLeftMs: Int?
    /// INTERVAL only. Even = work, odd = rest (firmware: `is_rest = index % 2`).
    public var currentInterval: Int?
    /// INTERVAL only.
    public var currentIntervalTimeLeftMs: Int?
    /// Bar clock (ms since epoch) when this snapshot was captured. Stock firmware
    /// serves a cached snapshot that only refreshes on user actions, so this is
    /// the reference point for the remaining time, not the poll moment.
    public var timestampMs: Int?

    public init(kind: Kind, isPaused: Bool = false, timeLeftMs: Int? = nil,
                currentInterval: Int? = nil, currentIntervalTimeLeftMs: Int? = nil,
                timestampMs: Int? = nil) {
        self.kind = kind
        self.isPaused = isPaused
        self.timeLeftMs = timeLeftMs
        self.currentInterval = currentInterval
        self.currentIntervalTimeLeftMs = currentIntervalTimeLeftMs
        self.timestampMs = timestampMs
    }

    public var isRestPhase: Bool {
        kind == .interval && ((currentInterval ?? 0) % 2 == 1)
    }

    /// Milliseconds until the current phase ends; nil for infinite / not started.
    public var phaseTimeLeftMs: Int? {
        switch kind {
        case .simple: return timeLeftMs
        case .interval: return currentIntervalTimeLeftMs
        case .infinite, .notStarted: return nil
        }
    }
}

extension BusySnapshot: Decodable {
    private enum Envelope: String, CodingKey { case snapshot, timestampMs = "snapshot_timestamp_ms" }
    private enum Keys: String, CodingKey {
        case type
        case isPaused = "is_paused"
        case timeLeftMs = "time_left_ms"
        case currentInterval = "current_interval"
        case currentIntervalTimeLeftMs = "current_interval_time_left_ms"
    }

    public init(from decoder: Decoder) throws {
        // Accept both the `{snapshot:{...}}` envelope and a bare snapshot.
        let inner: KeyedDecodingContainer<Keys>
        if let env = try? decoder.container(keyedBy: Envelope.self),
           env.contains(.snapshot) {
            inner = try env.nestedContainer(keyedBy: Keys.self, forKey: .snapshot)
            timestampMs = try env.decodeIfPresent(Int.self, forKey: .timestampMs)
        } else {
            inner = try decoder.container(keyedBy: Keys.self)
            timestampMs = nil
        }
        kind = try inner.decode(Kind.self, forKey: .type)
        isPaused = try inner.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        timeLeftMs = try inner.decodeIfPresent(Int.self, forKey: .timeLeftMs)
        currentInterval = try inner.decodeIfPresent(Int.self, forKey: .currentInterval)
        currentIntervalTimeLeftMs = try inner.decodeIfPresent(Int.self, forKey: .currentIntervalTimeLeftMs)
    }

    public static func decode(_ data: Data) throws -> BusySnapshot {
        try JSONDecoder().decode(BusySnapshot.self, from: data)
    }
}
