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

    /// Cache format version: bump when the lookup gets better icons, so old
    /// low-res entries are refetched.
    private static let cacheVersion = 3

    private func cacheFile(_ host: String) -> URL {
        dir.appendingPathComponent(host.replacingOccurrences(of: "/", with: "_") + "@\(Self.cacheVersion).png")
    }

    /// Whether the DuckDuckGo fallback may be used (Settings → favicons switch).
    var allowThirdParty = true

    /// PNG of the largest representation (ICO files carry several sizes).
    static func pngData(_ img: NSImage) -> Data? {
        let biggest = img.representations.max { $0.pixelsWide < $1.pixelsWide }
        if let bmp = biggest as? NSBitmapImageRep, let png = bmp.representation(using: .png, properties: [:]) { return png }
        guard let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff) else { return nil }
        return bmp.representation(using: .png, properties: [:])
    }

    /// PNG bytes for the extension pages (served by LocalServer).
    func png(for entry: String, completion: @escaping (Data?) -> Void) {
        image(for: entry) { img in
            guard let img, let png = Self.pngData(img) else { completion(nil); return }
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
                    if let png = Self.pngData(image) { try? png.write(to: self.cacheFile(host)) }
                }
                let cbs = self.waiters.removeValue(forKey: host) ?? []
                cbs.forEach { $0(image) }
            }
        }
    }

    /// Collects every icon the site offers (home-screen icons, <link rel=icon>,
    /// favicon.ico) and keeps the sharpest one actually served. Third-party
    /// icon services only when allowed in Settings.
    private static func fetch(host: String, session: URLSession, thirdParty: Bool) async -> NSImage? {
        let hosts = [host, "www." + host]
        var candidates: [String] = []
        for h in hosts {
            if let html = await fetchText(URL(string: "https://\(h)/")!, session: session) {
                candidates.append(contentsOf: iconLinks(in: html, base: URL(string: "https://\(h)/")!))
                break
            }
        }
        for h in hosts {
            candidates.append("https://\(h)/apple-touch-icon.png")
            candidates.append("https://\(h)/apple-touch-icon-precomposed.png")
        }
        for h in hosts { candidates.append("https://\(h)/favicon.ico") }
        if thirdParty {
            candidates.append("https://www.google.com/s2/favicons?domain=\(host)&sz=128")
            candidates.append("https://icons.duckduckgo.com/ip3/\(host).ico")
        }

        var best: NSImage?
        var bestPx: CGFloat = 0
        var tried = 0
        var seen = Set<String>()
        for c in candidates where seen.insert(c).inserted {
            if tried >= 6 || bestPx >= 120 { break }
            guard let url = URL(string: c) else { continue }
            tried += 1
            guard let img = await fetchImage(url, session: session) else { continue }
            let px = pixelWidth(img)
            if px > bestPx { best = img; bestPx = px }
        }
        return best
    }

    /// Largest bitmap inside (ICO files carry several sizes).
    private static func pixelWidth(_ img: NSImage) -> CGFloat {
        img.representations.map { CGFloat($0.pixelsWide) }.max() ?? img.size.width
    }

    private static func fetchImage(_ url: URL, session: URLSession) async -> NSImage? {
        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, http.statusCode == 200, data.count > 64,
              !(http.mimeType ?? "").contains("html"),
              let img = NSImage(data: data), img.size.width >= 8 else { return nil }
        return img
    }

    private static func fetchText(_ url: URL, session: URLSession) async -> String? {
        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              (http.mimeType ?? "").contains("html") else { return nil }
        return String(decoding: data.prefix(300_000), as: UTF8.self)
    }

    /// <link rel="apple-touch-icon" href=…> and <link rel="icon" sizes="NxN" href=…>,
    /// largest declared size first; apple-touch-icon counts as 180 px.
    static func iconLinks(in html: String, base: URL) -> [String] {
        var found: [(Int, String)] = []
        let tagRe = try! NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive])
        let attrRe = try! NSRegularExpression(pattern: "([a-zA-Z-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]+))", options: [])
        let ns = html as NSString
        for m in tagRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            var attrs: [String: String] = [:]
            let t = tag as NSString
            for a in attrRe.matches(in: tag, range: NSRange(location: 0, length: t.length)) {
                let name = t.substring(with: a.range(at: 1)).lowercased()
                let value = [2, 3, 4].compactMap { a.range(at: $0).location == NSNotFound ? nil : t.substring(with: a.range(at: $0)) }.first ?? ""
                attrs[name] = value
            }
            guard let rel = attrs["rel"]?.lowercased(), let href = attrs["href"], !href.isEmpty else { continue }
            let rels = rel.split(separator: " ").map(String.init)
            var score = 0
            if rels.contains("apple-touch-icon") || rels.contains("apple-touch-icon-precomposed") { score = 180 }
            else if rels.contains("icon") || rels.contains("shortcut") {
                score = 16
                if let sizes = attrs["sizes"]?.lowercased(), let n = Int(sizes.split(separator: "x").first ?? "") { score = n }
                if href.lowercased().hasSuffix(".svg") { score = 1 }   // NSImage handles SVG poorly at small sizes
            } else { continue }
            if let abs = URL(string: href, relativeTo: base)?.absoluteURL.absoluteString, abs.hasPrefix("http") {
                found.append((score, abs))
            }
        }
        return found.sorted { $0.0 > $1.0 }.map { $0.1 }
    }
}
