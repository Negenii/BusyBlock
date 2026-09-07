import Foundation
import BusyBlockCore

/// Fetches `/api/busy/snapshot` from the bar (or busybar-manager, which proxies it).
final class BarClient {
    private let session: URLSession
    private var host: String
    private var token: String?

    init(config: Config) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3
        cfg.timeoutIntervalForResource = 4
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
        host = config.barHost
        token = config.barToken
    }

    func update(config: Config) {
        host = config.barHost
        token = config.barToken
    }

    enum ClientError: Error { case badURL, badStatus(Int) }

    func fetchSnapshot() async throws -> BusySnapshot {
        var h = host.trimmingCharacters(in: .whitespaces)
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        while h.hasSuffix("/") { h.removeLast() }
        guard let url = URL(string: "http://\(h)/api/busy/snapshot") else { throw ClientError.badURL }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let token, !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-API-Token") }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.badStatus(http.statusCode)
        }
        return try BusySnapshot.decode(data)
    }
}
