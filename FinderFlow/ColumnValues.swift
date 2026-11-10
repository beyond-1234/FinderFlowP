import Foundation
import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Column values
//
// Media metadata (dimensions, duration, title/artist/album, page count, version) is
// only read when a profile actually shows it — probing every file in a folder would be
// slow and pointless for a source tree.

final class ColumnValueLoader {
    static let shared = ColumnValueLoader()

    private var cache: [String: ExtraMetadata] = [:]
    private let queue = DispatchQueue(label: "FinderFlowP.column.metadata",
                                      qos: .userInitiated,
                                      attributes: .concurrent)

    struct ExtraMetadata {
        var dimensions: String?
        var duration: String?
        var title: String?
        var artist: String?
        var album: String?
        var pageCount: String?
        var version: String?
    }

    func cached(for url: URL) -> ExtraMetadata? {
        cache[url.path]
    }

    /// Load metadata off the main thread, then call back on the main queue.
    func load(_ files: [FileItem],
              kinds: Set<ColumnKind>,
              completion: @escaping () -> Void) {
        guard !kinds.isEmpty else { return }

        queue.async {
            var changed = false
            for file in files where !file.isBrowsableFolder {
                if self.cache[file.url.path] != nil { continue }
                let meta = self.probe(file: file, kinds: kinds)
                if meta.hasAnyValue {
                    self.cache[file.url.path] = meta
                    changed = true
                }
            }
            guard changed else { return }
            DispatchQueue.main.async(execute: completion)
        }
    }

    func value(for kind: ColumnKind, item: FileItem) -> String? {
        guard let meta = cache[item.url.path] else { return nil }
        switch kind {
        case .dimensions: return meta.dimensions
        case .duration:   return meta.duration
        case .title:      return meta.title
        case .artist:     return meta.artist
        case .album:      return meta.album
        case .pageCount:  return meta.pageCount
        case .version:    return meta.version
        default:          return nil
        }
    }

    func clear() {
        cache.removeAll()
    }

    // MARK: Probing

    private func probe(file: FileItem, kinds: Set<ColumnKind>) -> ExtraMetadata {
        var meta = ExtraMetadata()

        if kinds.contains(.dimensions) || kinds.contains(.duration) {
            if file.isMediaKind {
                if let probe = probeMedia(file.url) {
                    meta.dimensions = probe.dimensions
                    meta.duration = probe.duration
                }
            }
        }
        if kinds.contains(.pageCount) {
            meta.pageCount = probePageCount(file.url)
        }
        if kinds.contains(.version) {
            meta.version = probeVersion(file.url)
        }
        if kinds.contains(.title) || kinds.contains(.artist) || kinds.contains(.album) {
            let tags = probeAudioTags(file.url)
            meta.title = tags.title
            meta.artist = tags.artist
            meta.album = tags.album
        }
        return meta
    }

    private func probeMedia(_ url: URL) -> (dimensions: String?, duration: String?)? {
        let asset = AVURLAsset(url: url)
        var dimensions: String?
        var duration: String?

        if let track = asset.tracks(withMediaType: .video).first {
            let size = track.naturalSize.applying(track.preferredTransform)
            let width = abs(Int(size.width.rounded()))
            let height = abs(Int(size.height.rounded()))
            if width > 0, height > 0 {
                dimensions = fileExtensionIsImage(url)
                    ? "\(width) × \(height)"
                    : "\(width) × \(height)"
            }
        }
        // Still images have no AV track; read the pixel size from ImageIO.
        if dimensions == nil, fileExtensionIsImage(url),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int {
            dimensions = "\(width) × \(height)"
        }

        let seconds = CMTimeGetSeconds(asset.duration)
        if seconds.isFinite, seconds > 0 {
            duration = formatDuration(seconds)
        }
        return (dimensions, duration)
    }

    private func fileExtensionIsImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    private func probePageCount(_ url: URL) -> String? {
        guard url.pathExtension.lowercased() == "pdf",
              let doc = CGPDFDocument(url as CFURL) else { return nil }
        let pages = doc.numberOfPages
        return pages > 0 ? "\(pages)" : nil
    }

    private func probeVersion(_ url: URL) -> String? {
        guard let bundle = Bundle(url: url) else { return nil }
        let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String
        if let short, let build, short != build { return "\(short) (\(build))" }
        return short ?? build
    }

    /// Audio tags via AVAsset metadata (works for m4a/mp3/aiff without extra deps).
    private func probeAudioTags(_ url: URL) -> (title: String?, artist: String?, album: String?) {
        let asset = AVURLAsset(url: url)
        var title: String?
        var artist: String?
        var album: String?

        for item in asset.commonMetadata {
            guard let key = item.commonKey?.rawValue,
                  let value = item.stringValue, !value.isEmpty else { continue }
            switch key {
            case "title":  title = value
            case "artist", "creator", "author": artist = value
            case "albumName": album = value
            default: break
            }
        }
        return (title, artist, album)
    }
}

private extension ColumnValueLoader.ExtraMetadata {
    var hasAnyValue: Bool {
        dimensions != nil || duration != nil || title != nil
            || artist != nil || album != nil || pageCount != nil || version != nil
    }
}

extension FileItem {
    /// Cheap extension test so metadata probing skips irrelevant files.
    var isMediaKind: Bool {
        switch fileExtension {
        case "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp",
             "webp", "mp4", "mov", "m4v", "avi", "mkv", "webm", "mp3", "m4a",
             "aac", "flac", "wav", "aiff", "aif", "ogg", "opus":
            return true
        default:
            return false
        }
    }
}
