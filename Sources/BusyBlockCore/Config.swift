import Foundation

public struct Config: Codable, Equatable {
    public var barHost: String
    public var barToken: String?
    public var pollIntervalSec: Double
    public var localPort: UInt16
    public var blockDuringRest: Bool
    public var blockedApps: [String]
    public var blockedDomains: [String]

    public init(barHost: String = "10.0.4.20", barToken: String? = nil,
                pollIntervalSec: Double = 2, localPort: UInt16 = 48321,
                blockDuringRest: Bool = false, blockedApps: [String] = [],
                blockedDomains: [String] = []) {
        self.barHost = barHost
        self.barToken = barToken
        self.pollIntervalSec = pollIntervalSec
        self.localPort = localPort
        self.blockDuringRest = blockDuringRest
        self.blockedApps = blockedApps
        self.blockedDomains = blockedDomains
    }

    public static let defaults = Config()

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BusyBlock", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    /// Missing keys fall back to defaults so an older file keeps loading.
    public static func load(from url: URL) throws -> Config {
        let data = try Data(contentsOf: url)
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> Config {
        let d = try JSONDecoder().decode(Partial.self, from: data)
        var c = Config.defaults
        if let v = d.barHost { c.barHost = v }
        c.barToken = d.barToken.flatMap { $0.isEmpty ? nil : $0 }
        if let v = d.pollIntervalSec { c.pollIntervalSec = max(0.5, v) }
        if let v = d.localPort { c.localPort = v }
        if let v = d.blockDuringRest { c.blockDuringRest = v }
        if let v = d.blockedApps { c.blockedApps = v }
        if let v = d.blockedDomains {
            c.blockedDomains = Array(Set(v.map(Domain.normalize).filter { !$0.isEmpty })).sorted()
        }
        return c
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    /// Load or, when the file is absent, write defaults and return them.
    public static func loadOrCreate(at url: URL = defaultURL) -> Config {
        if let c = try? load(from: url) { return c }
        try? Config.defaults.save(to: url)
        return .defaults
    }

    private struct Partial: Decodable {
        var barHost: String?
        var barToken: String?
        var pollIntervalSec: Double?
        var localPort: UInt16?
        var blockDuringRest: Bool?
        var blockedApps: [String]?
        var blockedDomains: [String]?
    }
}
