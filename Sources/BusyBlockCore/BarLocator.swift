import Foundation
import Network

/// Finds the bar without the person doing anything: the configured host,
/// then the USB address, then `busybar.local`, then a Bonjour browse for the
/// bar's `_http._tcp` service (`busybar-<mac>`). Each candidate is probed with
/// a real request; the first one that answers wins.
public enum BarLocator {
    public static let usbHost = "10.0.4.20"
    public static let mdnsHost = "busybar.local"
    public static let serviceType = "_http._tcp"
    public static let servicePrefix = "busybar"

    public enum Via: String, Codable { case configured, usb, mdns, bonjour }

    public struct Found: Equatable {
        public let host: String
        public let via: Via
        public let needsToken: Bool
    }

    public enum Probe: Equatable { case ok, needsToken, unreachable }

    /// Candidates in the order to try, deduplicated, empty strings dropped.
    public static func candidates(configured: String?, discovered: [String] = []) -> [(String, Via)] {
        var seen = Set<String>()
        var out: [(String, Via)] = []
        func add(_ h: String?, _ via: Via) {
            guard let h = h?.trimmingCharacters(in: .whitespacesAndNewlines), !h.isEmpty,
                  !seen.contains(h.lowercased()) else { return }
            seen.insert(h.lowercased())
            out.append((h, via))
        }
        add(configured, .configured)
        add(usbHost, .usb)
        add(mdnsHost, .mdns)
        for d in discovered { add(d, .bonjour) }
        return out
    }

    /// One blocking probe. Call off the main thread.
    public static func probe(host: String, token: String?, timeout: TimeInterval = 2) -> Probe {
        var headers: [String: String] = [:]
        if let token, !token.isEmpty { headers["X-API-Token"] = token }
        do {
            let data = try RawHTTPClient.get(host: host, path: "/api/busy/snapshot", headers: headers, timeout: timeout)
            return (try? BusySnapshot.decode(data)) != nil ? .ok : .unreachable
        } catch RawHTTPClient.Error.status(let code) where code == 401 || code == 403 {
            return .needsToken
        } catch {
            return .unreachable
        }
    }

    /// Bonjour browse for `busybar-*` services; resolves each to host:port.
    /// Blocking, bounded by `timeout`. Call off the main thread.
    public static func browse(timeout: TimeInterval = 3) -> [String] {
        let queue = DispatchQueue(label: "me.negenii.BusyBlock.browse")
        let lock = NSLock()
        var results: [String] = []
        var pending = 0
        let done = DispatchSemaphore(value: 0)

        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { found, _ in
            for r in found {
                guard case .service(let name, _, _, _) = r.endpoint,
                      name.lowercased().hasPrefix(servicePrefix) else { continue }
                lock.lock(); pending += 1; lock.unlock()
                // Let Network.framework resolve the service to an address.
                let conn = NWConnection(to: r.endpoint, using: .tcp)
                conn.stateUpdateHandler = { st in
                    switch st {
                    case .ready:
                        if case .hostPort(let host, let port)? = conn.currentPath?.remoteEndpoint {
                            let h: String
                            switch host {
                            case .ipv4(let a): h = "\(a)"
                            case .ipv6(let a): h = "[\(a)]"
                            case .name(let n, _): h = n
                            @unknown default: h = "\(host)"
                            }
                            let entry = port.rawValue == 80 ? h : "\(h):\(port.rawValue)"
                            lock.lock(); if !results.contains(entry) { results.append(entry) }; lock.unlock()
                        }
                        conn.cancel()
                    case .failed, .cancelled:
                        lock.lock(); pending -= 1; lock.unlock()
                    default: break
                    }
                }
                conn.start(queue: queue)
            }
        }
        browser.start(queue: queue)
        _ = done.wait(timeout: .now() + timeout)
        browser.cancel()
        lock.lock(); defer { lock.unlock() }
        // Strip interface zone suffixes ("10.1.1.76%en1", "[fe80::1%en0]") that a raw socket can't use.
        return results.map { $0.replacingOccurrences(of: "%[A-Za-z0-9]+", with: "", options: .regularExpression) }
    }

    /// Full search. Blocking; call off the main thread.
    public static func locate(configured: String?, token: String?, log: (String) -> Void = { _ in }) -> Found? {
        for (host, via) in candidates(configured: configured) {
            // USB answers within milliseconds or not at all; don't make people wait 3 s on it.
            let timeout: TimeInterval = (host == usbHost || via == .usb) ? 0.8 : 2
            let p = probe(host: host, token: token, timeout: timeout)
            log("probe \(host) (\(via.rawValue)): \(p)")
            if p != .unreachable { return Found(host: host, via: via, needsToken: p == .needsToken) }
        }
        let discovered = browse()
        log("bonjour: \(discovered)")
        for host in discovered {
            let p = probe(host: host, token: token)
            log("probe \(host) (bonjour): \(p)")
            if p != .unreachable { return Found(host: host, via: .bonjour, needsToken: p == .needsToken) }
        }
        return nil
    }
}
