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

    init(controller: BlockController, store: ConfigStore, openSettings: @escaping () -> Void) {
        self.controller = controller
        self.store = store
        self.openSettings = openSettings
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        buildMenu()
        controller.$state.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        controller.$lastError.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        controller.$activeHost.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    deinit {
        tick?.invalidate()
        NSStatusBar.system.removeStatusItem(item)
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
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit BusyBlock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        item.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    private func refresh() {
        let s = controller.state
        item.button?.image = Self.statusIcon(filled: s.isBlocking)
        item.button?.title = (s.isBlocking && store.config.showTimerInMenuBar) ? " " + remaining(s) : ""

        let via: String
        switch controller.foundVia {
        case .configured: via = ""
        case .usb: via = " · found on USB"
        case .mdns: via = " · found via mDNS"
        case .bonjour: via = " · found via Bonjour"
        }
        if controller.needsToken {
            statusItem.title = "Bar needs an API token"
            detailItem.title = "\(controller.activeHost)\(via) · paste the token in Settings"
        } else if !s.barConnected {
            statusItem.title = store.config.autoDiscover ? "Looking for the bar…" : "Bar unreachable"
            detailItem.title = controller.lastError.map { "\(controller.activeHost): \($0.prefix(60))" } ?? controller.activeHost
        } else if s.isBlocking {
            statusItem.title = "Blocking · \(remaining(s).isEmpty ? "no limit" : remaining(s) + " left")"
            detailItem.title = "\(store.config.blockedApps.count) apps, \(s.domains.count) domains"
        } else if s.paused {
            statusItem.title = "Paused"
            detailItem.title = "Bar connected"
        } else {
            statusItem.title = s.phase == "rest" ? "Rest phase" : "Idle"
            detailItem.title = "Bar connected · \(controller.activeHost)\(via)"
        }
    }

    /// The app icon's shape as a template image: a rounded square with the bar
    /// knocked out. Filled while blocking, outlined otherwise.
    private static var iconCache: [Bool: NSImage] = [:]
    static func statusIcon(filled: Bool) -> NSImage {
        if let cached = iconCache[filled] { return cached }
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            let box = rect.insetBy(dx: 1, dy: 1)
            let square = NSBezierPath(roundedRect: box, xRadius: 4.2, yRadius: 4.2)
            let bar = NSBezierPath(roundedRect: NSRect(x: box.minX + box.width * 0.22, y: box.midY - box.height * 0.08,
                                                       width: box.width * 0.56, height: box.height * 0.16), xRadius: 1, yRadius: 1)
            NSColor.black.setFill()
            NSColor.black.setStroke()
            if filled {
                square.append(bar)
                square.windingRule = .evenOdd
                square.fill()
            } else {
                square.lineWidth = 1.5
                square.stroke()
                bar.fill()
            }
            return true
        }
        img.isTemplate = true
        iconCache[filled] = img
        return img
    }

    private func remaining(_ s: BlockState) -> String {
        guard let end = s.endsAt else { return "" }
        // Bar shows whole seconds counting down: 58.4 s left reads as 59.
        let secs = max(0, Int((end.timeIntervalSinceNow - 0.05).rounded(.up)))
        return String(format: "%d:%02d", secs / 60, secs % 60)
    }

    @objc private func showSettings() { openSettings() }

}
