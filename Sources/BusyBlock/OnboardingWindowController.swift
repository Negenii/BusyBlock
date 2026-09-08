import AppKit
import Combine
import ServiceManagement
import BusyBlockCore

/// First-run walkthrough: find the bar, install the browser extension, explain
/// hiding, pick launch-at-login and icons, then hand over to Settings.
@MainActor
final class OnboardingWindowController: NSWindowController {
    private let store: ConfigStore
    private let controller: BlockController
    private let onFinish: () -> Void
    private let startNetworking: () -> Void
    private var cancellables = Set<AnyCancellable>()

    // Page 0 widgets
    private let netButton = NSButton(title: "Allow local network access", target: nil, action: nil)
    private let netSpinner = NSProgressIndicator()
    private let netStatus = NSTextField(wrappingLabelWithString: "")
    private let netDeniedBox = NSStackView()
    private var netResult: LocalNetworkAccess.Result?

    private var pages: [NSView] = []
    private var index = 0
    private let pageHost = NSView()
    private let dots = NSStackView()
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let nextButton = NSButton(title: "Continue", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip", target: nil, action: nil)

    // Page 1 widgets
    private let findSpinner = NSProgressIndicator()
    private let findTitle = NSTextField(labelWithString: "")
    private let findText = NSTextField(wrappingLabelWithString: "")
    private let findPanel = DevicePanelView()
    private let findIcon = NSImageView()
    private let hostField = NSTextField()
    private let tokenField = NSTextField()
    private let manualBox = NSStackView()

    // Page 5 widgets
    private let loginCheck = NSButton(checkboxWithTitle: "Launch BusyBlock at login", target: nil, action: nil)
    private let menuCheck = NSButton(checkboxWithTitle: "Icon in the menu bar", target: nil, action: nil)
    private let dockCheck = NSButton(checkboxWithTitle: "Icon in the Dock", target: nil, action: nil)
    private let iconsNote = NSTextField(wrappingLabelWithString: "")

    init(store: ConfigStore, controller: BlockController, startNetworking: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.store = store
        self.controller = controller
        self.startNetworking = startNetworking
        self.onFinish = onFinish
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Welcome to BusyBlock"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.contentView = build()
        w.center()
        controller.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.refreshFind()
            if let self, self.controller.state.barConnected, self.netResult != .granted {
                self.netResult = .granted
                self.netSpinner.stopAnimation(nil)
                self.netStatus.stringValue = "✓ Local network access is on."
                self.netButton.title = "Access granted"; self.netButton.isEnabled = false
                self.netDeniedBox.isHidden = true
                if self.index == 0 { self.nextButton.isEnabled = true }
            }
        }.store(in: &cancellables)
        controller.$discovering.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshFind() }.store(in: &cancellables)
        controller.$searchFailed.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshFind() }.store(in: &cancellables)
        controller.$needsToken.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshFind() }.store(in: &cancellables)
        LiveFrames.shared.$frame.receive(on: DispatchQueue.main).sink { [weak self] f in self?.findPanel.frame72 = f }.store(in: &cancellables)
        show(0)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func build() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 20, right: 32)
        root.translatesAutoresizingMaskIntoConstraints = false
        root.widthAnchor.constraint(equalToConstant: 600).isActive = true

        pageHost.translatesAutoresizingMaskIntoConstraints = false
        pageHost.widthAnchor.constraint(equalToConstant: 536).isActive = true
        pageHost.heightAnchor.constraint(equalToConstant: 372).isActive = true
        root.addArrangedSubview(pageHost)

        dots.orientation = .horizontal
        dots.spacing = 6
        backButton.target = self; backButton.action = #selector(back)
        nextButton.target = self; nextButton.action = #selector(next)
        nextButton.keyEquivalent = "\r"
        skipButton.target = self; skipButton.action = #selector(skip)
        skipButton.isBordered = false
        skipButton.contentTintColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [skipButton, dots, spacer, backButton, nextButton])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 10
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 536).isActive = true
        root.addArrangedSubview(bar)

        pages = [pageNetwork(), pageFind(), pageExtension(), pageHiding(), pageStartup(), pageDone()]
        for _ in pages {
            let d = DotView()
            d.translatesAutoresizingMaskIntoConstraints = false
            d.widthAnchor.constraint(equalToConstant: 8).isActive = true
            d.heightAnchor.constraint(equalToConstant: 8).isActive = true
            dots.addArrangedSubview(d)
        }
        return root
    }

    private func page(_ title: String, _ subtitle: String, _ body: [NSView]) -> NSView {
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 24, weight: .bold)
        let st = NSTextField(wrappingLabelWithString: subtitle)
        st.font = .systemFont(ofSize: 14)
        st.textColor = .secondaryLabelColor
        let v = NSStackView(views: [t, st] + body)
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 14
        v.setCustomSpacing(6, after: t)
        v.translatesAutoresizingMaskIntoConstraints = false
        for b in body { b.translatesAutoresizingMaskIntoConstraints = false }
        st.preferredMaxLayoutWidth = 536
        return v
    }

    private func label(_ text: String, size: CGFloat = 13, muted: Bool = false) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: size)
        if muted { l.textColor = .secondaryLabelColor }
        l.preferredMaxLayoutWidth = 536
        return l
    }

    // MARK: Page 0 — local network permission

    private func pageNetwork() -> NSView {
        netButton.target = self; netButton.action = #selector(askNetwork)
        netButton.bezelStyle = .rounded
        netButton.controlSize = .large
        netSpinner.style = .spinning
        netSpinner.controlSize = .small
        netSpinner.isDisplayedWhenStopped = false
        netStatus.font = .systemFont(ofSize: 13)
        netStatus.preferredMaxLayoutWidth = 536
        let row = NSStackView(views: [netButton, netSpinner])
        row.orientation = .horizontal
        row.spacing = 10
        netDeniedBox.orientation = .vertical
        netDeniedBox.alignment = .leading
        netDeniedBox.spacing = 8
        netDeniedBox.addArrangedSubview(label("Without it BusyBlock can't reach the bar. Turn it on in System Settings → Privacy & Security → Local Network, then check again.", muted: true))
        let openSettings = NSButton(title: "Open System Settings", target: self, action: #selector(openPrivacySettings))
        let recheck = NSButton(title: "Check again", target: self, action: #selector(askNetwork))
        let btns = NSStackView(views: [openSettings, recheck])
        btns.orientation = .horizontal
        netDeniedBox.addArrangedSubview(btns)
        netDeniedBox.isHidden = true
        return page("One permission first",
                    "To find your BUSY Bar, BusyBlock talks to devices on your local network: over the USB link and over Wi-Fi. macOS asks you once whether that's okay.",
                    [row, netStatus, netDeniedBox])
    }

    @objc private func askNetwork() {
        netButton.isEnabled = false
        netSpinner.startAnimation(nil)
        netStatus.stringValue = "Waiting for your answer…"
        netDeniedBox.isHidden = true
        startNetworking()   // the first LAN contact is what makes macOS show the prompt
        LocalNetworkAccess.probe { [weak self] result in
            guard let self else { return }
            // The bar answering settles it regardless of what the probe saw.
            let r: LocalNetworkAccess.Result = controller.state.barConnected ? .granted : result
            netResult = r
            netSpinner.stopAnimation(nil)
            switch r {
            case .granted:
                netStatus.stringValue = "✓ Local network access is on."
                netButton.title = "Access granted"
                nextButton.isEnabled = true
            case .denied:
                netStatus.stringValue = "Access was declined."
                netDeniedBox.isHidden = false
                netButton.isEnabled = true
            case .undetermined:
                netStatus.stringValue = "No answer yet. If macOS asked, choose Allow; otherwise access is probably already on."
                netButton.isEnabled = true
                netButton.title = "Check again"
            }
        }
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Page 1 — find the bar

    private func pageFind() -> NSView {
        // One title (the page's), then the bar centred, then one status line.
        findSpinner.style = .spinning
        findSpinner.controlSize = .small
        findSpinner.isDisplayedWhenStopped = false
        findTitle.font = .systemFont(ofSize: 14, weight: .medium)
        findText.font = .systemFont(ofSize: 13)
        findText.textColor = .secondaryLabelColor
        findText.alignment = .center
        findText.preferredMaxLayoutWidth = 480
        findPanel.translatesAutoresizingMaskIntoConstraints = false
        findPanel.widthAnchor.constraint(equalToConstant: 380).isActive = true
        findPanel.heightAnchor.constraint(equalToConstant: 380 * 248 / 768).isActive = true
        findIcon.contentTintColor = .secondaryLabelColor
        findIcon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        findIcon.isHidden = true
        let head = NSStackView(views: [findSpinner, findIcon, findTitle])
        head.orientation = .horizontal
        head.spacing = 8
        let centre = NSStackView(views: [findPanel, head, findText])
        centre.orientation = .vertical
        centre.alignment = .centerX
        centre.spacing = 10
        centre.setCustomSpacing(16, after: findPanel)
        centre.translatesAutoresizingMaskIntoConstraints = false
        centre.widthAnchor.constraint(equalToConstant: 536).isActive = true

        hostField.placeholderString = "Bar address, e.g. 10.0.4.20 or 192.168.1.50"
        tokenField.placeholderString = "API token, only if access protection is on"
        for f in [hostField, tokenField] { f.translatesAutoresizingMaskIntoConstraints = false; f.widthAnchor.constraint(equalToConstant: 360).isActive = true }
        let retry = NSButton(title: "Try again", target: self, action: #selector(retryFind))
        manualBox.orientation = .vertical
        manualBox.alignment = .leading
        manualBox.spacing = 8
        manualBox.addArrangedSubview(label("Connect the bar over USB, or make sure it's on the same Wi-Fi. You can also type its address:", muted: true))
        manualBox.addArrangedSubview(hostField)
        manualBox.addArrangedSubview(tokenField)
        manualBox.addArrangedSubview(retry)
        manualBox.isHidden = true

        manualBox.translatesAutoresizingMaskIntoConstraints = false
        manualBox.widthAnchor.constraint(equalToConstant: 536).isActive = true
        return page("Let's find your BUSY Bar", "BusyBlock hides apps and blocks websites while the bar's timer is running, so first it needs to see the bar.",
                    [centre, manualBox])
    }

    private func refreshFind() {
        let s = controller.state
        let searching = !s.barConnected && !controller.searchFailed && (controller.discovering || store.config.autoDiscover)
        if searching { findSpinner.startAnimation(nil) } else { findSpinner.stopAnimation(nil) }
        findPanel.dimmed = !s.barConnected
        manualBox.isHidden = true
        findIcon.isHidden = true
        if controller.needsToken {
            findTitle.stringValue = "Found it, but it wants an API token"
            findText.stringValue = "The bar has access protection on. Create a token in its settings and paste it here."
            manualBox.isHidden = false
        } else if s.barConnected {
            findTitle.stringValue = "Found your device"
            let usb = s.host == BarLocator.usbHost
            findIcon.image = NSImage(systemSymbolName: usb ? "cable.connector" : "wifi", accessibilityDescription: usb ? "USB" : "Wi-Fi")
            findIcon.isHidden = false
            findText.stringValue = ""
        } else if searching {
            findTitle.stringValue = "Looking for the bar…"
            findText.stringValue = "Checking USB, busybar.local and Bonjour."
        } else {
            findTitle.stringValue = "No bar found yet"
            findText.stringValue = "You can continue anyway; BusyBlock keeps looking in the background."
            manualBox.isHidden = false
        }
    }

    @objc private func retryFind() {
        var c = store.config
        let host = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        if !host.isEmpty { c.barHost = host }
        c.barToken = tokenField.stringValue.isEmpty ? nil : tokenField.stringValue
        store.save(c)
        controller.linkSuspect()
    }

    // MARK: Page 2 — browser extension

    private func pageExtension() -> NSView {
        let safariSteps = NSStackView(views: [
            stepCard(1, "Safari → Settings → Extensions", illustration: .extensionsTab),
            stepCard(2, "Tick BusyBlock", illustration: .tickRow),
            stepCard(3, "Allow it on every website", illustration: .allowButton),
            stepCard(4, "Keep its icon in the toolbar: that's where you block a site and see the timer", illustration: .toolbar),
        ])
        safariSteps.orientation = .vertical
        safariSteps.alignment = .leading
        safariSteps.spacing = 8

        let chromeIcon = NSImageView(image: NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: nil)!)
        chromeIcon.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        chromeIcon.contentTintColor = .secondaryLabelColor
        let chromeText = label("Chrome, Arc, Brave, Edge: install the BusyBlock extension from the Chrome Web Store (link coming soon).", muted: true)
        let chrome = NSStackView(views: [chromeIcon, chromeText])
        chrome.orientation = .horizontal
        chrome.alignment = .top
        chrome.spacing = 10

        return page("Add the browser extension", "The extension is already inside this app for Safari; it only needs to be switched on.",
                    [safariSteps, chrome])
    }

    private enum Illustration { case extensionsTab, tickRow, allowButton, toolbar }

    private func stepCard(_ n: Int, _ text: String, illustration: Illustration) -> NSView {
        let num = NSTextField(labelWithString: "\(n)")
        num.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        num.textColor = .controlAccentColor
        num.translatesAutoresizingMaskIntoConstraints = false
        num.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let t = label(text)
        t.preferredMaxLayoutWidth = 300
        let art = IllustrationView(kind: illustration)
        art.translatesAutoresizingMaskIntoConstraints = false
        art.widthAnchor.constraint(equalToConstant: 190).isActive = true
        art.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let spacer = NSView(); spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [num, t, spacer, art])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 536).isActive = true
        return row
    }

    // MARK: Page 3 — hiding

    private func pageHiding() -> NSView {
        // Real icons from this Mac where possible, so the picture means something.
        let ws = NSWorkspace.shared
        var icons: [NSImage] = []
        for app in Suggestions.apps where icons.count < 4 {
            if let url = ws.urlForApplication(withBundleIdentifier: app.id) { icons.append(ws.icon(forFile: url.path)) }
        }
        for id in store.config.blockedApps where icons.count < 4 {
            if let url = ws.urlForApplication(withBundleIdentifier: id), let img = Optional(ws.icon(forFile: url.path)), !icons.contains(img) { icons.append(img) }
        }
        while icons.count < 4 { icons.append(NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!) }

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 14
        row.alignment = .centerY
        for img in icons {
            let cell = NSView()
            cell.translatesAutoresizingMaskIntoConstraints = false
            cell.widthAnchor.constraint(equalToConstant: 64).isActive = true
            cell.heightAnchor.constraint(equalToConstant: 64).isActive = true
            let iv = NSImageView(image: img)
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.alphaValue = 0.3
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv)
            let badge = HiddenBadgeView()
            badge.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(badge)
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor), iv.topAnchor.constraint(equalTo: cell.topAnchor),
                iv.widthAnchor.constraint(equalToConstant: 56), iv.heightAnchor.constraint(equalToConstant: 56),
                badge.widthAnchor.constraint(equalToConstant: 22), badge.heightAnchor.constraint(equalToConstant: 22),
                badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor), badge.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
            ])
            row.addArrangedSubview(cell)
        }
        let sceneBox = NSStackView(views: [row])
        sceneBox.alignment = .centerX
        sceneBox.translatesAutoresizingMaskIntoConstraints = false
        sceneBox.widthAnchor.constraint(equalToConstant: 536).isActive = true
        sceneBox.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)

        func point(_ symbol: String, _ text: String) -> NSView {
            let i = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
            i.symbolConfiguration = .init(pointSize: 14, weight: .regular)
            i.contentTintColor = .secondaryLabelColor
            i.translatesAutoresizingMaskIntoConstraints = false
            i.widthAnchor.constraint(equalToConstant: 22).isActive = true
            let l = label(text)
            l.preferredMaxLayoutWidth = 500
            let r = NSStackView(views: [i, l])
            r.orientation = .horizontal
            r.alignment = .firstBaseline
            r.spacing = 8
            return r
        }
        return page("Apps hide, they don't quit",
                    "While the bar is busy, the apps on your list vanish the moment they come to the front.",
                    [sceneBox,
                     point("checkmark.circle", "Nothing closes. Unsaved work stays put."),
                     point("clock.arrow.circlepath", "Timer ends, the apps are back where they were."),
                     point("safari", "Websites show a block page with the bar's screen on it."),
                     point("lock", "Quit BusyBlock mid-session? The browser still blocks until the timer runs out.")])
    }

    // MARK: Page 4 — startup and icons

    private func pageStartup() -> NSView {
        loginCheck.target = self; loginCheck.action = #selector(toggleLogin)
        menuCheck.target = self; menuCheck.action = #selector(toggleIcons)
        dockCheck.target = self; dockCheck.action = #selector(toggleIcons)
        loginCheck.state = .on
        menuCheck.state = store.config.showMenuBarIcon ? .on : .off
        dockCheck.state = store.config.showDockIcon ? .on : .off
        iconsNote.font = .systemFont(ofSize: 12)
        iconsNote.textColor = .secondaryLabelColor
        iconsNote.preferredMaxLayoutWidth = 536
        updateIconsNote()
        return page("Run it quietly", "BusyBlock has nothing to say most of the time, so it can stay out of sight.",
                    [loginCheck, label("Where do you want its icon?", size: 13), menuCheck, dockCheck, iconsNote])
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13, *) else { return }
        do {
            if loginCheck.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
    }

    @objc private func toggleIcons() {
        var c = store.config
        c.showMenuBarIcon = menuCheck.state == .on
        c.showDockIcon = dockCheck.state == .on
        store.save(c)
        updateIconsNote()
    }

    private func updateIconsNote() {
        iconsNote.stringValue = (menuCheck.state == .off && dockCheck.state == .off)
            ? "No icon at all is fine: open BusyBlock from the browser extension's popup, from the Applications folder, or Spotlight."
            : "You can change this later in Settings."
    }

    // MARK: Page 5 — done

    private func pageDone() -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 40, weight: .light)
        icon.contentTintColor = .systemGreen
        return page("That's it", "Last thing: tell BusyBlock what distracts you.",
                    [icon, label("Next you'll see Settings. Add the apps to hide and the websites to block; there are one-click suggestions for the usual suspects. Then start the bar and try opening one of them.")])
    }

    // MARK: - Navigation

    private func show(_ i: Int) {
        index = max(0, min(pages.count - 1, i))
        pageHost.subviews.forEach { $0.removeFromSuperview() }
        let p = pages[index]
        pageHost.addSubview(p)
        NSLayoutConstraint.activate([p.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor), p.topAnchor.constraint(equalTo: pageHost.topAnchor),
                                     p.widthAnchor.constraint(equalTo: pageHost.widthAnchor)])
        for (k, d) in dots.arrangedSubviews.enumerated() { (d as? DotView)?.color = k == index ? .controlAccentColor : .quaternaryLabelColor }
        backButton.isHidden = index == 0
        nextButton.title = index == pages.count - 1 ? "Open Settings" : "Continue"
        nextButton.isEnabled = index != 0 || netResult == .granted
        skipButton.isHidden = index == pages.count - 1
        if index == 1 { refreshFind() }
        if index == 4 {
            if #available(macOS 13, *) { loginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off }
        }
    }

    @objc private func back() { show(index - 1) }
    @objc private func next() { if index == pages.count - 1 { finish() } else { show(index + 1) } }
    @objc private func skip() { finish() }

    private func finish() {
        var c = store.config
        c.onboardingDone = true
        store.save(c)
        window?.close()
        onFinish()
    }
}

