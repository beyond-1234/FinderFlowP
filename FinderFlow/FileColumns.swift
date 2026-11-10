import SwiftUI
import AppKit
import AVFoundation
import ImageIO

// MARK: - Column model
//
// Windows Explorer's Details view does not show one fixed column set everywhere: a
// folder of photos gets Dimensions, a music folder gets Title/Artist/Album/Length, a
// folder of sources gets Type/Size/Date modified. The same idea is implemented here.
//
// A column is identified by a stable `ColumnKind`. A folder resolves to a `ColumnProfile`
// (from the file extensions it contains), and each profile has its own column order,
// visibility and widths persisted in UserDefaults, so customising a photo folder does
// not disturb a source-code folder.

enum ColumnKind: String, Codable, CaseIterable, Identifiable {
    case name
    case dateModified
    case dateCreated
    case dateAdded
    case size
    case kind
    case fileExtension
    case dimensions
    case duration
    case title
    case artist
    case album
    case pageCount
    case version
    case permissions
    case path

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name:         return "Name"
        case .dateModified: return "Date Modified"
        case .dateCreated:  return "Date Created"
        case .dateAdded:    return "Date Added"
        case .size:         return "Size"
        case .kind:         return "Type"
        case .fileExtension: return "Extension"
        case .dimensions:   return "Dimensions"
        case .duration:     return "Length"
        case .title:        return "Title"
        case .artist:       return "Artist"
        case .album:        return "Album"
        case .pageCount:    return "Pages"
        case .version:      return "Version"
        case .permissions:  return "Permissions"
        case .path:         return "Path"
        }
    }

    var defaultWidth: CGFloat {
        switch self {
        case .name:         return 260
        case .dateModified: return 148
        case .dateCreated:  return 148
        case .dateAdded:    return 140
        case .size:         return 88
        case .kind:         return 120
        case .fileExtension: return 80
        case .dimensions:   return 110
        case .duration:     return 80
        case .title:        return 150
        case .artist:       return 130
        case .album:        return 140
        case .pageCount:    return 60
        case .version:      return 80
        case .permissions:  return 100
        case .path:         return 240
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name: return 120
        case .size, .pageCount, .duration: return 50
        default: return 60
        }
    }

    /// Right-aligned for numbers, like Explorer.
    var alignment: NSTextAlignment {
        switch self {
        case .size, .pageCount, .dimensions, .duration: return .right
        default: return .left
        }
    }

    /// Sort key matching this column, or nil when the column is not sortable.
    var sortField: SortField? {
        switch self {
        case .name, .title, .artist, .album: return .name
        case .dateModified, .dateAdded:      return .dateModified
        case .dateCreated:                   return .dateCreated
        case .size:                          return .size
        case .kind:                          return .kind
        case .fileExtension:                 return .ext
        default:                             return nil
        }
    }

    /// Columns every profile starts with.
    static let baseSet: [ColumnKind] = [.name, .dateModified, .kind, .size]

    /// Everything the user may add, in menu order.
    static func menuOrder(for profile: ColumnProfile) -> [ColumnKind] {
        switch profile {
        case .images:    return [.name, .dateModified, .dateCreated, .dimensions, .size, .kind, .fileExtension, .path]
        case .audio:     return [.name, .title, .artist, .album, .duration, .dateModified, .size, .kind, .fileExtension, .path]
        case .video:     return [.name, .duration, .dimensions, .dateModified, .size, .kind, .fileExtension, .path]
        case .documents: return [.name, .pageCount, .dateModified, .dateCreated, .size, .kind, .fileExtension, .path]
        case .applications: return [.name, .version, .dateModified, .size, .kind, .path]
        default:         return [.name, .dateModified, .dateCreated, .size, .kind, .fileExtension, .permissions, .path]
        }
    }
}

// MARK: - Profiles

enum ColumnProfile: String, Codable, CaseIterable, Identifiable {
    case generic
    case images
    case audio
    case video
    case documents
    case applications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .generic:      return "General"
        case .images:       return "Pictures"
        case .audio:        return "Music"
        case .video:        return "Videos"
        case .documents:    return "Documents"
        case .applications: return "Applications"
        }
    }

    /// Column set used when the profile has never been customised.
    ///
    /// Deliberately the same six columns the list view shipped with, so switching to
    /// the configurable table does not silently hide columns people already relied on.
    var defaults: [ColumnKind] {
        switch self {
        case .images:
            return [.name, .dateModified, .dimensions, .dateCreated, .size, .kind, .fileExtension]
        case .audio:
            return [.name, .dateModified, .title, .artist, .album, .duration, .dateCreated, .size, .kind, .fileExtension]
        case .video:
            return [.name, .dateModified, .duration, .dimensions, .dateCreated, .size, .kind, .fileExtension]
        case .documents:
            return [.name, .dateModified, .pageCount, .dateCreated, .size, .kind, .fileExtension]
        case .applications:
            return [.name, .dateModified, .version, .dateCreated, .size, .kind, .fileExtension]
        case .generic:
            // The original six, in the original order.
            return [.name, .dateModified, .dateCreated, .size, .kind, .fileExtension]
        }
    }

    /// Pick the profile that best describes a folder, based on the extensions present.
    /// The most common relevant type wins; ties fall back to the generic profile.
    static func detect(from files: [FileItem]) -> ColumnProfile {
        var counts: [ColumnProfile: Int] = [:]
        var total = 0

        for file in files where !file.isBrowsableFolder {
            total += 1
            for profile in profileFor(extension: file.fileExtension) {
                counts[profile, default: 0] += 1
            }
        }

        guard total > 0 else { return .generic }

        // Require a real majority so a single stray .jpg in a code folder does not
        // switch the whole layout to Pictures.
        let best = counts.max { $0.value < $1.value }
        if let best, Double(best.value) / Double(total) >= 0.5 {
            return best.key
        }
        return .generic
    }

    private static func profileFor(extension ext: String) -> [ColumnProfile] {
        switch ext.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif",
             "bmp", "webp", "raw", "cr2", "nef", "arw", "dng", "svg":
            return [.images]
        case "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma":
            return [.audio]
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg":
            return [.video]
        case "pdf", "doc", "docx", "rtf", "txt", "md", "pages", "odt", "xls", "xlsx", "ppt", "pptx":
            return [.documents]
        case "app":
            return [.applications]
        default:
            return []
        }
    }
}

