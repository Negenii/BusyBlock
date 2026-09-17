import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

/// Self-updates through Sparkle: the app checks a signed feed on GitHub once a
/// day and offers the new version. Sparkle only exists in the Xcode build, so
/// the Swift-command-line build (used by the self-test) compiles without it.
@MainActor
final class Updater {
    static let shared = Updater()

    #if canImport(Sparkle)
    private let controller = SPUStandardUpdaterController(startingUpdater: true,
                                                          updaterDelegate: nil,
                                                          userDriverDelegate: nil)
    /// False in builds without Sparkle, so the UI can hide the controls.
    let available = true
    var checksAutomatically: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    func checkNow() { controller.updater.checkForUpdates() }
    #else
    let available = false
    var checksAutomatically: Bool {
        get { false }
        set { _ = newValue }
    }
    func checkNow() {}
    #endif
}
