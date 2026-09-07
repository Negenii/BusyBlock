import AppKit
import Combine
import UniformTypeIdentifiers
import BusyBlockCore

/// Settings window. Everything saves as you change it (no Save button) and
/// every status line follows the controller live. AppKit only: SwiftUI macros
/// don't build with Command Line Tools.
@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let store: ConfigStore
    private let controller: BlockController
    private var cancellables = Set<AnyCancellable>()
    private var loading = false

    // Status card
    private let statusDot = DotView()
    private let statusTitle = NSTextField(labelWithString: "")
    private let statusDetail = NSTextField(labelWithString: "")

    // Bar
    private let hostField = NSTextField()
    private let tokenField = NSTextField()
    private let discoverCheck = NSButton(checkboxWithTitle: "Find the bar automatically when this host is silent", target: nil, action: nil)
    private let restCheck = NSButton(checkboxWithTitle: "Keep blocking during rest phases", target: nil, action: nil)
    private let screenCheck = NSButton(checkboxWithTitle: "Show the bar's screen in the browser", target: nil, action: nil)

    // Apps
    private let appsTable = NSTableView()
    private let dropZone = DropZoneView()
    private var apps: [String] = []

    // Domains
    private let domainsTable = NSTableView()
    private let domainField = NSTextField()
    private var domains: [String] = []

    private let saveDebounce = PassthroughSubject<Void, Never>()

    init(store: ConfigStore, controller: BlockController) {
        self.store = store
        self.controller = controller
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "BusyBlock"
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        super.init(window: w)
        w.contentView = buildContent()
        w.center()

        controller.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshStatus() }.store(in: &cancellables)
        controller.$activeHost.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshStatus() }.store(in: &cancellables)
        controller.$needsToken.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshStatus() }.store(in: &cancellables)
        controller.$lastError.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshStatus() }.store(in: &cancellables)
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
    }

    // MARK: - Layout

    private func buildContent() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        root.addArrangedSubview(statusCard())

        root.addArrangedSubview(header("BUSY Bar"))
        hostField.placeholderString = "10.0.4.20 over USB, an IP over Wi-Fi, or 127.0.0.1:8321 for busybar-manager"
        hostField.delegate = self
        root.addArrangedSubview(row("Host", hostField))
        tokenField.placeholderString = "only if access protection is on in the bar's settings"
        tokenField.delegate = self
        root.addArrangedSubview(row("API token", tokenField))
        for check in [discoverCheck, restCheck, screenCheck] {
            check.target = self
            check.action = #selector(toggled)
            root.addArrangedSubview(indent(check))
        }

        root.addArrangedSubview(header("Apps to hide while the bar is busy"))
        let appsScroll = table(appsTable, id: "app", rowHeight: 40)
        appsTable.registerForDraggedTypes([.fileURL])
        root.addArrangedSubview(appsScroll)
        dropZone.onDrop = { [weak self] urls in self?.addApps(urls) }
        dropZone.onClick = { [weak self] in self?.pickApp() }
        root.addArrangedSubview(dropZone)
        dropZone.translatesAutoresizingMaskIntoConstraints = false
        dropZone.heightAnchor.constraint(equalToConstant: 64).isActive = true

        root.addArrangedSubview(header("Websites to block"))
        root.addArrangedSubview(table(domainsTable, id: "domain", rowHeight: 30))
        domainField.placeholderString = "youtube.com, reddit.com/r/all, …  press Return to add"
        domainField.delegate = self
        domainField.target = self
        domainField.action = #selector(addDomain)
        let addBtn = NSButton(title: "Add", target: self, action: #selector(addDomain))
        let domainRow = NSStackView(views: [domainField, addBtn])
        domainRow.orientation = .horizontal
        root.addArrangedSubview(domainRow)

        let hint = NSTextField(wrappingLabelWithString: "Changes apply immediately. Select an item and press Delete to remove it. Config file: \(store.url.path)")
        hint.textColor = .tertiaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        root.addArrangedSubview(hint)

        for v in root.arrangedSubviews {
            root.widthAnchor.constraint(equalTo: v.widthAnchor, constant: 48).isActive = true
        }
        return root
    }

    private func statusCard() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        statusTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        statusDetail.font = .systemFont(ofSize: 12)
        statusDetail.textColor = .secondaryLabelColor
        statusDetail.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [statusTitle, statusDetail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let h = NSStackView(views: [statusDot, text])
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 12
        h.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        h.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: card.leadingAnchor), h.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            h.topAnchor.constraint(equalTo: card.topAnchor), h.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 14), statusDot.heightAnchor.constraint(equalToConstant: 14),
        ])
        return card
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

    private func table(_ table: NSTableView, id: String, rowHeight: CGFloat) -> NSView {
        let col = NSTableColumn(identifier: .init(id))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = rowHeight
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 8
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: id == "app" ? 150 : 120).isActive = true
        return scroll
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
        if apps != c.blockedApps { apps = c.blockedApps; appsTable.reloadData() }
        if domains != c.blockedDomains { domains = c.blockedDomains; domainsTable.reloadData() }
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
        c.blockedApps = apps
        c.blockedDomains = domains
        store.save(c)
    }

    private func refreshStatus() {
        let s = controller.state
        let host = controller.activeHost
        let via: String
        switch controller.foundVia {
        case .configured: via = ""
        case .usb: via = " · found on USB"
        case .mdns: via = " · found via mDNS"
        case .bonjour: via = " · found via Bonjour"
        }
        if controller.needsToken {
            statusDot.color = .systemOrange
            statusTitle.stringValue = "The bar wants an API token"
            statusDetail.stringValue = "\(host)\(via) · create one in the bar's settings and paste it below"
        } else if !s.barConnected {
            statusDot.color = .systemGray
            statusTitle.stringValue = store.config.autoDiscover ? "Looking for the bar…" : "Bar unreachable"
            let err = controller.lastError.map { " · \($0.prefix(70))" } ?? ""
            statusDetail.stringValue = "\(host)\(err)"
        } else if s.isBlocking {
            statusDot.color = .systemRed
            let left = s.endsAt.map { Self.remaining($0) } ?? ""
            statusTitle.stringValue = "Blocking · " + (left.isEmpty ? "no time limit" : "\(left) left")
            statusDetail.stringValue = "\(apps.count) apps, \(domains.count) websites · bar at \(host)\(via)"
        } else {
            statusDot.color = .systemGreen
            statusTitle.stringValue = s.paused ? "Paused" : s.phase == "rest" ? "Rest phase" : "Idle · start the bar to block"
            statusDetail.stringValue = "Bar at \(host)\(via)"
        }
    }

    private static func remaining(_ end: Date) -> String {
        let secs = max(0, Int((end.timeIntervalSinceNow - 0.05).rounded(.up)))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    // MARK: - Actions

    @objc private func toggled() { saveDebounce.send() }

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
        appsTable.reloadData()
        saveDebounce.send()
    }

    @objc private func addDomain() {
        let d = Domain.normalize(domainField.stringValue)
        guard !d.isEmpty else { NSSound.beep(); return }
        domainField.stringValue = ""
        guard !domains.contains(d) else { return }
        domains.append(d)
        domains.sort()
        domainsTable.reloadData()
        saveDebounce.send()
    }

    private func removeSelected(in table: NSTableView) {
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else { return }
        if table === appsTable { apps = apps.enumerated().filter { !rows.contains($0.offset) }.map(\.element) }
        else { domains = domains.enumerated().filter { !rows.contains($0.offset) }.map(\.element) }
        table.reloadData()
        saveDebounce.send()
    }

    // MARK: - Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === appsTable ? apps.count : domains.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === appsTable {
            let id = apps[row]
            let cell = ItemCell.dequeue(tableView, id: "appCell")
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                cell.icon.image = NSWorkspace.shared.icon(forFile: url.path)
                cell.title.stringValue = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                cell.subtitle.stringValue = id
            } else {
                cell.icon.image = NSImage(systemSymbolName: "questionmark.app.dashed", accessibilityDescription: nil)
                cell.title.stringValue = id
                cell.subtitle.stringValue = "not installed"
            }
            cell.onRemove = { [weak self] in
                guard let self, let i = self.apps.firstIndex(of: id) else { return }
                self.apps.remove(at: i); self.appsTable.reloadData(); self.saveDebounce.send()
            }
            return cell
        }
        let d = domains[row]
        let cell = ItemCell.dequeue(tableView, id: "domainCell", compact: true)
        cell.icon.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        cell.icon.contentTintColor = .secondaryLabelColor
        cell.title.stringValue = d
        cell.subtitle.stringValue = ""
        FaviconLoader.shared.image(for: d) { [weak cell] img in
            // The cell may have been recycled for another domain by now.
            guard let cell, cell.title.stringValue == d, let img else { return }
            cell.icon.image = img
        }
        cell.onRemove = { [weak self] in
            guard let self, let i = self.domains.firstIndex(of: d) else { return }
            self.domains.remove(at: i); self.domainsTable.reloadData(); self.saveDebounce.send()
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === appsTable, !DropZoneView.appURLs(info).isEmpty else { return [] }
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let urls = DropZoneView.appURLs(info)
        addApps(urls)
        return !urls.isEmpty
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, let t = window?.firstResponder as? NSTableView {
            removeSelected(in: t)
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - Views

/// Icon + title + subtitle + hover "remove" button.
final class ItemCell: NSTableCellView {
    let icon = NSImageView()
    let title = NSTextField(labelWithString: "")
    let subtitle = NSTextField(labelWithString: "")
    private let remove = NSButton()
    var onRemove: (() -> Void)?

    static func dequeue(_ table: NSTableView, id: String, compact: Bool = false) -> ItemCell {
        if let c = table.makeView(withIdentifier: .init(id), owner: nil) as? ItemCell { return c }
        let c = ItemCell(compact: compact)
        c.identifier = .init(id)
        return c
    }

    init(compact: Bool) {
        super.init(frame: .zero)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        let size: CGFloat = compact ? 16 : 28
        icon.widthAnchor.constraint(equalToConstant: size).isActive = true
        icon.heightAnchor.constraint(equalToConstant: size).isActive = true
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 13, weight: compact ? .regular : .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.isHidden = compact
        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        remove.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove")
        remove.isBordered = false
        remove.contentTintColor = .tertiaryLabelColor
        remove.target = self
        remove.action = #selector(removeTapped)
        remove.toolTip = "Remove"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let h = NSStackView(views: [icon, text, spacer, remove])
        h.orientation = .horizontal
        h.alignment = .centerY
        h.spacing = 10
        h.distribution = .fill
        h.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        h.translatesAutoresizingMaskIntoConstraints = false
        addSubview(h)
        NSLayoutConstraint.activate([
            h.leadingAnchor.constraint(equalTo: leadingAnchor), h.trailingAnchor.constraint(equalTo: trailingAnchor),
            h.topAnchor.constraint(equalTo: topAnchor), h.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        text.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func removeTapped() { onRemove?() }
}

/// Dashed "drop apps here" target; also clickable to open the file picker.
final class DropZoneView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onClick: (() -> Void)?
    private var active = false { didSet { needsDisplay = true } }
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        let icon = NSImageView(image: NSImage(systemSymbolName: "square.and.arrow.down.on.square", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        label.stringValue = "Drop apps here from Finder, or click to choose"
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 12)
        let s = NSStackView(views: [icon, label])
        s.orientation = .horizontal
        s.spacing = 8
        s.translatesAutoresizingMaskIntoConstraints = false
        addSubview(s)
        NSLayoutConstraint.activate([s.centerXAnchor.constraint(equalTo: centerXAnchor), s.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }

    required init?(coder: NSCoder) { fatalError() }

    static func appURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { $0.pathExtension == "app" && Bundle(url: $0)?.bundleIdentifier != nil }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        (active ? NSColor.controlAccentColor.withAlphaComponent(0.12) : NSColor.quaternaryLabelColor.withAlphaComponent(0.05)).setFill()
        path.fill()
        path.lineWidth = active ? 2 : 1
        path.setLineDash([6, 4], count: 2, phase: 0)
        (active ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setStroke()
        path.stroke()
        label.textColor = active ? .controlAccentColor : .secondaryLabelColor
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !Self.appURLs(sender).isEmpty
        active = ok
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { active = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { active = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.appURLs(sender)
        active = false
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    override func mouseUp(with event: NSEvent) { onClick?() }
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
