import AppKit
import Combine
import ServiceManagement
import UniformTypeIdentifiers
import BusyBlockCore

/// Settings window. Everything saves as you change it (no Save button) and
/// every status line follows the controller live. AppKit only: SwiftUI macros
/// don't build with Command Line Tools.
@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    private let store: ConfigStore
    private let controller: BlockController
    private var cancellables = Set<AnyCancellable>()
    private var loading = false

    // Status card
    private let statusDot = DotView()
    private let spinner = NSProgressIndicator()
    private var root: NSStackView!
    private var scroll: NSScrollView!
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(labelWithString: "")

    // Bar
    private let devicePanel = DevicePanelView()
    private let advancedToggle = NSButton()
    private let advancedBox = NSStackView()
    private let connIcon = NSImageView()
    private let connLabel = NSTextField(labelWithString: "")
    private var advancedManual: Bool?   // nil = follow the connection state
    private let hostField = NSTextField()
    private let tokenField = NSTextField()
    private let discoverCheck = NSButton(checkboxWithTitle: "Find the BUSY Bar automatically (USB, busybar.local, Bonjour)", target: nil, action: nil)
    private let restCheck = NSButton(checkboxWithTitle: "Keep blocking during rest phases", target: nil, action: nil)
    private let screenCheck = NSButton(checkboxWithTitle: "Show the bar's screen in the browser", target: nil, action: nil)
    private let timerCheck = NSButton(checkboxWithTitle: "Show the countdown in the menu bar (the BUSY app shows it too)", target: nil, action: nil)
    private let loginCheck = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let menuIconCheck = NSButton(checkboxWithTitle: "Show icon in the menu bar", target: nil, action: nil)
    private let dockIconCheck = NSButton(checkboxWithTitle: "Show icon in the Dock", target: nil, action: nil)

    // Apps
    private let appChips = FlowView()
    private let dropZone = DropZoneView()
    private var dropZoneWidth: NSLayoutConstraint!
    private var appChipsWidth: NSLayoutConstraint!
    private let appPills = FlowView()
    private var apps: [String] = []

    // Domains
    private let chips = FlowView()
    private let domainField = NSTextField()
    private var domains: [String] = []
    private let pills = FlowView()
    private var pillsHint = NSTextField(labelWithString: "")
    private var appPillsHint = NSTextField(labelWithString: "")

    private let saveDebounce = PassthroughSubject<Void, Never>()

    init(store: ConfigStore, controller: BlockController) {
        self.store = store
        self.controller = controller
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "BusyBlock"
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        super.init(window: w)
        let container = DropContainerView()
        container.zone = dropZone
        container.onDrop = { [weak self] urls in self?.addApps(urls) }
        // Content scrolls inside the window when it would not fit on screen.
        let content = buildContent()
        content.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = content
        self.scroll = scroll
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor), scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        container.installOverlay()
        w.contentView = container
        w.center()

        controller.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshStatus() }.store(in: &cancellables)
        controller.$activeHost.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshStatus() }.store(in: &cancellables)
        controller.$needsToken.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshStatus() }.store(in: &cancellables)
        controller.$lastError.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshStatus() }.store(in: &cancellables)
        controller.$discovering.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshStatus() }.store(in: &cancellables)
        controller.$searchFailed.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshStatus() }.store(in: &cancellables)
        LiveFrames.shared.$frame.receive(on: DispatchQueue.main).sink { [weak self] f in self?.devicePanel.frame72 = f }.store(in: &cancellables)
        store.$config.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.load() }.store(in: &cancellables)
        saveDebounce.debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.commit() }.store(in: &cancellables)
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStatus() }
        }
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        load()
        super.showWindow(sender)
        fitWindow()
    }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let root = NSStackView()
        self.root = root
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        // Status card and the bar preview side by side, as two separate things.
        let topRow = NSStackView(views: [devicePanel, statusCard()])
        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.spacing = 14
        root.addArrangedSubview(topRow)
        // Host and token only matter when discovery failed or the bar wants a
        // token; they unfold on their own in those cases.
        advancedToggle.bezelStyle = .inline
        advancedToggle.isBordered = false
        advancedToggle.target = self
        advancedToggle.action = #selector(toggleAdvanced)
        advancedToggle.font = .systemFont(ofSize: 12)
        advancedToggle.alignment = .left
        advancedToggle.contentTintColor = .secondaryLabelColor
        // Same row: how we're connected (USB or Wi-Fi) and to what.
        connIcon.contentTintColor = .secondaryLabelColor
        connIcon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        connLabel.font = .systemFont(ofSize: 12)
        connLabel.textColor = .secondaryLabelColor
        let connRow = NSStackView(views: [advancedToggle, connIcon, connLabel])
        connRow.orientation = .horizontal
        connRow.alignment = .centerY
        connRow.spacing = 6
        advancedToggle.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        root.addArrangedSubview(connRow)
        advancedBox.orientation = .vertical
        advancedBox.alignment = .leading
        advancedBox.spacing = 8
        hostField.placeholderString = "10.0.4.20 over USB, an IP over Wi-Fi, or 127.0.0.1:8321 for busybar-manager"
        hostField.delegate = self
        advancedBox.addArrangedSubview(row("Host", hostField))
        tokenField.placeholderString = "only if access protection is on in the bar's settings"
        tokenField.delegate = self
        advancedBox.addArrangedSubview(row("API token", tokenField))
        root.addArrangedSubview(advancedBox)

        root.addArrangedSubview(header("BUSY Bar"))
        for check in [discoverCheck, restCheck, screenCheck, menuIconCheck, dockIconCheck, timerCheck] {
            check.target = self
            check.action = #selector(toggled)
            root.addArrangedSubview(check)
        }
        loginCheck.target = self
        loginCheck.action = #selector(toggleLogin)
        root.addArrangedSubview(loginCheck)

        appsCallout = callout("Start here: drop the apps you want hidden, or pick from the suggestions")
        root.addArrangedSubview(appsCallout)
        root.addArrangedSubview(header("Apps to hide while the bar is busy"))
        appChips.spacing = 8
        dropZone.onClick = { [weak self] in self?.pickApp() }
        dropZone.translatesAutoresizingMaskIntoConstraints = false
        dropZoneWidth = dropZone.widthAnchor.constraint(equalToConstant: 100)
        dropZoneWidth.isActive = true
        dropZone.heightAnchor.constraint(equalToConstant: 100).isActive = true
        appChips.translatesAutoresizingMaskIntoConstraints = false
        appChipsWidth = appChips.widthAnchor.constraint(equalToConstant: 592 - 100 - 12)
        appChipsWidth.isActive = true
        let appsRow = NSStackView(views: [appChips, dropZone])
        appsRow.orientation = .horizontal
        appsRow.alignment = .top
        appsRow.spacing = 12
        root.addArrangedSubview(appsRow)
        appPillsHint = NSTextField(labelWithString: "Installed apps people usually hide, one click to add:")
        appPillsHint.textColor = .secondaryLabelColor
        appPillsHint.font = .systemFont(ofSize: 11)
        root.addArrangedSubview(appPillsHint)
        appPills.spacing = 6
        root.addArrangedSubview(appPills)

        sitesCallout = callout("…and the websites to block")
        root.addArrangedSubview(sitesCallout)
        root.addArrangedSubview(header("Websites to block"))
        chips.spacing = 8
        root.addArrangedSubview(chips)
        domainField.placeholderString = "youtube.com, reddit.com/r/all, …  press Return to add"
        domainField.delegate = self
        domainField.target = self
        domainField.action = #selector(addDomain)
        let addBtn = NSButton(title: "Add", target: self, action: #selector(addDomain))
        let domainRow = NSStackView(views: [domainField, addBtn])
        domainRow.orientation = .horizontal
        root.addArrangedSubview(domainRow)
        pillsHint = NSTextField(labelWithString: "Usual suspects, one click to add:")
        pillsHint.textColor = .secondaryLabelColor
        pillsHint.font = .systemFont(ofSize: 11)
        root.addArrangedSubview(pillsHint)
        root.addArrangedSubview(pills)

        // Footer: the tour again, and a way to say thanks.
        let replay = NSButton(title: "Show the welcome tour again", target: self, action: #selector(replayOnboarding))
        replay.isBordered = false
        replay.font = .systemFont(ofSize: 11)
        replay.contentTintColor = .secondaryLabelColor
        let coffee = NSButton(title: "Buy me a coffee", target: self, action: #selector(openSupport))
        coffee.bezelStyle = .rounded
        coffee.controlSize = .small
        coffee.font = .systemFont(ofSize: 11)
        coffee.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)
        coffee.imagePosition = .imageLeading
        coffee.toolTip = "BusyBlock is free. If it keeps you off the internet, buy me a coffee."
        let gap = NSView()
        gap.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [replay, gap, coffee])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
        root.addArrangedSubview(footer)

        for v in root.arrangedSubviews {
            root.widthAnchor.constraint(equalTo: v.widthAnchor, constant: 48).isActive = true
        }
        root.widthAnchor.constraint(equalToConstant: 640).isActive = true
        return root
    }

    private func statusCard() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        statusTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        statusTitle.lineBreakMode = .byWordWrapping
        statusTitle.maximumNumberOfLines = 2
        statusDetail.font = .systemFont(ofSize: 12)
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.lineBreakMode = .byWordWrapping
        statusDetail.maximumNumberOfLines = 3
        statusDetail.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        statusTitle.setContentCompressionResistancePriority(.init(2), for: .horizontal)
        statusTitle.preferredMaxLayoutWidth = 592 - 240 - 14 - 16 - 16 - 12 - 14
        statusDetail.preferredMaxLayoutWidth = 592 - 240 - 14 - 16 - 16 - 12 - 14
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        let text = NSStackView(views: [statusTitle, statusDetail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        // Small live preview of the bar, like busybar-manager's, only smaller; sits next to the card.
        devicePanel.translatesAutoresizingMaskIntoConstraints = false
        devicePanel.widthAnchor.constraint(equalToConstant: 240).isActive = true
        devicePanel.heightAnchor.constraint(equalToConstant: 240 * 248 / 768).isActive = true
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Dot and spinner share one 16×16 slot; only one of them shows at a time.
        let lead = NSView()
        lead.translatesAutoresizingMaskIntoConstraints = false
        lead.widthAnchor.constraint(equalToConstant: 16).isActive = true
        lead.heightAnchor.constraint(equalToConstant: 16).isActive = true
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        lead.addSubview(statusDot)
        lead.addSubview(spinner)
        NSLayoutConstraint.activate([
            statusDot.centerXAnchor.constraint(equalTo: lead.centerXAnchor), statusDot.centerYAnchor.constraint(equalTo: lead.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: lead.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: lead.centerYAnchor),
        ])
        let h = NSStackView(views: [lead, text])
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 12
        h.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 14)
        h.translatesAutoresizingMaskIntoConstraints = false
        card.translatesAutoresizingMaskIntoConstraints = false
        card.widthAnchor.constraint(equalToConstant: 592 - 240 - 14).isActive = true
        card.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: card.leadingAnchor), h.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            h.topAnchor.constraint(equalTo: card.topAnchor), h.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 14), statusDot.heightAnchor.constraint(equalToConstant: 14),
        ])
        return card
    }

    private var appsCallout = NSView()
    private var sitesCallout = NSView()

    /// Accent bubble shown above a section right after onboarding.
    private func callout(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .medium)
        l.textColor = .white
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        box.layer?.cornerRadius = 8
        l.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(l)
        NSLayoutConstraint.activate([l.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10), l.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
                                     l.topAnchor.constraint(equalTo: box.topAnchor, constant: 6), l.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6)])
        box.isHidden = true
        return box
    }

    func highlightSetup() {
        for v in [appsCallout, sitesCallout] { v.isHidden = false; v.alphaValue = 1 }
        fitWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.6; self.appsCallout.animator().alphaValue = 0; self.sitesCallout.animator().alphaValue = 0 },
                                                completionHandler: { [weak self] in self?.appsCallout.isHidden = true; self?.sitesCallout.isHidden = true; self?.fitWindow() })
        }
    }

    private func header(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: text.uppercased())
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func row(_ label: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.textColor = .secondaryLabelColor
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let s = NSStackView(views: [l, control])
        s.orientation = .horizontal
        s.spacing = 10
        control.translatesAutoresizingMaskIntoConstraints = false
        control.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        return s
    }

    private func indent(_ v: NSView) -> NSView {
        let s = NSStackView(views: [v])
        s.edgeInsets = NSEdgeInsets(top: 0, left: 90, bottom: 0, right: 0)
        return s
    }

    // MARK: - Data

    private func load() {
        loading = true
        defer { loading = false }
        let c = store.config
        if hostField.stringValue != c.barHost, hostField.currentEditor() == nil { hostField.stringValue = c.barHost }
        if tokenField.currentEditor() == nil { tokenField.stringValue = c.barToken ?? "" }
        discoverCheck.state = c.autoDiscover ? .on : .off
        restCheck.state = c.blockDuringRest ? .on : .off
        screenCheck.state = c.showScreenInBrowser ? .on : .off
        timerCheck.state = c.showTimerInMenuBar ? .on : .off
        menuIconCheck.state = c.showMenuBarIcon ? .on : .off
        dockIconCheck.state = c.showDockIcon ? .on : .off
        timerCheck.isEnabled = c.showMenuBarIcon
        if #available(macOS 13, *) {
            loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
            loginCheck.isEnabled = Bundle.main.bundleURL.pathExtension == "app"
        }
        apps = c.blockedApps
        rebuildAppChips()
        rebuildAppPills()
        if domains != c.blockedDomains { domains = c.blockedDomains; rebuildChips() }
        rebuildPills()
        refreshStatus()
    }

    /// Push the UI into the store (debounced; the store writes the file).
    private func commit() {
        guard !loading else { return }
        var c = store.config
        c.barHost = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        c.barToken = tokenField.stringValue.isEmpty ? nil : tokenField.stringValue
        c.autoDiscover = discoverCheck.state == .on
        c.blockDuringRest = restCheck.state == .on
        c.showScreenInBrowser = screenCheck.state == .on
        c.showTimerInMenuBar = timerCheck.state == .on
        c.showMenuBarIcon = menuIconCheck.state == .on
        c.showDockIcon = dockIconCheck.state == .on
        c.blockedApps = apps
        c.blockedDomains = domains
        store.save(c)
    }

    /// The window takes the height of its content; a fixed height would make
    /// the stack pad the slack into some row.
    /// Window height follows the content, capped so it always fits on the screen
    /// (below the menu bar, above the Dock); beyond that the content scrolls.
    private func fitWindow() {
        guard let w = window, let root else { return }
        root.layoutSubtreeIfNeeded()
        let wanted = root.fittingSize.height
        let screen = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let titleBar = w.frame.height - w.contentRect(forFrameRect: w.frame).height
        let maxContent = screen.height - titleBar - 24
        let h = min(wanted, maxContent)
        var f = w.frame
        let delta = h - w.contentRect(forFrameRect: f).height
        f.origin.y -= delta
        f.size.height += delta
        if f.maxY > screen.maxY { f.origin.y = screen.maxY - f.height }
        if f.minY < screen.minY { f.origin.y = screen.minY }
        w.setFrame(f, display: true, animate: false)
    }

    private var advancedShown: Bool { !advancedBox.isHidden }

    private func setAdvanced(_ shown: Bool) {
        advancedBox.isHidden = !shown
        advancedToggle.title = (shown ? "▾ " : "▸ ") + "Bar connection (host, API token)"
    }

    @objc private func toggleAdvanced() {
        advancedManual = !advancedShown
        setAdvanced(!advancedShown)
    }

    private func refreshStatus() {
        let s = controller.state
        let wanted = advancedManual ?? ((!s.barConnected && controller.searchFailed && !controller.discovering) || controller.needsToken)
        if wanted != advancedShown { setAdvanced(wanted); fitWindow() }
        devicePanel.dimmed = !s.barConnected
        let host = controller.activeHost
        let via: String
        switch controller.foundVia {
        case .configured: via = ""
        case .usb: via = " · found on USB"
        case .mdns: via = " · found via mDNS"
        case .bonjour: via = " · found via Bonjour"
        }
        let searching = !s.barConnected && !controller.searchFailed && (controller.discovering || store.config.autoDiscover)
        if searching { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        statusDot.isHidden = searching
        if controller.needsToken {
            statusDot.color = .systemOrange
            statusTitle.stringValue = "The bar wants an API token"
            statusDetail.stringValue = "\(host)\(via) · create one in the bar's settings and paste it below"
        } else if searching {
            statusTitle.stringValue = "Looking for the BUSY Bar…"
            statusDetail.stringValue = "USB, busybar.local, Bonjour"
        } else if !s.barConnected {
            statusDot.color = .systemGray
            statusTitle.stringValue = "BUSY Bar not found"
            statusDetail.stringValue = store.config.autoDiscover
                ? "Not on USB, busybar.local or Bonjour; still checking every 20 s. Plug it in, or enter its address below."
                : "\(host)" + (controller.lastError.map { " · \($0.prefix(60))" } ?? "")
        } else if s.isBlocking {
            statusDot.color = .systemRed
            let left = s.endsAt.map { Self.remaining($0) } ?? ""
            statusTitle.stringValue = "Blocking · " + (left.isEmpty ? "no time limit" : "\(left) left")
            statusDetail.stringValue = "\(apps.count) apps, \(domains.count) websites"
        } else {
            statusDot.color = .systemGreen
            statusTitle.stringValue = s.paused ? "Paused" : s.phase == "rest" ? "Rest phase" : "Idle · start the bar to block"
            statusDetail.stringValue = "\(apps.count) apps, \(domains.count) websites ready"
        }
        // Connection row: USB is the bar's fixed USB address, anything else is Wi-Fi.
        if s.barConnected {
            let usb = host == BarLocator.usbHost
            connIcon.image = NSImage(systemSymbolName: usb ? "cable.connector" : "wifi", accessibilityDescription: usb ? "USB" : "Wi-Fi")
            connIcon.isHidden = false
            connLabel.stringValue = (usb ? "USB" : "Wi-Fi · \(host)") + (controller.foundVia == .configured ? "" : " · found automatically")
        } else {
            connIcon.isHidden = true
            connLabel.stringValue = searching ? "searching…" : "not connected"
        }
    }

    private static func remaining(_ end: Date) -> String {
        let secs = max(0, Int((end.timeIntervalSinceNow - 0.05).rounded(.up)))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    // MARK: - Actions

    @objc private func toggled() { saveDebounce.send() }

    var onReplayOnboarding: (() -> Void)?
    @objc private func replayOnboarding() { onReplayOnboarding?() }

    @objc private func openSupport() { NSWorkspace.shared.open(Support.page) }

    @objc private func toggleLogin() {
        guard #available(macOS 13, *) else { return }
        do {
            if loginCheck.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
            let alert = NSAlert(); alert.messageText = "Launch at Login failed"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if let f = obj.object as? NSTextField, f === hostField || f === tokenField { saveDebounce.send() }
    }

    @objc private func pickApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose apps to hide while the bar is busy"
        guard panel.runModal() == .OK else { return }
        addApps(panel.urls)
    }

    private func addApps(_ urls: [URL]) {
        var added = false
        for url in urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !apps.contains(id) { apps.append(id); added = true }
        }
        guard added else { return }
        rebuildAppChips()
        rebuildAppPills()
        saveDebounce.send()
    }

    private func rebuildChips() {
        chips.subviews.forEach { $0.removeFromSuperview() }
        for d in domains {
            let chip = ChipView(title: d)
            chip.onRemove = { [weak self] in
                guard let self, let i = self.domains.firstIndex(of: d) else { return }
                self.domains.remove(at: i)
                self.rebuildChips(); self.rebuildPills(); self.saveDebounce.send()
            }
            FaviconLoader.shared.image(for: d) { [weak chip] img in
                if let img { chip?.icon.image = img; chip?.icon.contentTintColor = nil }
            }
            chips.addSubview(chip)
        }
        chips.needsLayout = true
        DispatchQueue.main.async { [weak self] in self?.fitWindow() }
    }

    private func rebuildAppChips() {
        appChips.subviews.forEach { $0.removeFromSuperview() }
        let ws = NSWorkspace.shared
        for id in apps {
            let url = ws.urlForApplication(withBundleIdentifier: id)
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? id
            let chip = ChipView(title: name, large: true)
            chip.toolTip = url == nil ? "\(id) (not installed)" : id
            if let url {
                chip.icon.image = ws.icon(forFile: url.path)
                chip.icon.contentTintColor = nil
            } else {
                chip.icon.image = NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: nil)
            }
            chip.onRemove = { [weak self] in
                guard let self, let i = self.apps.firstIndex(of: id) else { return }
                self.apps.remove(at: i)
                self.rebuildAppChips(); self.rebuildAppPills(); self.saveDebounce.send()
            }
            appChips.addSubview(chip)
        }
        // No apps yet: the drop zone takes the whole row.
        let empty = apps.isEmpty
        appChips.isHidden = empty
        appChipsWidth.constant = empty ? 0 : 592 - 100 - 12
        dropZoneWidth.constant = empty ? 592 : 100
        dropZone.wide = empty
        appChips.needsLayout = true
        DispatchQueue.main.async { [weak self] in self?.fitWindow() }
    }

    private func rebuildAppPills() {
        appPills.subviews.forEach { $0.removeFromSuperview() }
        let ws = NSWorkspace.shared
        for app in Suggestions.remainingApps(given: apps, installed: { ws.urlForApplication(withBundleIdentifier: $0) != nil }) {
            let b = NSButton(title: app.name, target: self, action: #selector(appPillTapped(_:)))
            b.bezelStyle = .badge
            b.controlSize = .regular
            b.font = .systemFont(ofSize: 12)
            if let url = ws.urlForApplication(withBundleIdentifier: app.id) {
                let icon = ws.icon(forFile: url.path)
                icon.size = NSSize(width: 18, height: 18)
                b.image = icon
                b.imagePosition = .imageLeading
            }
            b.identifier = .init(app.id)
            b.toolTip = "Hide \(app.name) while the bar is busy"
            appPills.addSubview(b)
        }
        let empty = appPills.subviews.isEmpty
        appPills.isHidden = empty
        appPillsHint.isHidden = empty
        appPills.needsLayout = true
        DispatchQueue.main.async { [weak self] in self?.fitWindow() }
    }

    @objc private func appPillTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, !apps.contains(id) else { return }
        apps.append(id)
        rebuildAppChips()
        rebuildAppPills()
        saveDebounce.send()
    }

    private func rebuildPills() {
        pills.subviews.forEach { $0.removeFromSuperview() }
        for d in Suggestions.remaining(given: domains) {
            let b = NSButton(title: d, target: self, action: #selector(pillTapped(_:)))
            b.bezelStyle = .badge
            b.controlSize = .small
            b.font = .systemFont(ofSize: 11)
            b.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            b.imagePosition = .imageLeading
            b.toolTip = "Block \(d) while the bar is busy"
            pills.addSubview(b)
        }
        let empty = pills.subviews.isEmpty
        pills.isHidden = empty
        pillsHint.isHidden = empty
        pills.needsLayout = true
        DispatchQueue.main.async { [weak self] in self?.fitWindow() }
    }

    @objc private func pillTapped(_ sender: NSButton) {
        let d = Domain.normalize(sender.title)
        guard !d.isEmpty, !domains.contains(d) else { return }
        domains.append(d)
        domains.sort()
        rebuildChips()
        rebuildPills()
        saveDebounce.send()
    }

    @objc private func addDomain() {
        let d = Domain.normalize(domainField.stringValue)
        guard !d.isEmpty else { NSSound.beep(); return }
        domainField.stringValue = ""
        guard !domains.contains(d) else { return }
        domains.append(d)
        domains.sort()
        rebuildChips()
        rebuildPills()
        saveDebounce.send()
    }

}

