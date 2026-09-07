import AppKit
import BusyBlockCore

/// Favicons for the blocked-domains list. Tries the site's own /favicon.ico
/// first, then DuckDuckGo's icon service. Cached in memory and on disk next
/// to the config so the list draws instantly next time.
@MainActor
final class FaviconLoader {
    static let shared = FaviconLoader()

    private var memory: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private var waiters: [String: [(NSImage?) -> Void]] = [:]
    private let session: URLSession
    private let dir: URL

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 6
        cfg.timeoutIntervalForResource = 10
        cfg.httpAdditionalHeaders = ["User-Agent": "BusyBlock/0.1 (favicon)"]
        session = URLSession(configuration: cfg)
        dir = Config.defaultURL.deletingLastPathComponent().appendingPathComponent("favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Host part of a block-list entry ("reddit.com/r" → "reddit.com").
    static func host(of entry: String) -> String {
        entry.split(separator: "/").first.map(String.init) ?? entry
    }

    private func cacheFile(_ host: String) -> URL {
        dir.appendingPathComponent(host.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    /// Whether the DuckDuckGo fallback may be used (Settings → favicons switch).
    var allowThirdParty = true

    /// PNG bytes for the extension pages (served by LocalServer).
    func png(for entry: String, completion: @escaping (Data?) -> Void) {
        image(for: entry) { img in
            guard let img, let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { completion(nil); return }
            completion(png)
        }
    }

    /// Calls back on the main queue, possibly synchronously from cache.
    func image(for entry: String, completion: @escaping (NSImage?) -> Void) {
        let host = Self.host(of: entry)
        if let img = memory[host] { completion(img); return }
        if let img = NSImage(contentsOf: cacheFile(host)) {
            memory[host] = img
            completion(img)
            return
        }
        waiters[host, default: []].append(completion)
        guard !inFlight.contains(host) else { return }
        inFlight.insert(host)
        let thirdParty = allowThirdParty
        Task { [weak self] in
            let image = await Self.fetch(host: host, session: self?.session ?? .shared, thirdParty: thirdParty)
            await MainActor.run {
                guard let self else { return }
                self.inFlight.remove(host)
                if let image {
                    self.memory[host] = image
                    if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: self.cacheFile(host))
                    }
                }
                let cbs = self.waiters.removeValue(forKey: host) ?? []
                cbs.forEach { $0(image) }
            }
        }
    }

    private static func fetch(host: String, session: URLSession, thirdParty: Bool) async -> NSImage? {
        var candidates = ["https://\(host)/favicon.ico", "https://www.\(host)/favicon.ico"]
        if thirdParty { candidates.append("https://icons.duckduckgo.com/ip3/\(host).ico") }
        for c in candidates {
            guard let url = URL(string: c) else { continue }
            if let (data, resp) = try? await session.data(from: url),
               let http = resp as? HTTPURLResponse, http.statusCode == 200, data.count > 64,
               let img = NSImage(data: data), img.size.width > 0 {
                return img
            }
        }
        return nil
    }
}