// MARK: - Persisted column configuration
//
// Design rule: the column layout is STABLE across folders. Navigating must never
// silently add or remove columns. A folder only gains a different layout when the user
// explicitly changes it, and that change is remembered for that folder alone.
//
// Storage therefore has two layers:
//   * a global default (applies to every folder that has no override), and
//   * per-folder overrides keyed by path.
//
// File-type detection does not drive this any more. It only decides which columns the
// header menu *suggests first* (a Pictures folder lists Dimensions near the top), and
// the extra columns stay unchecked until the user ticks them.

struct ColumnConfig: Codable, Equatable {
    /// Visible columns, in display order.
    var order: [ColumnKind]
    /// Width per column.
    var widths: [String: Double]

    func width(for kind: ColumnKind) -> CGFloat {
        CGFloat(widths[kind.rawValue] ?? Double(kind.defaultWidth))
    }
}

final class ColumnConfigStore {
    static let shared = ColumnConfigStore()

    /// The layout used by any folder without its own override.
    private(set) var defaultConfig: ColumnConfig
    /// Per-folder overrides, keyed by folder path.
    private var overrides: [String: ColumnConfig] = [:]

    private let defaultKey = "winfilesDefaultColumns"
    private let overridesKey = "winfilesFolderColumns"

    private init() {
        defaultConfig = ColumnConfig(order: ColumnProfile.generic.defaults, widths: [:])
        load()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: defaultKey),
           let decoded = try? JSONDecoder().decode(ColumnConfig.self, from: data) {
            defaultConfig = decoded
        }
        if let data = UserDefaults.standard.data(forKey: overridesKey),
           let decoded = try? JSONDecoder().decode([String: ColumnConfig].self, from: data) {
            overrides = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(defaultConfig) {
            UserDefaults.standard.set(data, forKey: defaultKey)
        }
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: overridesKey)
        }
    }

    // MARK: Reading

    /// Configuration for a folder: its own override, else the global default.
    func config(forFolder folder: URL?) -> ColumnConfig {
        guard let key = folder?.standardizedFileURL.path,
              let override = overrides[key] else { return defaultConfig }
        return override
    }

    func hasOverride(forFolder folder: URL?) -> Bool {
        guard let key = folder?.standardizedFileURL.path else { return false }
        return overrides[key] != nil
    }

    // MARK: Writing

    /// Apply a change. With a folder, the change becomes that folder's override;
    /// without one, it updates the global default.
    func update(forFolder folder: URL?, _ mutate: (inout ColumnConfig) -> Void) {
        if let key = folder?.standardizedFileURL.path {
            var config = overrides[key] ?? defaultConfig
            mutate(&config)
            overrides[key] = config
        } else {
            mutate(&defaultConfig)
        }
        persist()
    }

    func setOrder(_ order: [ColumnKind], forFolder folder: URL?) {
        update(forFolder: folder) { $0.order = order }
    }

    func setWidth(_ width: CGFloat, for kind: ColumnKind, forFolder folder: URL?) {
        update(forFolder: folder) { $0.widths[kind.rawValue] = Double(width) }
    }

    func toggle(_ kind: ColumnKind, forFolder folder: URL?) {
        update(forFolder: folder) { config in
            if let index = config.order.firstIndex(of: kind) {
                // Name is the anchor column and cannot be hidden.
                guard kind != .name else { return }
                config.order.remove(at: index)
            } else {
                config.order.append(kind)
            }
        }
    }

    /// Drop this folder's override so it follows the global default again.
    func clearOverride(forFolder folder: URL?) {
        guard let key = folder?.standardizedFileURL.path else { return }
        overrides.removeValue(forKey: key)
        persist()
    }

    /// Reset the global default to the original column set.
    func resetDefault() {
        defaultConfig = ColumnConfig(order: ColumnProfile.generic.defaults, widths: [:])
        persist()
    }

    /// Forget every folder override.
    func clearAllOverrides() {
        overrides.removeAll()
        persist()
    }
}
