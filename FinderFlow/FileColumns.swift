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

    var defaults: [ColumnKind] {
        switch self {
        case .images:       return [.name, .dimensions, .dateModified, .size, .kind]
        case .audio:        return [.name, .title, .artist, .album, .duration, .dateModified]
        case .video:        return [.name, .duration, .dimensions, .dateModified, .size]
        case .documents:    return [.name, .pageCount, .dateModified, .size, .kind]
        case .applications: return [.name, .version, .dateModified, .size]
        case .generic:      return ColumnKind.baseSet
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

    private var cache: [ColumnProfile: ColumnConfig] = [:]
    private let defaultsKey = "winfilesColumnConfigs"

    private init() { load() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: ColumnConfig].self, from: data)
        else { return }
        for (raw, config) in decoded {
            if let profile = ColumnProfile(rawValue: raw) {
                cache[profile] = config
            }
        }
    }

    private func persist() {
        var raw: [String: ColumnConfig] = [:]
        for (profile, config) in cache { raw[profile.rawValue] = config }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    func config(for profile: ColumnProfile) -> ColumnConfig {
        if let existing = cache[profile] { return existing }
        let fresh = ColumnConfig(order: profile.defaults, widths: [:])
        cache[profile] = fresh
        return fresh
    }

    func setOrder(_ order: [ColumnKind], for profile: ColumnProfile) {
        var config = config(for: profile)
        config.order = order
        cache[profile] = config
        persist()
    }

    func setWidth(_ width: CGFloat, for kind: ColumnKind, profile: ColumnProfile) {
        var config = config(for: profile)
        config.widths[kind.rawValue] = Double(width)
        cache[profile] = config
        persist()
    }

    func toggle(_ kind: ColumnKind, in profile: ColumnProfile) {
        var config = config(for: profile)
        if let index = config.order.firstIndex(of: kind) {
            // Name is the anchor column and cannot be hidden.
            guard kind != .name else { return }
            config.order.remove(at: index)
        } else {
            let allowed = ColumnKind.menuOrder(for: profile)
            guard allowed.contains(kind) else { return }
            config.order.append(kind)
        }
        cache[profile] = config
        persist()
    }

    func reset(_ profile: ColumnProfile) {
        cache[profile] = ColumnConfig(order: profile.defaults, widths: [:])
        persist()
    }
}
