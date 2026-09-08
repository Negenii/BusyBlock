import Foundation
import Network

/// macOS 15+ asks the person before an app may talk to the local network.
/// There is no API to read that decision; the only way to learn it is to try.
/// A Bonjour browse is the gentlest probe: denied access surfaces as a DNS
/// "policy denied" error, granted access as a ready browser (and, for us,
/// as the bar answering).
enum LocalNetworkAccess {
    enum Result { case granted, denied, undetermined }

    private static let policyDenied: Int32 = -65570   // kDNSServiceErr_PolicyDenied

    /// Calls back on the main queue once, within `timeout` seconds.
    static func probe(timeout: TimeInterval = 6, completion: @escaping (Result) -> Void) {
        let queue = DispatchQueue(label: "me.negenii.BusyBlock.lna")
        let browser = NWBrowser(for: .bonjour(type: "_http._tcp", domain: nil), using: .tcp)
        var done = false
        func finish(_ r: Result) {
            queue.async {
                guard !done else { return }
                done = true
                browser.cancel()
                DispatchQueue.main.async { completion(r) }
            }
        }
        browser.stateUpdateHandler = { state in
            switch state {
            case .waiting(let error), .failed(let error):
                if case .dns(let code) = error, code == policyDenied { finish(.denied) }
            default: break
            }
        }
        browser.browseResultsChangedHandler = { results, _ in
            if !results.isEmpty { finish(.granted) }
        }
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) {
            // No denial and no results: either granted with an empty LAN, or the
            // prompt is still up. Report undetermined; the caller may retry.
            finish(browser.state == .ready ? .undetermined : .undetermined)
        }
    }
}
