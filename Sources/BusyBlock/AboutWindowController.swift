import AppKit
import BusyBlockCore

/// About panel: what this is, where it lives, and the credits that the
/// licences of the artwork actually require to be in front of the user.
/// The README does not ship inside the app, so the attribution lives here.
@MainActor
final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 420),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "About BusyBlock"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.contentView = build()
        w.setContentSize(w.contentView!.fittingSize)
        w.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let name = NSTextField(labelWithString: "BusyBlock")
        name.font = .systemFont(ofSize: 22, weight: .semibold)

        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let version = NSTextField(labelWithString: "Version \(short) (\(build))")
        version.font = .systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor

        let tagline = wrapped("Hides the apps that distract you and blocks the websites that distract you, for exactly as long as your BUSY Bar timer runs.", size: 13)
        tagline.alignment = .center

        let links = NSStackView(views: [linkButton("Source code", Support.repo), linkButton("Buy me a coffee", Support.page)])
        links.orientation = .horizontal
        links.spacing = 10

        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.widthAnchor.constraint(equalToConstant: 356).isActive = true

        let creditsTitle = NSTextField(labelWithString: "ACKNOWLEDGEMENTS")
        creditsTitle.font = .systemFont(ofSize: 10, weight: .semibold)
        creditsTitle.textColor = .tertiaryLabelColor

        let credits = wrapped("""
        The BUSY Bar device render comes from the open-source BUSY Bar firmware, \
        copyright © Flipper Devices, used under CC-BY 4.0.

        BusyBlock is an unofficial project and is not affiliated with or endorsed by \
        Flipper Devices. "BUSY Bar" is their trademark.

        BusyBlock itself is free software under the GPL-3.0, copyright © 2026 \
        Evgeny Ugreninov. It comes with no warranty.
        """, size: 11)
        credits.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [icon, name, version, tagline, links, rule, creditsTitle, credits])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(4, after: name)
        stack.setCustomSpacing(16, after: version)
        stack.setCustomSpacing(18, after: tagline)
        stack.setCustomSpacing(18, after: links)
        stack.setCustomSpacing(14, after: rule)
        stack.setCustomSpacing(6, after: creditsTitle)
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 32, bottom: 26, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The credits paragraph is the only thing that sets the width.
        for v in [tagline, credits] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: 356).isActive = true
        }
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            host.widthAnchor.constraint(equalToConstant: 420),   // 356 of text plus the insets
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor), stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor), stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return host
    }

    private func wrapped(_ text: String, size: CGFloat) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: size)
        l.preferredMaxLayoutWidth = 356
        l.isSelectable = true
        return l
    }

    private func linkButton(_ title: String, _ url: URL) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(openLink(_:)))
        b.bezelStyle = .rounded
        b.controlSize = .regular
        b.identifier = .init(url.absoluteString)
        return b
    }

    @objc private func openLink(_ sender: NSButton) {
        guard let s = sender.identifier?.rawValue, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }
}
