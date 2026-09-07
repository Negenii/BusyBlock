import AppKit
import Combine
import BusyBlockCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ConfigStore!
    private var controller: BlockController!
    private var blocker: AppBlocker!
    private var server: LocalServer!
    private var menuBar: MenuBarController!
    private var settings: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        store = ConfigStore(log: log)
        controller = BlockController(config: store.config)
        blocker = AppBlocker(log: log)
        blocker.blockedBundleIDs = Set(store.config.blockedApps)

        controller.onChange = { [weak self] old, new in
            guard let self else { return }
            if old.isBlocking != new.isBlocking || old.phase != new.phase || old.barConnected != new.barConnected {
                self.log("state: \(new.phase) blocking=\(new.isBlocking) bar=\(new.barConnected)")
            }
            self.blocker.isActive = new.isBlocking
        }

        store.$config.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] cfg in
            guard let self else { return }
            self.blocker.blockedBundleIDs = Set(cfg.blockedApps)
            self.controller.reload(config: cfg)
            self.blocker.sweep()
        }.store(in: &cancellables)

        server = LocalServer(port: store.config.localPort, log: log) { [weak self] in
            self?.controller.state ?? .offline(domains: [])
        }
        do { try server.start() } catch { log("local server start failed: \(error)") }

        controller.start()
        menuBar = MenuBarController(controller: controller, store: store) { [weak self] in self?.showSettings() }
        log("BusyBlock started, config at \(store.url.path)")
    }

    func showSettings() {
        if settings == nil { settings = SettingsWindowController(store: store, controller: controller) }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    private func log(_ s: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        print("[\(ts)] \(s)")
        fflush(stdout)
    }
}
