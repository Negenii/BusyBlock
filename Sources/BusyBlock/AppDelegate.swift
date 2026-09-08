import AppKit
import Combine
import Network
import BusyBlockCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ConfigStore!
    private var controller: BlockController!
    private var blocker: AppBlocker!
    private var server: LocalServer!
    private var stream: BarStream!
    private var lastFrameJSON: Data?
    private let pathMonitor = NWPathMonitor()
    private var pathDebounce: DispatchWorkItem?
    private var lastFrameRGB: Data?
    private var menuBar: MenuBarController!
    private var settings: SettingsWindowController?
    private var onboarding: OnboardingWindowController?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = ConfigStore(log: log)
        applyDockSetting()
        store.$config.map(\.showDockIcon).removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyDockSetting() }.store(in: &cancellables)
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
            // Follow the host the controller is actually on (may be a discovered one).
            self.stream.update(host: self.controller.activeHost, token: cfg.barToken)
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
            let wasConnected = self.controller.streamConnected
            if wasConnected != connected {
                self.log("bar stream \(connected ? "up" : "down")\(error.map { ": \($0)" } ?? "")")
            }
            self.controller.streamConnected = connected
            if wasConnected && !connected { self.controller.linkSuspect() }
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

        // First run: the onboarding asks for local-network access before we
        // touch the LAN, so the system prompt appears at the right moment.
        if store.config.onboardingDone || CommandLine.arguments.contains("--settings") { startNetworking() }
        // Interfaces coming and going (USB cable, Wi-Fi) are the usual reason
        // the bar moves; re-check right away instead of waiting for timeouts.
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pathDebounce?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.log("network path changed"); self?.controller.linkSuspect() }
                self.pathDebounce = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "me.negenii.BusyBlock.path"))
        server.onOpenRequest = { DispatchQueue.main.async { [weak self] in self?.showSettings() } }
        applyMenuBarSetting()
        store.$config.map(\.showMenuBarIcon).removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyMenuBarSetting() }.store(in: &cancellables)
        log("BusyBlock started, config at \(store.url.path)")
        // The settings window is the app's window: show it when a person
        // launched us (Finder, Launchpad, Spotlight), not when login did.
        if CommandLine.arguments.contains("--onboarding") || !store.config.onboardingDone {
            showOnboarding()
        } else if CommandLine.arguments.contains("--settings") || openRequestedBeforeLaunch || !Self.launchedAsLoginItem() {
            showSettings()
        }
    }

    private var networkingStarted = false
    func startNetworking() {
        guard !networkingStarted else { return }
        networkingStarted = true
        controller.start()
        stream.start()
        log("networking started")
    }

    /// True when launchd started us as a login item (no one clicked anything).
    private static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    private func applyDockSetting() {
        let policy: NSApplication.ActivationPolicy = store.config.showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            // Switching to .regular hides windows for a moment; bring ours back.
            if policy == .regular, let w = settings?.window, w.isVisible { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil) }
        }
    }

    private func applyMenuBarSetting() {
        if store.config.showMenuBarIcon {
            if menuBar == nil { menuBar = MenuBarController(controller: controller, store: store) { [weak self] in self?.showSettings() } }
        } else {
            menuBar = nil
        }
    }

    /// busyblock://open from the browser popup (Chrome and friends). This can
    /// arrive before applicationDidFinishLaunching when the URL is what
    /// launched us, so just remember it until we're set up.
    private var openRequestedBeforeLaunch = false
    func application(_ application: NSApplication, open urls: [URL]) {
        if store == nil { openRequestedBeforeLaunch = true } else { showSettings() }
    }

    /// Dock/Finder click on a running app.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    func showOnboarding() {
        if onboarding == nil {
            onboarding = OnboardingWindowController(store: store, controller: controller, startNetworking: { [weak self] in self?.startNetworking() }) { [weak self] in
                self?.onboarding = nil
                self?.startNetworking()
                self?.showSettings(highlightSetup: true)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        onboarding?.showWindow(nil)
        onboarding?.window?.makeKeyAndOrderFront(nil)
    }

    func showSettings(highlightSetup: Bool = false) {
        guard store != nil, controller != nil else { openRequestedBeforeLaunch = true; return }
        if !store.config.onboardingDone && onboarding == nil && !highlightSetup { showOnboarding(); return }
        if settings == nil {
            settings = SettingsWindowController(store: store, controller: controller)
            settings?.onReplayOnboarding = { [weak self] in self?.settings?.window?.orderOut(nil); self?.showOnboarding() }
        }
        NSApp.activate(ignoringOtherApps: true)
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
        if highlightSetup { settings?.highlightSetup() }
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