/// Round accent badge with a crossed-out eye, for "this app gets hidden".
final class HiddenBadgeView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 22, height: 22) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        guard let sym = NSImage(systemSymbolName: "eye.slash.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) else { return }
        let tinted = sym.copy() as! NSImage
        tinted.lockFocus(); NSColor.white.set(); NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop); tinted.unlockFocus()
        let sz = tinted.size
        tinted.draw(in: NSRect(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2, width: sz.width, height: sz.height))
    }
}

/// Small schematic pictures for the Safari steps, drawn rather than shipped as images.
final class IllustrationView: NSView {
    private let kind: OnboardingIllustrationKind
    init(kind: Any) {
        self.kind = OnboardingIllustrationKind(rawValue: String(describing: kind)) ?? .extensionsTab
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.1).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds.insetBy(dx: 10, dy: 8)
        let font = NSFont.systemFont(ofSize: 11)
        let muted: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let strong: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor]
        func icon(_ name: String, at p: NSPoint, size: CGFloat = 14, tint: NSColor = .labelColor) {
            guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: size, weight: .regular)) else { return }
            let tinted = img.copy() as! NSImage
            tinted.lockFocus(); tint.set(); NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop); tinted.unlockFocus()
            tinted.draw(at: p, from: .zero, operation: .sourceOver, fraction: 1)
        }
        func appIcon(at p: NSPoint, size: CGFloat = 16) {
            let r = NSRect(x: p.x, y: p.y, width: size, height: size)
            NSColor(calibratedRed: 0.9, green: 0.28, blue: 0.3, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: size * 0.22, yRadius: size * 0.22).fill()
            NSColor.white.setFill()
            NSRect(x: r.minX + size * 0.22, y: r.midY - size * 0.08, width: size * 0.56, height: size * 0.16).fill()
        }
        switch kind {
        case .extensionsTab:
            icon("gearshape", at: NSPoint(x: b.minX, y: b.midY - 8), size: 14, tint: .secondaryLabelColor)
            "Settings".draw(at: NSPoint(x: b.minX + 20, y: b.midY - 7), withAttributes: muted)
            icon("puzzlepiece.extension", at: NSPoint(x: b.minX + 84, y: b.midY - 8), size: 14, tint: .controlAccentColor)
            "Extensions".draw(at: NSPoint(x: b.minX + 104, y: b.midY - 7), withAttributes: strong)
        case .tickRow:
            let box = NSRect(x: b.minX, y: b.midY - 7, width: 14, height: 14)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
            icon("checkmark", at: NSPoint(x: box.minX + 2, y: box.minY + 1), size: 9, tint: .white)
            appIcon(at: NSPoint(x: b.minX + 22, y: b.midY - 8))
            "BusyBlock".draw(at: NSPoint(x: b.minX + 44, y: b.midY - 7), withAttributes: strong)
        case .allowButton:
            let btn = NSRect(x: b.minX, y: b.midY - 11, width: b.width, height: 22)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: btn, xRadius: 6, yRadius: 6).fill()
            let t = "Always Allow on Every Website"
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white]
            let sz = t.size(withAttributes: a)
            t.draw(at: NSPoint(x: btn.midX - sz.width / 2, y: btn.midY - sz.height / 2), withAttributes: a)
        case .toolbar:
            let bar = NSRect(x: b.minX, y: b.midY - 10, width: b.width, height: 20)
            NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 5, yRadius: 5).fill()
            icon("chevron.left", at: NSPoint(x: bar.minX + 6, y: bar.midY - 6), size: 10, tint: .tertiaryLabelColor)
            icon("chevron.right", at: NSPoint(x: bar.minX + 22, y: bar.midY - 6), size: 10, tint: .tertiaryLabelColor)
            let field = NSRect(x: bar.minX + 40, y: bar.midY - 6, width: bar.width - 84, height: 12)
            NSColor.windowBackgroundColor.setFill()
            NSBezierPath(roundedRect: field, xRadius: 4, yRadius: 4).fill()
            appIcon(at: NSPoint(x: bar.maxX - 34, y: bar.midY - 7), size: 14)
            icon("puzzlepiece.extension", at: NSPoint(x: bar.maxX - 16, y: bar.midY - 6), size: 11, tint: .tertiaryLabelColor)
        }
    }
}

enum OnboardingIllustrationKind: String { case extensionsTab, tickRow, allowButton, toolbar }
