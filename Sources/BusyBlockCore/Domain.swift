import Foundation

public enum Domain {
    /// Lowercase, no scheme, no port, no leading "www.". Keeps a path if given
    /// ("site.com/section"). Empty when it doesn't look like a host.
    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        var path = ""
        if let slash = s.firstIndex(of: "/") {
            path = String(s[slash...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            s = String(s[..<slash])
        }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        guard s.contains("."), !s.contains(" ") else { return "" }
        return path.isEmpty ? s : s + "/" + path
    }

    /// Same rule as the extension's shouldBlock: host equals the entry or is a
    /// subdomain of it; an entry with a path matches as a prefix of host+path.
    public static func matches(host: String, path: String, entry: String) -> Bool {
        let host = host.lowercased()
        let slash = entry.firstIndex(of: "/")
        let entryHost = slash.map { String(entry[..<$0]) } ?? entry
        let entryPath = slash.map { String(entry[$0...]) } ?? ""
        let hostOK = host == entryHost || host.hasSuffix("." + entryHost)
        guard hostOK else { return false }
        if entryPath.isEmpty { return true }
        return (entryHost + path).hasPrefix(entryHost + entryPath)
    }
}
