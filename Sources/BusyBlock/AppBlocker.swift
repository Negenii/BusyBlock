import AppKit

/// Hides listed apps while active and re-hides them whenever they launch or
/// come to the front. hide() is
/// ignored mid-activation, so retry a few times.
@MainActor
final class AppBlocker {
    var blockedBundleIDs: Set<String> = []
    var isActive = false {
        didSet { if isActive && !oldValue { sweep() } }
    }

    private var observers: [NSObjectProtocol] = []
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = { print($0) }) {
        self.log = log
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                Task { @MainActor [weak self] in self?.handle(app) }
            })
        }
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
    }

    private func isBlocked(_ app: NSRunningApplication) -> Bool {
        guard isActive, let id = app.bundleIdentifier else { return false }
        return blockedBundleIDs.contains(id) && id != Bundle.main.bundleIdentifier
    }

    private func handle(_ app: NSRunningApplication) {
        guard isBlocked(app) else { return }
        hide(app, attempt: 0)
    }

    /// Hide every running blocked app.
    func sweep() {
        guard isActive, !blockedBundleIDs.isEmpty else { return }
        for app in NSWorkspace.shared.runningApplications where isBlocked(app) {
            hide(app, attempt: 0)
        }
    }

    private func hide(_ app: NSRunningApplication, attempt: Int) {
        guard !app.isTerminated else { return }
        if app.isHidden && attempt > 0 { return }
        let ok = app.hide()
        if attempt == 0 { log("hide \(app.bundleIdentifier ?? "?") -> \(ok)") }
        guard attempt < 4 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !app.isHidden, !app.isTerminated, self.isBlocked(app) else { return }
            self.hide(app, attempt: attempt + 1)
        }
    }
}
