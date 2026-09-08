import Foundation

/// Sites people usually block with tools like this. Shown as quick-add pills.
public enum Suggestions {
    public static let domains: [String] = [
        "youtube.com", "instagram.com", "facebook.com", "x.com", "tiktok.com",
        "reddit.com", "twitch.tv", "netflix.com", "linkedin.com", "pinterest.com",
        "threads.net", "discord.com", "web.telegram.org", "news.ycombinator.com", "9gag.com",
    ]

    /// The short lists the welcome tour shows: enough to get going, few
    /// enough to fit the page. Everything else is a click away in Settings.
    public static let tourDomains: [String] = Array(domains.prefix(6))
    public static let tourAppLimit = 6

    /// Apps people usually hide, by bundle id. Only the installed ones are shown.
    public static let apps: [(id: String, name: String)] = [
        ("ru.keepcoder.Telegram", "Telegram"), ("org.telegram.desktop", "Telegram Desktop"),
        ("net.whatsapp.WhatsApp", "WhatsApp"), ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"), ("com.apple.MobileSMS", "Messages"),
        ("com.apple.mail", "Mail"), ("com.twitter.twitter-mac", "X"),
        ("org.whispersystems.signal-desktop", "Signal"), ("com.viber.osx", "Viber"),
        ("com.facebook.archon", "Messenger"), ("com.microsoft.teams2", "Teams"),
        ("com.valvesoftware.steam", "Steam"), ("com.epicgames.EpicGamesLauncher", "Epic Games"),
        ("com.apple.TV", "TV"), ("com.apple.Music", "Music"), ("com.spotify.client", "Spotify"),
        ("com.apple.news", "News"), ("com.apple.Photos", "Photos"),
    ]

    /// App suggestions not yet in the list; `installed` decides which exist on this Mac.
    public static func remainingApps(given blocked: [String], installed: (String) -> Bool) -> [(id: String, name: String)] {
        let have = Set(blocked)
        return apps.filter { !have.contains($0.id) && installed($0.id) }
    }

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
