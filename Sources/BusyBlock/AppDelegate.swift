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
        controller.onHostChange = { [weak self] host in
            guard let self else { return }
            self.log("bar host now \(host) (\(self.controller.foundVia.rawValue))")
            self.stream.update(host: host, token: self.store.config.barToken)
        }
        stream.onStatus = { [weak self] connected, error in
            guard let self else { return }
            if self.controller.streamConnected != connected {
                self.log("bar stream \(connected ? "up" : "down")\(error.map { ": \($0)" } ?? "")")
            }
            self.controller.streamConnected = connected
            LiveFrames.shared.connected = connected
        }
        stream.onMessage = { [weak self] msg, received in
            guard let self else { return }
            if let ms = msg.timestampMs { self.controller.calibrate(barMs: ms, receivedAt: received) }
            if let snap = msg.timer { self.controller.ingest(snapshot: snap, receivedAt: received) }
            if let frame = msg.frames.last(where: { $0.screen == .front }) { LiveFrames.shared.frame = frame }
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
        server.onDomainChange = { [weak self] add, remove in
            guard let self else { return Data("{}".utf8) }
            // Called on the server queue; config is main-actor state.
            return DispatchQueue.main.sync {
                var c = self.store.config
                if let a = add { let d = Domain.normalize(a); if !d.isEmpty, !c.blockedDomains.contains(d) { c.blockedDomains.append(d) } }
                if let r = remove { let d = Domain.normalize(r); c.blockedDomains.removeAll { $0 == d } }
                c.blockedDomains.sort()
                self.store.save(c)
                var s = self.controller.state
                s.domains = c.blockedDomains
                return s.wireJSON()
            }
        }
        server.faviconProvider = { host, done in
            guard !host.isEmpty else { done(nil); return }
            DispatchQueue.main.async {
                FaviconLoader.shared.allowThirdParty = self.store.config.faviconFallback
                FaviconLoader.shared.png(for: host, completion: done)
            }
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
        server.onOpenRequest = { DispatchQueue.main.async { [weak self] in self?.showSettings() } }
        applyMenuBarSetting()
        store.$config.map(\.showMenuBarIcon).removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyMenuBarSetting() }.store(in: &cancellables)
        log("BusyBlock started, config at \(store.url.path)")
        // The settings window is the app's window: show it when a person
        // launched us (Finder, Launchpad, Spotlight), not when login did.
        if CommandLine.arguments.contains("--settings") || !Self.launchedAsLoginItem() { showSettings() }
    }

    /// True when launchd started us as a login item (no one clicked anything).
    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    private func applyMenuBarSetting() {
        if store.config.showMenuBarIcon {
            if menuBar == nil { menuBar = MenuBarController(controller: controller, store: store) { [weak self] in self?.showSettings() } }
        } else {
            menuBar = nil
        }
    }

    /// Dock/Finder click on a running app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    func showSettings() {
        if settings == nil { settings = SettingsWindowController(store: store, controller: controller) }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    private static let logURL = Config.defaultURL.deletingLastPathComponent().appendingPathComponent("busyblock.log")

    /// stdout plus ~/Library/Application Support/BusyBlock/busyblock.log (kept under 1 MB).
    private func log(_ s: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(s)\n"
        print(line, terminator: "")
        fflush(stdout)
        let url = Self.logURL
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
