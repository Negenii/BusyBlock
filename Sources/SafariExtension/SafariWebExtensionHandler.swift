import SafariServices
import AppKit
import os.log

/// Native side of the Safari extension. The popup asks us to launch BusyBlock
/// when the helper isn't answering; we live inside that app, so we open it.
class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let logger = Logger(subsystem: "me.negenii.BusyBlock.Extension", category: "handler")

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let type = message?["type"] as? String ?? ""
        var response: [String: Any] = ["ok": false]
        if type == "launch" { response["ok"] = launchApp() }
        let reply = NSExtensionItem()
        reply.userInfo = [SFExtensionMessageKey: response]
        context.completeRequest(returningItems: [reply])
    }

    /// The .appex sits in BusyBlock.app/Contents/PlugIns/, so the app is three levels up.
    private func launchApp() -> Bool {
        let appURL = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard appURL.pathExtension == "app" else {
            logger.error("unexpected bundle layout: \(appURL.path, privacy: .public)")
            return false
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { [logger] _, error in
            if let error { logger.error("launch failed: \(error.localizedDescription, privacy: .public)") }
        }
        return true
    }
}
