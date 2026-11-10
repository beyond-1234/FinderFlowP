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
// A column is identified by a stable `ColumnKind`. The header menu groups candidates by
// the file types a folder actually contains (see FileTypeScanner), while the visible set
// stays stable across folders and only changes when the user edits it.

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

    /// Default visible columns — the set the list has always shipped with.
    static let defaultOrder: [ColumnKind] = [
        .name, .dateModified, .dateCreated, .size, .kind, .fileExtension
    ]

    /// Columns that only make sense for particular file types.
    /// Used both to group the header menu and to decide what is worth offering.
    var group: ColumnGroup? {
        switch self {
        case .dimensions, .pageCount:      return .imageAndDocument
        case .duration, .title, .artist, .album: return .media
        case .version:                     return .application
        default:                           return nil
        }
    }
}

// MARK: - Column groups for the header menu
//
// The menu offers columns grouped by the kind of file the folder actually contains.
// Nothing is enabled automatically: detection only decides which groups are worth
// showing, and the user ticks what they want.

enum ColumnGroup: String, CaseIterable, Identifiable {
    case general
    case imageAndDocument
    case media
    case application

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:          return "General"
        case .imageAndDocument: return "Images & Documents"
        case .media:            return "Audio & Video"
        case .application:      return "Applications"
        }
    }

    /// Columns in this group, in menu order.
    var columns: [ColumnKind] {
        switch self {
        case .general:
            return [.name, .dateModified, .dateCreated, .dateAdded,
                    .size, .kind, .fileExtension, .permissions, .path]
        case .imageAndDocument:
            return [.dimensions, .pageCount]
        case .media:
            return [.duration, .title, .artist, .album]
        case .application:
            return [.version]
        }
    }
}

// MARK: - File type detection
//
// Scans the extensions present in the current folder and reports which column groups
// are relevant. This is deliberately *only* used to decide what the header menu offers —
// it never changes the visible columns by itself.

enum FileTypeScanner {

    struct Result {
        /// Groups worth offering, in a stable display order.
        var groups: [ColumnGroup]
        /// Number of files matched per group, so the menu can hint at relevance.
        var counts: [ColumnGroup: Int]

        static let empty = Result(groups: [.general], counts: [:])
    }

    static func scan(_ files: [FileItem]) -> Result {
        var counts: [ColumnGroup: Int] = [:]
        var sawAny = false

        for file in files where !file.isBrowsableFolder {
            sawAny = true
            for group in groups(forExtension: file.fileExtension) {
                counts[group, default: 0] += 1
            }
        }

        guard sawAny else { return .empty }

        // Always offer the general group; add the specialised ones that actually occur.
        var groups: [ColumnGroup] = [.general]
        for group in [ColumnGroup.imageAndDocument, .media, .application] {
            if counts[group, default: 0] > 0 {
                groups.append(group)
            }
        }
        return Result(groups: groups, counts: counts)
    }

    /// Which groups a single extension belongs to.
    static func groups(forExtension ext: String) -> [ColumnGroup] {
        switch ext.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif",
             "bmp", "webp", "raw", "cr2", "nef", "arw", "dng", "svg",
             "pdf", "pages", "doc", "docx", "rtf", "odt",
             "xls", "xlsx", "ppt", "pptx":
            return [.imageAndDocument]
        case "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "ogg", "opus", "wma",
             "mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpg", "mpeg":
            return [.media]
        case "app":
            return [.application]
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
        defaultConfig = ColumnConfig(order: ColumnKind.defaultOrder, widths: [:])
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
        defaultConfig = ColumnConfig(order: ColumnKind.defaultOrder, widths: [:])
        persist()
    }

    /// Forget every folder override.
    func clearAllOverrides() {
        overrides.removeAll()
        persist()
    }
}
