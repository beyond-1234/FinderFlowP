import SwiftUI

/// Persisted browse preferences — defaults mirror macOS Finder with newest-first
/// date grouping. Users can change any setting; it sticks.
enum UserPreferences {
    static let viewModeKey       = "ffViewMode"
    static let sortFieldKey      = "ffSortField"
    static let sortAscendingKey  = "ffSortAscending"
    static let groupByKey        = "ffGroupBy"
    static let folderOrderKey    = "ffFolderOrder"
    static let showHiddenKey     = "ffShowHidden"
    static let showPreviewKey    = "ffShowPreview"
    /// Bumped key so FinderFlowP enforces its own default settings
    static let defaultsMigratedKey = "ffBrowseDefaultsMigrated200"
    static let didShowFirstRunKey  = "ffDidShowFirstRun"

    // FinderFlowP defaults: list + no grouping + Name A→Z + folders on top
    static let defaultViewMode:       ViewMode     = .list
    static let defaultSortField:      SortField    = .name
    static let defaultSortAscending:  Bool         = true
    static let defaultGroupBy:        GroupBy      = .none
    static let defaultFolderOrder:    FolderOrder  = .foldersFirst

    /// Applies FinderFlowP Dolphin/Windows-like browse defaults
    static func migrateBrowseDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: defaultsMigratedKey) else { return }
        defaults.set(true, forKey: defaultsMigratedKey)

        defaults.set(defaultSortField.rawValue, forKey: sortFieldKey)
        defaults.set(defaultSortAscending, forKey: sortAscendingKey)
        defaults.set(defaultGroupBy.rawValue, forKey: groupByKey)
        defaults.set(defaultViewMode.rawValue, forKey: viewModeKey)
        defaults.set(defaultFolderOrder.rawValue, forKey: folderOrderKey)
    }

    /// Apply factory browse defaults (Settings reset + install repair).
    static func applyFactoryBrowseDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(defaultViewMode.rawValue, forKey: viewModeKey)
        defaults.set(defaultSortField.rawValue, forKey: sortFieldKey)
        defaults.set(defaultSortAscending, forKey: sortAscendingKey)
        defaults.set(defaultGroupBy.rawValue, forKey: groupByKey)
        defaults.set(defaultFolderOrder.rawValue, forKey: folderOrderKey)
    }
}

// MARK: - AppStorage helpers (enum ↔ persisted raw string)

extension ViewMode {
    static func fromStorage(_ raw: String) -> ViewMode {
        ViewMode(rawValue: raw) ?? UserPreferences.defaultViewMode
    }
}

extension SortField {
    static func fromStorage(_ raw: String) -> SortField {
        SortField(rawValue: raw) ?? UserPreferences.defaultSortField
    }
}

extension GroupBy {
    static func fromStorage(_ raw: String) -> GroupBy {
        GroupBy(rawValue: raw) ?? UserPreferences.defaultGroupBy
    }
}

extension FolderOrder {
    static func fromStorage(_ raw: String) -> FolderOrder {
        FolderOrder(rawValue: raw) ?? UserPreferences.defaultFolderOrder
    }
}
