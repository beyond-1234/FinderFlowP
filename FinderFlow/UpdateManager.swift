import AppKit

// MARK: - Update checking
//
// This fork is self-hosted: it is not published through FinderFlow's release channel,
// so shipping an auto-updater pointed at the upstream appcast would offer updates that
// overwrite local changes. Sparkle was removed deliberately.
//
// The type is kept so the rest of the app (Settings, menu command) does not need to
// know about it. If you later publish your own builds, wire your update mechanism in
// here and the UI will pick it up.

@MainActor
final class UpdateManager: NSObject, ObservableObject {

    static let shared = UpdateManager()

    private override init() { super.init() }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// No updater is installed, so there is nothing to toggle.
    var autoCheckEnabled: Bool {
        get { false }
        set { _ = newValue }
    }

    /// Tells the user why nothing happens instead of failing silently.
    func checkForUpdates() {
        let alert = NSAlert()
        alert.messageText = "Updates are not configured"
        alert.informativeText = """
        This build is your own fork, so it does not check FinderFlow's release channel. \
        Rebuild it from your repository to get the latest changes.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
