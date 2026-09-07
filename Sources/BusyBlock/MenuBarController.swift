import AppKit
import Combine
import ServiceManagement
import BusyBlockCore

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let menu = NSMenu()
    private let controller: BlockController
    private let store: ConfigStore
    private let openSettings: () -> Void
    private var cancellables = Set<AnyCancellable>()
    private var tick: Timer?

    private let statusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let detailItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")

    init(controller: BlockController, store: ConfigStore, openSettings: @escaping () -> Void) {
        self.controller = controller
        self.store = store
        self.openSettings = openSettings
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        buildMenu()
        controller.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        controller.$lastError.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    private func buildMenu() {
        menu.delegate = self
        statusItem.isEnabled = false
        detailItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(detailItem)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let folder = NSMenuItem(title: "Open Config Folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        let ext = NSMenuItem(title: "Show Browser Extension Folder", action: #selector(openExtensionFolder), keyEquivalent: "")
        ext.target = self
        menu.addItem(ext)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit BusyBlock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        if #available(macOS 13, *) {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            loginItem.isHidden = Bundle.main.bundleURL.pathExtension != "app"
        }
        refresh()
    }

    private func refresh() {
        let s = controller.state
        let symbol = s.isBlocking ? "hand.raised.fill" : "hand.raised"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "BusyBlock") {
            img.isTemplate = true
            item.button?.image = img
        }
        item.button?.title = s.isBlocking ? " " + remaining(s) : ""

        if !s.barConnected {
            statusItem.title = "Bar unreachable"
            detailItem.title = controller.lastError.map { "\(store.config.barHost): \($0.prefix(60))" } ?? store.config.barHost
        } else if s.isBlocking {
            statusItem.title = "Blocking · \(remaining(s).isEmpty ? "no limit" : remaining(s) + " left")"
            detailItem.title = "\(store.config.blockedApps.count) apps, \(s.domains.count) domains"
        } else if s.paused {
            statusItem.title = "Paused"
            detailItem.title = "Bar connected"
        } else {
            statusItem.title = s.phase == "rest" ? "Rest phase" : "Idle"
            detailItem.title = "Bar connected · \(store.config.barHost)"
        }
    }

    private func remaining(_ s: BlockState) -> String {
        guard let end = s.endsAt else { return "" }
        // Bar shows whole seconds counting down: 58.4 s left reads as 59.
        let secs = max(0, Int((end.timeIntervalSinceNow - 0.05).rounded(.up)))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    @objc private func showSettings() { openSettings() }

    @objc private func openFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.url])
    }

    @objc private func openExtensionFolder() {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("extension"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("extension"),
        ].compactMap { $0 }
        if let dir = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Launch at Login failed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
