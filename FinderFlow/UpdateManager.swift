import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

/// Signed updates via Sparkle (when available).
@MainActor
final class UpdateManager: NSObject, ObservableObject {

    static let shared = UpdateManager()

    #if canImport(Sparkle)
    private let controller: SPUStandardUpdaterController
    #endif
    private static let migratedAutoCheckKey = "ffSparkleAutoCheckMigrated"

    private override init() {
        #if canImport(Sparkle)
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        #endif
        super.init()
        #if canImport(Sparkle)
        migrateAutoCheckPreference()
        #endif
    }

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    /// Settings → Updates.
    var autoCheckEnabled: Bool {
        get {
            #if canImport(Sparkle)
            return controller.updater.automaticallyChecksForUpdates
            #else
            return false
            #endif
        }
        set {
            #if canImport(Sparkle)
            controller.updater.automaticallyChecksForUpdates = newValue
            #endif
        }
    }

    nonisolated func checkForUpdates() {
        #if canImport(Sparkle)
        Task { @MainActor in
            Self.shared.controller.checkForUpdates(nil)
        }
        #endif
    }

    #if canImport(Sparkle)
    /// Older builds stored this in `ffAutoCheck`. Sparkle uses its own default after migration.
    private func migrateAutoCheckPreference() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.migratedAutoCheckKey) else { return }
        if defaults.object(forKey: "ffAutoCheck") != nil {
            controller.updater.automaticallyChecksForUpdates = defaults.bool(forKey: "ffAutoCheck")
        }
        defaults.set(true, forKey: Self.migratedAutoCheckKey)
    }
    #endif
}
