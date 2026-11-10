import Foundation

// MARK: - One-time preference migration
//
// The app was developed under a working name and stored its settings under
// `winfiles*` keys. Everything now uses the `ff*` prefix so the fork stays consistent
// with the upstream naming scheme.
//
// This migrates those values once, so upgrading does not silently reset the user's
// search scope, column layout, integrations or icon size.

enum PreferenceMigration {

    private static let doneKey = "ffWorkingNameMigrationDone"

    /// Old key → new key. Only keys the working name introduced are listed; the rest
    /// already used the `ff` prefix.
    private static let renames: [(String, String)] = [
        ("winfilesSearchScope",          "ffSearchScope"),
        ("winfilesDefaultColumns",       "ffDefaultColumns"),
        ("winfilesFolderColumns",        "ffFolderColumns"),
        ("winfilesIntegrationOverrides", "ffIntegrationOverrides"),
        ("winfilesDefaultTerminalID",    "ffDefaultTerminalID"),
        ("winfilesArchiveToolID",        "ffArchiveToolID"),
        ("winfilesOpenWithByExtension",  "ffOpenWithByExtension"),
        ("winfilesIconSize",             "ffIconSize"),
        // The migration flag itself moved from winfilesDefaultsMigrated100 to
        // ffBrowseDefaultsMigrated200; that one is intentionally NOT carried over, so
        // the new default-set pass runs once under the new key.
    ]

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }

        for (oldKey, newKey) in renames {
            guard let value = defaults.object(forKey: oldKey) else { continue }
            // Never overwrite a value the new key already holds.
            if defaults.object(forKey: newKey) == nil {
                defaults.set(value, forKey: newKey)
            }
            defaults.removeObject(forKey: oldKey)
        }

        defaults.set(true, forKey: doneKey)
    }
}