// MARK: - Views

/// Small dashed square: click to pick apps. Drags are handled by the window's
/// DropContainerView, which grows this look over the whole window.
final class DropZoneView: NSView {
    var onClick: (() -> Void)?
    var active = false { didSet { needsDisplay = true } }
    var wide = false { didSet { label.stringValue = wide ? "Drop apps here from Finder, or click to choose" : "Drop apps\nor click"; stack.orientation = wide ? .horizontal : .vertical } }
    private let label = NSTextField(wrappingLabelWithString: "Drop apps\nor click")
    private let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let icon = NSImageView(image: NSImage(systemSymbolName: "square.and.arrow.down.on.square", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 20, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        let s = stack
        s.addArrangedSubview(icon)
        s.addArrangedSubview(label)
        s.orientation = .vertical
        s.alignment = .centerX
        s.spacing = 8
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([s.centerXAnchor.constraint(equalTo: centerXAnchor), s.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     s.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -8)])
    }

    required init?(coder: NSCoder) { fatalError() }

    static func appURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier != nil }
    }

    override func draw(_ dirtyRect: NSRect) {
        DropContainerView.drawDashed(in: bounds, active: active)
        label.textColor = active ? .controlAccentColor : .secondaryLabelColor
    }

    override func mouseUp(with event: NSEvent) { onClick?() }
}

