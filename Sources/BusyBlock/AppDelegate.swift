import AppKit
import Combine
import BusyBlockCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ConfigStore!
    private var controller: BlockController!
    private var blocker: AppBlocker!
    private var server: LocalServer!
    private var stream: BarStream!
    private var lastFrameJSON: Data?
    private var lastFrameRGB: Data?
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
            self.stream.update(host: cfg.barHost, token: cfg.barToken)
            self.blocker.sweep()
        }.store(in: &cancellables)

        stream = BarStream(host: store.config.barHost, token: store.config.barToken, log: log)
        stream.onStatus = { [weak self] connected, error in
            guard let self else { return }
            if self.controller.streamConnected != connected {
                self.log("bar stream \(connected ? "up" : "down")\(error.map { ": \($0)" } ?? "")")
            }
            self.controller.streamConnected = connected
        }
        stream.onMessage = { [weak self] msg, received in
            guard let self else { return }
            if let ms = msg.timestampMs { self.controller.calibrate(barMs: ms, receivedAt: received) }
            if let snap = msg.timer { self.controller.ingest(snapshot: snap, receivedAt: received) }
            if self.store.config.showScreenInBrowser,
               let frame = msg.frames.last(where: { $0.screen == .front }), frame.rgb != self.lastFrameRGB {
                self.lastFrameRGB = frame.rgb
                let json = try? JSONSerialization.data(withJSONObject: [
                    "w": frame.width, "h": frame.height, "rgb": frame.rgb.base64EncodedString(),
                ])
                self.lastFrameJSON = json
                if let json { self.server.broadcast(event: "frame", data: json) }
            }
        }
        controller.$state.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] state in
            self?.server.broadcast(event: "state", data: state.wireJSON())
        }.store(in: &cancellables)

        server = LocalServer(port: store.config.localPort, log: log) { [weak self] in
            self?.controller.state ?? .offline(domains: [])
        }
        server.initialEvents = { [weak self] in
            guard let self else { return [] }
            var events = [("state", self.controller.state.wireJSON())]
            if self.store.config.showScreenInBrowser, let f = self.lastFrameJSON { events.append(("frame", f)) }
            return events
        }
        do { try server.start() } catch { log("local server start failed: \(error)") }

        controller.start()
        stream.start()
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
