import Foundation

/// Sites people usually block with tools like this. Shown as quick-add pills.
public enum Suggestions {
    public static let domains: [String] = [
        "youtube.com", "instagram.com", "facebook.com", "x.com", "tiktok.com",
        "reddit.com", "twitch.tv", "netflix.com", "linkedin.com", "pinterest.com",
        "threads.net", "discord.com", "web.telegram.org", "vk.com", "pikabu.ru",
        "news.ycombinator.com", "9gag.com",
    ]

    /// Suggestions not yet in the list.
    public static func remaining(given blocked: [String]) -> [String] {
        let have = Set(blocked.map { $0.lowercased() })
        return domains.filter { !have.contains($0) }
    }
}

/// Which browser-extension origins may write to the helper. Web pages can
/// reach 127.0.0.1 too, so state-changing requests must come from an
/// extension page, never from a site.
public enum OriginPolicy {
    public static func isExtension(_ origin: String?) -> Bool {
        guard let o = origin?.lowercased() else { return false }
        return o.hasPrefix("chrome-extension://") || o.hasPrefix("moz-extension://")
            || o.hasPrefix("safari-web-extension://") || o.hasPrefix("extension://")
    }
}