/// Window content view. When apps are dragged anywhere over the window, the
/// small drop square grows into a full-window target with an animation and
/// shrinks back when the drag leaves or ends.
final class DropContainerView: NSView {
    weak var zone: DropZoneView?
    var onDrop: (([URL]) -> Void)?
    private let overlay = DropOverlayView()

    static func drawDashed(in rect: NSRect, active: Bool) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        (active ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.quaternaryLabelColor.withAlphaComponent(0.05)).setFill()
        path.fill()
        path.lineWidth = active ? 2 : 1
        path.setLineDash([6, 4], count: 2, phase: 0)
        (active ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.stroke()
    }

    func installOverlay() {
        registerForDraggedTypes([.fileURL])
        overlay.isHidden = true
        overlay.wantsLayer = true
        addSubview(overlay, positioned: .above, relativeTo: nil)
    }

    private var zoneFrame: NSRect {
        guard let zone else { return NSRect(x: bounds.midX - 50, y: bounds.midY - 50, width: 100, height: 100) }
        return zone.convert(zone.bounds, to: self)
    }

    private func grow() {
        overlay.frame = zoneFrame
        overlay.isHidden = false
        zone?.active = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.11
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            overlay.animator().frame = bounds.insetBy(dx: 14, dy: 14)
        }
    }

    private func shrink() {
        zone?.active = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.09
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            overlay.animator().frame = zoneFrame
        }, completionHandler: { [weak self] in self?.overlay.isHidden = true })
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !DropZoneView.appURLs(sender).isEmpty else { return [] }
        grow()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { shrink() }
    override func draggingEnded(_ sender: NSDraggingInfo) { if !overlay.isHidden { shrink() } }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = DropZoneView.appURLs(sender)
        shrink()
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

