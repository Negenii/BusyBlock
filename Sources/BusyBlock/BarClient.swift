import Foundation
import BusyBlockCore

/// Fetches `/api/busy/snapshot` from the bar (or busybar-manager, which proxies it)
/// over a plain socket with a hard timeout. See RawHTTPClient for why not URLSession.
final class BarClient {
    private var host: String
    private var token: String?
    private let timeout: TimeInterval = 3

    enum ClientError: Error { case badResponse }

    init(config: Config) {
        host = config.barHost
        token = config.barToken
    }

    func update(config: Config) {
        host = config.barHost
        token = config.barToken
    }

    /// GET /api/time → {"timestamp":"2026-09-07T22:29:02+01:00"} → ms since epoch.
    func fetchBarTimeMs() async throws -> Int {
        let host = self.host
        var headers: [String: String] = [:]
        if let token, !token.isEmpty { headers["X-API-Token"] = token }
        let timeout = self.timeout
        let data = try await Task.detached(priority: .utility) {
            try RawHTTPClient.get(host: host, path: "/api/time", headers: headers, timeout: timeout)
        }.value
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["timestamp"] as? String else { throw ClientError.badResponse }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        guard let date = fmt.date(from: text) ?? ISO8601DateFormatter().date(from: text) else { throw ClientError.badResponse }
        return Int(date.timeIntervalSince1970 * 1000)
    }

    func fetchSnapshot() async throws -> BusySnapshot {
        let host = self.host
        var headers: [String: String] = [:]
        if let token, !token.isEmpty { headers["X-API-Token"] = token }
        let timeout = self.timeout
        let data = try await Task.detached(priority: .utility) {
            try RawHTTPClient.get(host: host, path: "/api/busy/snapshot", headers: headers, timeout: timeout)
        }.value
        return try BusySnapshot.decode(data)
    }
}
