import Foundation
import BusyBlockCore

/// Fetches `/api/busy/snapshot` from the bar (or busybar-manager, which proxies it)
/// over a plain socket with a hard timeout. See RawHTTPClient for why not URLSession.
final class BarClient {
    private var host: String
    private var token: String?
    private let timeout: TimeInterval = 3

    init(config: Config) {
        host = config.barHost
        token = config.barToken
    }

    func update(config: Config) {
        host = config.barHost
        token = config.barToken
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