/// The grown drop target drawn over the whole window.
final class DropOverlayView: NSView {
    private let label = NSTextField(labelWithString: "Drop to hide these apps while the bar is busy")
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .controlAccentColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([label.centerXAnchor.constraint(equalTo: centerXAnchor), label.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        bounds.fill()
        DropContainerView.drawDashed(in: bounds, active: true)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never steal clicks
}

/// A blocked website: favicon, domain, remove button, in a rounded pill.
final class ChipView: NSView {
    let icon = NSImageView()
    var onRemove: (() -> Void)?

    init(title: String, large: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = large ? 18 : 15
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        icon.contentTintColor = .secondaryLabelColor
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let iconSize: CGFloat = large ? 22 : 16
        icon.widthAnchor.constraint(equalToConstant: iconSize).isActive = true
        icon.heightAnchor.constraint(equalToConstant: iconSize).isActive = true
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: large ? 14 : 13)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        let remove = NSButton()
        remove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove \(title)")
        remove.isBordered = false
        remove.contentTintColor = .tertiaryLabelColor
        remove.target = self
        remove.action = #selector(removeTapped)
        remove.toolTip = "Remove \(title)"
        let h = NSStackView(views: [icon, label, remove])
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 7
        h.edgeInsets = large ? NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 8) : NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 6)
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: leadingAnchor), h.trailingAnchor.constraint(equalTo: trailingAnchor),
            h.topAnchor.constraint(equalTo: topAnchor), h.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func removeTapped() { onRemove?() }
}

/// Wraps its subviews into rows, like tags. Height follows content.
final class FlowView: NSView {
    var spacing: CGFloat = 6
    private var heightConstraint: NSLayoutConstraint?

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        let width = bounds.width
        for v in subviews {
            let sz = v.fittingSize
            if x + sz.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            v.frame = NSRect(x: x, y: y, width: sz.width, height: sz.height)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        let total = subviews.isEmpty ? 0 : y + rowH
        if heightConstraint == nil {
            heightConstraint = heightAnchor.constraint(equalToConstant: total)
            heightConstraint?.isActive = true
        } else if heightConstraint?.constant != total {
            heightConstraint?.constant = total
        }
    }

    override func didAddSubview(_ subview: NSView) { needsLayout = true }
}

/// Coloured status dot.
final class DotView: NSView {
    var color: NSColor = .systemGray { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.25).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 3, dy: 3)).fill()
    }
}
