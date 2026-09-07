import AppKit
import Combine
import UniformTypeIdentifiers
import BusyBlockCore

/// AppKit settings window (SwiftUI macros aren't available with CLT-only builds).
@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let store: ConfigStore
    private let controller: BlockController
    private var cancellables = Set<AnyCancellable>()

    private let hostField = NSTextField()
    private let tokenField = NSTextField()
    private let intervalPopup = NSPopUpButton()
    private let restCheck = NSButton(checkboxWithTitle: "Block during rest phase too", target: nil, action: nil)
    private let screenCheck = NSButton(checkboxWithTitle: "Show the bar's screen in the browser (otherwise a plain countdown)", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let appsTable = NSTableView()
    private let bundleField = NSTextField()
    private let domainsView = NSTextView()
    private let portField = NSTextField()
    private var apps: [String] = []

    init(store: ConfigStore, controller: BlockController) {
        self.store = store
        self.controller = controller
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 690),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "BusyBlock Settings"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.contentView = buildContent()
        w.center()
        controller.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshStatus() }.store(in: &cancellables)
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        load()
        super.showWindow(sender)
    }

    // MARK: Layout

    private func buildContent() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        root.addArrangedSubview(header("BUSY Bar"))
        hostField.placeholderString = "10.0.4.20 or 127.0.0.1:8321"
        root.addArrangedSubview(row("Host", hostField))
        tokenField.placeholderString = "Wi-Fi API token, empty over USB"
        root.addArrangedSubview(row("Token", tokenField))
        for s in [1, 2, 3, 5, 10] { intervalPopup.addItem(withTitle: "\(s) s") }
        root.addArrangedSubview(row("Poll every", intervalPopup))
        root.addArrangedSubview(restCheck)
        root.addArrangedSubview(screenCheck)
        statusLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(row("Status", statusLabel))

        root.addArrangedSubview(header("Apps to hide"))
        let col = NSTableColumn(identifier: .init("app"))
        col.title = "App"
        col.width = 480
        appsTable.addTableColumn(col)
        appsTable.headerView = nil
        appsTable.dataSource = self
        appsTable.delegate = self
        appsTable.allowsMultipleSelection = true
        let scroll = NSScrollView()
        scroll.documentView = appsTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        root.addArrangedSubview(scroll)
        let appButtons = NSStackView()
        appButtons.orientation = .horizontal
        let addApp = NSButton(title: "Add App…", target: self, action: #selector(pickApp))
        bundleField.placeholderString = "or type a bundle id"
        bundleField.target = self
        bundleField.action = #selector(addTypedApp)
        let addTyped = NSButton(title: "Add", target: self, action: #selector(addTypedApp))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeApps))
        [addApp, bundleField, addTyped, remove].forEach { appButtons.addArrangedSubview($0) }
        bundleField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        root.addArrangedSubview(appButtons)

        root.addArrangedSubview(header("Websites to block (one per line)"))
        domainsView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        domainsView.isRichText = false
        domainsView.isAutomaticQuoteSubstitutionEnabled = false
        domainsView.isAutomaticSpellingCorrectionEnabled = false
        let dscroll = NSScrollView()
        dscroll.documentView = domainsView
        dscroll.hasVerticalScroller = true
        dscroll.borderType = .bezelBorder
        dscroll.translatesAutoresizingMaskIntoConstraints = false
        dscroll.heightAnchor.constraint(equalToConstant: 130).isActive = true
        domainsView.autoresizingMask = [.width]
        domainsView.isVerticallyResizable = true
        domainsView.textContainer?.widthTracksTextView = true
        root.addArrangedSubview(dscroll)

        root.addArrangedSubview(header("Local server for the extension"))
        portField.placeholderString = "48321"
        root.addArrangedSubview(row("Port", portField))
        let hint = NSTextField(wrappingLabelWithString: "The extension polls http://127.0.0.1:<port>/state. Restart BusyBlock after changing the port.")
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        root.addArrangedSubview(hint)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        let revert = NSButton(title: "Revert", target: self, action: #selector(revert))
        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        buttons.addArrangedSubview(revert)
        buttons.addArrangedSubview(save)
        root.addArrangedSubview(buttons)
        root.setCustomSpacing(16, after: statusLabel.superview ?? statusLabel)

        for v in root.arrangedSubviews {
            root.widthAnchor.constraint(equalTo: v.widthAnchor, constant: 32).isActive = true
        }
        buttons.alignment = .trailing
        return root
    }

    private func header(_ text: String) -> NSView {
        let l = NSTextField(labelWithString: text)
        l.font = .boldSystemFont(ofSize: 13)
        return l
    }

    private func row(_ label: String, _ control: NSView) -> NSView {
        let s = NSStackView()
        s.orientation = .horizontal
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 80).isActive = true
        s.addArrangedSubview(l)
        s.addArrangedSubview(control)
        control.translatesAutoresizingMaskIntoConstraints = false
        if control is NSTextField { control.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true }
        return s
    }

    // MARK: Data

    private func load() {
        let c = store.config
        hostField.stringValue = c.barHost
        tokenField.stringValue = c.barToken ?? ""
        let idx = [1, 2, 3, 5, 10].firstIndex(of: Int(c.pollIntervalSec.rounded())) ?? 1
        intervalPopup.selectItem(at: idx)
        restCheck.state = c.blockDuringRest ? .on : .off
        screenCheck.state = c.showScreenInBrowser ? .on : .off
        apps = c.blockedApps
        appsTable.reloadData()
        domainsView.string = c.blockedDomains.joined(separator: "\n")
        portField.stringValue = String(c.localPort)
        refreshStatus()
    }

    private func refreshStatus() {
        let s = controller.state
        if !s.barConnected { statusLabel.stringValue = "unreachable · \(controller.lastError ?? "")" }
        else if s.isBlocking { statusLabel.stringValue = "blocking (\(s.phase))" }
        else { statusLabel.stringValue = s.paused ? "paused" : s.phase }
    }

    @objc private func revert() { load() }

    @objc private func save() {
        var c = store.config
        c.barHost = hostField.stringValue.trimmingCharacters(in: .whitespaces)
        c.barToken = tokenField.stringValue.isEmpty ? nil : tokenField.stringValue
        c.pollIntervalSec = Double([1, 2, 3, 5, 10][max(0, intervalPopup.indexOfSelectedItem)])
        c.blockDuringRest = restCheck.state == .on
        c.showScreenInBrowser = screenCheck.state == .on
        c.blockedApps = apps
        c.blockedDomains = Array(Set(domainsView.string.split(whereSeparator: \.isNewline)
            .map { Domain.normalize(String($0)) }.filter { !$0.isEmpty })).sorted()
        c.localPort = UInt16(portField.stringValue) ?? c.localPort
        store.save(c)
        load()
    }

    @objc private func pickApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !apps.contains(id) { apps.append(id) }
        }
        appsTable.reloadData()
    }

    @objc private func addTypedApp() {
        let id = bundleField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return }
        if !apps.contains(id) { apps.append(id) }
        bundleField.stringValue = ""
        appsTable.reloadData()
    }

    @objc private func removeApps() {
        let rows = appsTable.selectedRowIndexes
        apps = apps.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        appsTable.reloadData()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { apps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = apps[row]
        let name: String
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        } else { name = "(not installed)" }
        let cell = NSTextField(labelWithString: "\(name)  —  \(id)")
        cell.lineBreakMode = .byTruncatingMiddle
        return cell
    }
}
