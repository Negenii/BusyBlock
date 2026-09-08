import AppKit
import Combine
import ServiceManagement
import UniformTypeIdentifiers
import BusyBlockCore

/// Settings window in the System Settings style: a sidebar of sections on
/// the left (small coloured icon tiles), the chosen section on the right as
/// grouped forms. Everything saves as you change it and every status line
/// follows the controller live. AppKit only: SwiftUI macros don't build with
/// Command Line Tools.
@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
    enum Section: String, CaseIterable {
        case general, apps, websites, bar
        var title: String {
            switch self {
            case .general: return "General"
            case .apps: return "Apps"
            case .websites: return "Websites"
            case .bar: return "BUSY Bar"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape.fill"
            case .apps: return "eye.slash.fill"
            case .websites: return "globe"
            case .bar: return "timer"
            }
        }
        var tint: NSColor {
            switch self {
            case .general: return NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.60, alpha: 1)
            case .apps: return NSColor(calibratedRed: 0.55, green: 0.45, blue: 0.95, alpha: 1)
            case .websites: return .systemBlue
            case .bar: return NSColor(calibratedRed: 0.93, green: 0.30, blue: 0.25, alpha: 1)
            }
        }
    }

    private let store: ConfigStore
    private let controller: BlockController
    private var cancellables = Set<AnyCancellable>()
    private var loading = false
    private let split = NSSplitViewController()

    // Sidebar
    private var sidebarRows: [Section: SidebarRowView] = [:]
    private let footerDot = DotView()
    private let footerText = NSTextField(labelWithString: "")

    // Detail
    private let headerTile = IconTileView(size: 24)
    private let headerTitle = NSTextField(labelWithString: "")
    private let detailScroll = NSScrollView()
    private var sections: [Section: NSView] = [:]
    private var docWidth: NSLayoutConstraint?
    private(set) var selected: Section = .general

    // BUSY Bar section
    private let statusDot = DotView()
    private let spinner = NSProgressIndicator()
    private let statusTitle = NSTextField(wrappingLabelWithString: "")
    private let statusDetail = NSTextField(wrappingLabelWithString: "")
    private let devicePanel = DevicePanelView()
    private let connIcon = NSImageView()
    private let connLabel = NSTextField(wrappingLabelWithString: "")
    private let hostField = NSTextField()
    private let tokenField = NSSecureTextField()
    private let discoverSwitch = NSSwitch()
    private let restSwitch = NSSwitch()
    private let screenSwitch = NSSwitch()

    // General section
    private let loginSwitch = NSSwitch()
    private let menuIconSwitch = NSSwitch()
    private let dockIconSwitch = NSSwitch()
    private let timerSwitch = NSSwitch()
    private var timerRow: NSView!
    private let iconsFooter = NSTextField(wrappingLabelWithString: "")

    // Apps section
    private let appChips = FlowView()
    private let dropZone = DropZoneView()
    private var dropNarrow: NSLayoutConstraint!
    private var dropWide: NSLayoutConstraint!
    private var chipsToZone: NSLayoutConstraint!
    private let appPills = FlowView()
    private var appPillsGroup: NSView!
    private var apps: [String] = []
    private var appsCallout = NSView()

    // Websites section
    private let chips = FlowView()
    private let chipsEmpty = NSTextField(labelWithString: "Nothing yet. Add a site below, or pick one of the usual suspects.")
    private let domainField = NSTextField()
    private var domains: [String] = []
    private var chipsBuilt = false
    private let pills = FlowView()
    private var pillsGroup: NSView!
    private var sitesCallout = NSView()

    private let saveDebounce = PassthroughSubject<Void, Never>()
    var onReplayOnboarding: (() -> Void)?

    init(store: ConfigStore, controller: BlockController) {
        self.store = store
        self.controller = controller
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 580),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "BusyBlock"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        super.init(window: w)

        let sidebarVC = PlainViewController(view: buildSidebar())
        let detailVC = PlainViewController(view: buildDetail())
        let side = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        side.minimumThickness = 200
        side.maximumThickness = 200
        side.canCollapse = false
        if #available(macOS 11, *) { side.allowsFullHeightLayout = true }
        split.addSplitViewItem(side)
        split.addSplitViewItem(NSSplitViewItem(viewController: detailVC))
        split.splitView.dividerStyle = .thin

        // The whole window is a drop target for apps: the small square in the
        // Apps section grows over the window while something is dragged.
        let container = DropContainerView()
        container.zone = dropZone
        container.onDrop = { [weak self] urls in self?.addApps(urls); self?.select(.apps) }
        let sv = split.view
        sv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(sv)
        NSLayoutConstraint.activate([
            sv.leadingAnchor.constraint(equalTo: container.leadingAnchor), sv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sv.topAnchor.constraint(equalTo: container.topAnchor), sv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.installOverlay()
        w.contentView = container
        w.center()

        for s in Section.allCases { sections[s] = buildSection(s) }
        let remembered = UserDefaults.standard.string(forKey: "settingsSection").flatMap(Section.init(rawValue:)) ?? .general
        select(remembered)

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
        // Something the bar needs from you? Open on that page.
        let s = controller.state
        if controller.needsToken || (!s.barConnected && controller.searchFailed && !controller.discovering) { select(.bar) }
        super.showWindow(sender)
    }

    // MARK: - Sidebar

    private func buildSidebar() -> NSView {
        let v = NSView()
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .width
        list.spacing = 2
        list.translatesAutoresizingMaskIntoConstraints = false
        func header(_ t: String) -> NSView {
            let l = NSTextField(labelWithString: t)
            l.font = .systemFont(ofSize: 11, weight: .semibold)
            l.textColor = .tertiaryLabelColor
            let box = NSStackView(views: [l])
            box.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 2, right: 0)
            return box
        }
        func row(_ s: Section) -> NSView {
            let r = SidebarRowView(section: s)
            r.onSelect = { [weak self] in self?.select(s) }
            sidebarRows[s] = r
            return r
        }
        list.addArrangedSubview(row(.general))
        list.addArrangedSubview(header("Blocking"))
        list.addArrangedSubview(row(.apps))
        list.addArrangedSubview(row(.websites))
        list.addArrangedSubview(header("Device"))
        list.addArrangedSubview(row(.bar))
        v.addSubview(list)

        // Bar status, always in view whichever section is open.
        footerText.font = .systemFont(ofSize: 12)
        footerText.textColor = .secondaryLabelColor
        footerText.lineBreakMode = .byTruncatingTail
        footerDot.translatesAutoresizingMaskIntoConstraints = false
        footerDot.widthAnchor.constraint(equalToConstant: 10).isActive = true
        footerDot.heightAnchor.constraint(equalToConstant: 10).isActive = true
        let footer = NSStackView(views: [footerDot, footerText])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 7
        footer.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(footer)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: v.topAnchor, constant: 52),
            list.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            list.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -16),
        ])
        return v
    }

    private func select(_ s: Section) {
        selected = s
        UserDefaults.standard.set(s.rawValue, forKey: "settingsSection")
        for (k, r) in sidebarRows { r.selected = k == s }
        headerTile.symbol = s.symbol
        headerTile.tint = s.tint
        headerTitle.stringValue = s.title
        guard let doc = sections[s] else { return }
        docWidth?.isActive = false
        detailScroll.documentView = doc
        docWidth = doc.widthAnchor.constraint(equalTo: detailScroll.contentView.widthAnchor)
        docWidth?.isActive = true
        doc.topAnchor.constraint(equalTo: detailScroll.contentView.topAnchor).isActive = true
        doc.leadingAnchor.constraint(equalTo: detailScroll.contentView.leadingAnchor).isActive = true
        doc.needsLayout = true
        detailScroll.contentView.scroll(to: .zero)
    }

    // MARK: - Detail

    private func buildDetail() -> NSView {
        let v = NSView()
        headerTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        let header = NSStackView(views: [headerTile, headerTitle])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 9
        header.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(header)
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.hasVerticalScroller = true
        detailScroll.autohidesScrollers = true
        detailScroll.drawsBackground = false
        v.addSubview(detailScroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: v.topAnchor, constant: 36),
            header.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 26),
            detailScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            detailScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            detailScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            detailScroll.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        return v
    }

    private func buildSection(_ s: Section) -> NSView {
        let stack = FlippedStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for g in groups(for: s) {
            stack.addArrangedSubview(g)
            g.translatesAutoresizingMaskIntoConstraints = false
            g.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        return stack
    }

    private func groups(for s: Section) -> [NSView] {
        switch s {
        case .general:
            loginSwitch.target = self; loginSwitch.action = #selector(toggleLogin)
            for sw in [menuIconSwitch, dockIconSwitch, timerSwitch] { sw.target = self; sw.action = #selector(toggled) }
            timerRow = Form.toggle("Countdown next to the menu-bar icon", subtitle: "The BUSY app shows it too, so this is off by default.", timerSwitch)
            let replay = NSButton(title: "Show Again", target: self, action: #selector(replayOnboarding))
            replay.bezelStyle = .rounded
            iconsFooter.font = .systemFont(ofSize: 11)
            iconsFooter.textColor = .secondaryLabelColor
            return [
                Form.group("Startup", rows: [Form.toggle("Launch BusyBlock at login", loginSwitch)],
                           footer: "BusyBlock is a background helper: it needs to be running for the bar to block anything."),
                Form.group("Icon", rows: [Form.toggle("Show in the menu bar", menuIconSwitch),
                                          Form.toggle("Show in the Dock", dockIconSwitch), timerRow], footerView: iconsFooter),
                Form.group("Help", rows: [Form.control("Welcome tour", replay)]),
            ]
        case .apps:
            appsCallout = Form.callout("Start here: drop the apps you want hidden, or pick from the usual suspects")
            dropZone.onClick = { [weak self] in self?.pickApp() }
            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            appChips.spacing = 8
            appChips.translatesAutoresizingMaskIntoConstraints = false
            dropZone.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(appChips)
            row.addSubview(dropZone)
            dropNarrow = dropZone.widthAnchor.constraint(equalToConstant: 100)
            dropWide = dropZone.widthAnchor.constraint(equalTo: row.widthAnchor)
            chipsToZone = appChips.trailingAnchor.constraint(equalTo: dropZone.leadingAnchor, constant: -12)
            NSLayoutConstraint.activate([
                dropZone.heightAnchor.constraint(equalToConstant: 100),
                dropZone.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                dropZone.topAnchor.constraint(equalTo: row.topAnchor),
                appChips.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                appChips.topAnchor.constraint(equalTo: row.topAnchor),
                row.bottomAnchor.constraint(greaterThanOrEqualTo: appChips.bottomAnchor),
                row.bottomAnchor.constraint(greaterThanOrEqualTo: dropZone.bottomAnchor),
                dropNarrow, chipsToZone,
            ])
            appPills.spacing = 8
            appPillsGroup = Form.group("Usual suspects", rows: [Form.custom(appPills)],
                                       footer: "Installed apps people usually hide. One click adds one.")
            return [
                appsCallout,
                Form.group("Hidden while the bar is busy", rows: [Form.custom(row)],
                           footer: "Hidden, not quit: nothing is lost, and they come back when the timer ends."),
                appPillsGroup,
            ]
        case .websites:
            sitesCallout = Form.callout("…and the websites to block")
            chips.spacing = 8
            chipsEmpty.font = .systemFont(ofSize: 13)
            chipsEmpty.textColor = .secondaryLabelColor
            domainField.placeholderString = "youtube.com, reddit.com/r/all, …"
            domainField.delegate = self
            domainField.target = self
            domainField.action = #selector(addDomain)
            let add = NSButton(title: "Add", target: self, action: #selector(addDomain))
            add.bezelStyle = .rounded
            let addRow = NSStackView(views: [domainField, add])
            addRow.orientation = .horizontal
            addRow.spacing = 8
            pills.spacing = 8
            pillsGroup = Form.group("Usual suspects", rows: [Form.custom(pills)],
                                    footer: "One click adds one. Subdomains count too: blocking youtube.com covers m.youtube.com.")
            return [
                sitesCallout,
                Form.group("Blocked while the bar is busy", rows: [Form.custom(chips), Form.custom(chipsEmpty), Form.custom(addRow)],
                           footer: "The browser extension redirects these to a block page while the timer runs."),
                pillsGroup,
            ]
        case .bar:
            for sw in [discoverSwitch, restSwitch, screenSwitch] { sw.target = self; sw.action = #selector(toggled) }
            hostField.placeholderString = "10.0.4.20 over USB, an IP over Wi-Fi"
            hostField.delegate = self
            tokenField.placeholderString = "only if access protection is on"
            tokenField.delegate = self
            connIcon.contentTintColor = .secondaryLabelColor
            connIcon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
            connLabel.font = .systemFont(ofSize: 11)
            connLabel.textColor = .secondaryLabelColor
            let conn = NSStackView(views: [connIcon, connLabel])
            conn.orientation = .horizontal
            conn.alignment = .firstBaseline
            conn.spacing = 5
            return [
                Form.group("Status", rows: [Form.custom(statusHero())]),
                Form.group("Connection", rows: [
                    Form.toggle("Find the bar automatically", subtitle: "USB, then busybar.local, then Bonjour.", discoverSwitch),
                    Form.field("Address", hostField),
                    Form.field("API token", tokenField),
                ], footerView: conn),
                Form.group("Blocking", rows: [
                    Form.toggle("Keep blocking during rest phases", subtitle: "Off means apps and sites come back between intervals.", restSwitch),
                    Form.toggle("Show the bar's screen in the browser", subtitle: "Off means the extension draws its own countdown.", screenSwitch),
                ]),
            ]
        }
    }

    /// Live preview of the bar beside the status text.
    private func statusHero() -> NSView {
        statusTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        statusTitle.maximumNumberOfLines = 2
        statusDetail.font = .systemFont(ofSize: 12)
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.maximumNumberOfLines = 3
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        let text = NSStackView(views: [statusTitle, statusDetail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        devicePanel.translatesAutoresizingMaskIntoConstraints = false
        devicePanel.widthAnchor.constraint(equalToConstant: 220).isActive = true
        devicePanel.heightAnchor.constraint(equalToConstant: 220 * 248 / 768).isActive = true
        // Dot and spinner share one slot; only one shows at a time.
        let lead = NSView()
        lead.translatesAutoresizingMaskIntoConstraints = false
        lead.widthAnchor.constraint(equalToConstant: 16).isActive = true
        lead.heightAnchor.constraint(equalToConstant: 16).isActive = true
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        lead.addSubview(statusDot)
        lead.addSubview(spinner)
        NSLayoutConstraint.activate([
            statusDot.centerXAnchor.constraint(equalTo: lead.centerXAnchor), statusDot.centerYAnchor.constraint(equalTo: lead.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 14), statusDot.heightAnchor.constraint(equalToConstant: 14),
            spinner.centerXAnchor.constraint(equalTo: lead.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: lead.centerYAnchor),
        ])
        let h = NSStackView(views: [devicePanel, lead, text])
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 12
        h.setCustomSpacing(16, after: devicePanel)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return h
    }

    /// Right after onboarding: point at the two lists that still need filling.
    func highlightSetup() {
        select(.apps)
        for v in [appsCallout, sitesCallout] { v.isHidden = false; v.alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.6; self.appsCallout.animator().alphaValue = 0; self.sitesCallout.animator().alphaValue = 0 },
                                                completionHandler: { [weak self] in self?.appsCallout.isHidden = true; self?.sitesCallout.isHidden = true })
        }
    }

    // MARK: - Data

    private func load() {
        loading = true
        defer { loading = false }
        let c = store.config
        if hostField.stringValue != c.barHost, hostField.currentEditor() == nil { hostField.stringValue = c.barHost }
        if tokenField.currentEditor() == nil { tokenField.stringValue = c.barToken ?? "" }
        discoverSwitch.state = c.autoDiscover ? .on : .off
        restSwitch.state = c.blockDuringRest ? .on : .off
        screenSwitch.state = c.showScreenInBrowser ? .on : .off
        timerSwitch.state = c.showTimerInMenuBar ? .on : .off
        menuIconSwitch.state = c.showMenuBarIcon ? .on : .off
        dockIconSwitch.state = c.showDockIcon ? .on : .off
        timerSwitch.isEnabled = c.showMenuBarIcon
        iconsFooter.stringValue = (!c.showMenuBarIcon && !c.showDockIcon)
            ? "No icon at all is fine: open BusyBlock from the browser extension's popup, the Applications folder, or Spotlight."
            : "The menu-bar icon fills in while the bar is busy."
        if #available(macOS 13, *) {
            loginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
            loginSwitch.isEnabled = Bundle.main.bundleURL.pathExtension == "app"
        }
        apps = c.blockedApps
        rebuildAppChips()
        rebuildAppPills()
        if domains != c.blockedDomains || !chipsBuilt { domains = c.blockedDomains; rebuildChips() }
        rebuildPills()
        refreshStatus()
    }

    /// Push the UI into the store (debounced; the store writes the file).
    private func commit() {
        guard !loading else { return }
        var c = store.config
        c.barHost = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        c.barToken = tokenField.stringValue.isEmpty ? nil : tokenField.stringValue
        c.autoDiscover = discoverSwitch.state == .on
        c.blockDuringRest = restSwitch.state == .on
        c.showScreenInBrowser = screenSwitch.state == .on
        c.showTimerInMenuBar = timerSwitch.state == .on
        c.showMenuBarIcon = menuIconSwitch.state == .on
        c.showDockIcon = dockIconSwitch.state == .on
        c.blockedApps = apps
        c.blockedDomains = domains
        store.save(c)
    }

    private func refreshStatus() {
        let s = controller.state
        devicePanel.dimmed = !s.barConnected
        let host = controller.activeHost
        let searching = !s.barConnected && !controller.searchFailed && (controller.discovering || store.config.autoDiscover)
        if searching { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        statusDot.isHidden = searching
        var footer: String
        if controller.needsToken {
            statusDot.color = .systemOrange
            statusTitle.stringValue = "The bar wants an API token"
            statusDetail.stringValue = "\(host) · create one in the bar's settings and paste it below"
            footer = "Needs an API token"
        } else if searching {
            statusTitle.stringValue = "Looking for the BUSY Bar…"
            statusDetail.stringValue = "USB, busybar.local, Bonjour"
            statusDot.color = .systemGray
            footer = "Looking for the bar…"
        } else if !s.barConnected {
            statusDot.color = .systemGray
            statusTitle.stringValue = "BUSY Bar not found"
            statusDetail.stringValue = store.config.autoDiscover
                ? "Not on USB, busybar.local or Bonjour; still checking every 20 s. Plug it in, or enter its address below."
                : "\(host)" + (controller.lastError.map { " · \($0.prefix(60))" } ?? "")
            footer = "Bar not found"
        } else if s.isBlocking {
            statusDot.color = .systemRed
            let left = s.endsAt.map { Self.remaining($0) } ?? ""
            statusTitle.stringValue = "Blocking · " + (left.isEmpty ? "no time limit" : "\(left) left")
            statusDetail.stringValue = "\(apps.count) apps hidden, \(domains.count) websites blocked"
            footer = "Blocking" + (left.isEmpty ? "" : " · \(left)")
        } else {
            statusDot.color = .systemGreen
            statusTitle.stringValue = s.paused ? "Paused" : s.phase == "rest" ? "Rest phase" : "Idle · start the bar to block"
            statusDetail.stringValue = "\(apps.count) apps, \(domains.count) websites ready"
            footer = s.paused ? "Paused" : s.phase == "rest" ? "Rest phase" : "Idle"
        }
        footerDot.color = statusDot.color
        footerDot.isHidden = searching
        footerText.stringValue = footer
        // Connection footer: USB is the bar's fixed USB address, anything else is Wi-Fi.
        if s.barConnected {
            let usb = host == BarLocator.usbHost
            connIcon.image = NSImage(systemSymbolName: usb ? "cable.connector" : "wifi", accessibilityDescription: usb ? "USB" : "Wi-Fi")
            connIcon.isHidden = false
            connLabel.stringValue = "Connected over " + (usb ? "USB" : "Wi-Fi at \(host)") + (controller.foundVia == .configured ? "." : ", found automatically.")
        } else {
            connIcon.isHidden = true
            connLabel.stringValue = searching ? "Searching…" : "Not connected."
        }
    }

    private static func remaining(_ end: Date) -> String {
        let secs = max(0, Int((end.timeIntervalSinceNow - 0.05).rounded(.up)))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    // MARK: - Actions

    @objc private func toggled() {
        timerSwitch.isEnabled = menuIconSwitch.state == .on
        saveDebounce.send()
    }

    @objc private func replayOnboarding() { onReplayOnboarding?() }

    @objc private func toggleLogin() {
        guard #available(macOS 13, *) else { return }
        do {
            if loginSwitch.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
        chipsBuilt = true
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
        chips.superview?.isHidden = domains.isEmpty
        chipsEmpty.superview?.isHidden = !domains.isEmpty
        chips.needsLayout = true
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
        chipsToZone.isActive = !empty
        dropNarrow.isActive = !empty
        dropWide.isActive = empty
        dropZone.wide = empty
        appChips.needsLayout = true
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
        appPillsGroup.isHidden = appPills.subviews.isEmpty
        appPills.needsLayout = true
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
            b.controlSize = .regular
            b.font = .systemFont(ofSize: 12)
            b.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            b.imagePosition = .imageLeading
            b.identifier = .init(d)
            b.toolTip = "Block \(d) while the bar is busy"
            FaviconLoader.shared.image(for: d) { [weak b] img in
                guard let img, let b else { return }
                let i = img.copy() as! NSImage
                i.size = NSSize(width: 18, height: 18)
                b.image = i
            }
            pills.addSubview(b)
        }
        pillsGroup.isHidden = pills.subviews.isEmpty
        pills.needsLayout = true
    }

    @objc private func pillTapped(_ sender: NSButton) {
        let d = Domain.normalize(sender.identifier?.rawValue ?? sender.title)
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

// MARK: - Form pieces (System Settings look)

/// Builders for the grouped-form look: a title, a rounded box of rows with
/// hairlines between them, an optional footnote.
enum Form {
    static func group(_ title: String, rows: [NSView], footer: String? = nil, footerView: NSView? = nil) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        let box = FormGroupBox(rows: rows)
        let stack = NSStackView(views: [t, box])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let f: NSView?
        if let footerView { f = footerView } else if let footer {
            let l = NSTextField(wrappingLabelWithString: footer)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            f = l
        } else { f = nil }
        if let f {
            f.translatesAutoresizingMaskIntoConstraints = false
            let pad = NSStackView(views: [f])
            pad.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            stack.addArrangedSubview(pad)
            stack.setCustomSpacing(6, after: box)
            pad.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            f.widthAnchor.constraint(equalTo: pad.widthAnchor, constant: -24).isActive = true
        }
        return stack
    }

    static func toggle(_ title: String, subtitle: String? = nil, _ sw: NSSwitch) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13)
        let text = NSStackView(views: [t])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        if let subtitle {
            let s = NSTextField(wrappingLabelWithString: subtitle)
            s.font = .systemFont(ofSize: 11)
            s.textColor = .secondaryLabelColor
            text.addArrangedSubview(s)
        }
        sw.controlSize = .small
        return row([text, spacer(), sw])
    }

    static func field(_ title: String, _ field: NSTextField) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        field.controlSize = .regular
        return row([t, spacer(), field])
    }

    static func control(_ title: String, _ control: NSView) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13)
        return row([t, spacer(), control])
    }

    static func custom(_ v: NSView) -> NSView {
        v.translatesAutoresizingMaskIntoConstraints = false
        let r = NSStackView(views: [v])
        r.orientation = .vertical
        r.alignment = .width
        r.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        return r
    }

    /// Accent bubble shown above a list right after onboarding.
    static func callout(_ text: String) -> NSView {
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

    private static func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    private static func row(_ views: [NSView]) -> NSView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = 12
        r.edgeInsets = NSEdgeInsets(top: 9, left: 16, bottom: 9, right: 16)
        r.translatesAutoresizingMaskIntoConstraints = false
        r.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return r
    }
}

/// Rounded box with a hairline between rows, drawn so it follows the
/// appearance (light or dark) on its own.
final class FormGroupBox: NSView {
    private let stack = NSStackView()

    init(rows: [NSView]) {
        super.init(frame: .zero)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        rows.forEach { stack.addArrangedSubview($0) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() { super.layout(); needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        (dark ? NSColor.white.withAlphaComponent(0.06) : NSColor.white.withAlphaComponent(0.75)).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(dark ? 0.5 : 0.8).setStroke()
        path.lineWidth = 1
        path.stroke()
        let visible = stack.arrangedSubviews.filter { !$0.isHidden }
        NSColor.separatorColor.setFill()
        for v in visible.dropLast() {
            NSRect(x: 16, y: v.frame.minY - 0.5, width: bounds.width - 16, height: 1).fill()
        }
    }
}

/// Small rounded square with a white symbol, System Settings style.
final class IconTileView: NSView {
    var symbol = "" { didSet { needsDisplay = true } }
    var tint: NSColor = .systemGray { didSet { needsDisplay = true } }
    private let size: CGFloat

    init(size: CGFloat) {
        self.size = size
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSBezierPath(roundedRect: bounds, xRadius: size * 0.28, yRadius: size * 0.28)
        NSGradient(starting: tint.blended(withFraction: 0.15, of: .white) ?? tint, ending: tint)?.draw(in: r, angle: -90)
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size * 0.55, weight: .semibold)) else { return }
        let t = img.copy() as! NSImage
        t.lockFocus(); NSColor.white.set(); NSRect(origin: .zero, size: t.size).fill(using: .sourceAtop); t.unlockFocus()
        t.isTemplate = false
        t.draw(in: NSRect(x: bounds.midX - t.size.width / 2, y: bounds.midY - t.size.height / 2, width: t.size.width, height: t.size.height),
               from: .zero, operation: .sourceOver, fraction: 1)
    }
}

/// One sidebar entry: tile, name, accent pill when selected.
final class SidebarRowView: NSView {
    var onSelect: (() -> Void)?
    var selected = false { didSet { label.textColor = selected ? .white : .labelColor; needsDisplay = true } }
    private let label: NSTextField

    init(section: SettingsWindowController.Section) {
        label = NSTextField(labelWithString: section.title)
        super.init(frame: .zero)
        let tile = IconTileView(size: 20)
        tile.symbol = section.symbol
        tile.tint = section.tint
        label.font = .systemFont(ofSize: 13)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(section.title)
        setAccessibilityTitle(section.title)
        let h = NSStackView(views: [tile, label])
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 8
        h.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: leadingAnchor), h.trailingAnchor.constraint(equalTo: trailingAnchor),
            h.topAnchor.constraint(equalTo: topAnchor), h.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard selected else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override var mouseDownCanMoveWindow: Bool { false }
    /// The label would swallow the click; the whole row is the target.
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
}

/// Scroll-view document: flipped so short content sits at the top, not the bottom.
final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// A view controller that just hosts a view built elsewhere.
final class PlainViewController: NSViewController {
    private let hosted: NSView
    init(view: NSView) { hosted = view; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = hosted }
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

    override var mouseDownCanMoveWindow: Bool { false }
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

    /// Where the overlay grows from: the drop square if it's on screen, else the middle.
    private var zoneFrame: NSRect {
        guard let zone, zone.window === window, !zone.isHiddenOrHasHiddenAncestor else {
            return NSRect(x: bounds.midX - 50, y: bounds.midY - 50, width: 100, height: 100)
        }
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

/// A blocked website or app: icon, name, remove button, in a rounded pill.
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
