import Foundation
import AppKit

// MARK: - File transfer engine
//
// Replaces the bare `FileManager.copyItem` / `moveItem` calls. Reasons:
//   * Those are blocking and report nothing, so large or cross-disk transfers look
//     like a freeze.
//   * They cannot be cancelled.
//   * `moveItem` across volumes fails for some files (permissions, resource forks)
//     where a copy-then-delete succeeds.
//
// This engine walks the source tree, copies file by file in chunks, reports bytes,
// obeys cancellation, preserves metadata, and cleans up a partial destination.

enum TransferEngine {

    enum TransferError: LocalizedError {
        case cancelled
        case failed(String, URL)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Cancelled"
            case .failed(let reason, let url):
                return "\(url.lastPathComponent): \(reason)"
            }
        }
    }

    /// Mode of a transfer.
    enum Mode {
        case copy
        case move
    }

    /// Estimate the byte size of a set of URLs (recursively).
    static func totalSize(of urls: [URL]) -> Int64 {
        var total: Int64 = 0
        for url in urls {
            total += size(of: url)
        }
        return total
    }

    private static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
            return Int64(values?.fileSize ?? 0)
        }
        guard let enumerator = fm.enumerator(at: url,
                                            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                            options: []) else { return 0 }
        var sum: Int64 = 0
        for case let child as URL in enumerator {
            let values = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                sum += Int64(values?.fileSize ?? 0)
            }
        }
        return sum
    }

    /// Perform the transfer. Call from a background queue.
    /// - Returns: the created destination URLs.
    @discardableResult
    static func transfer(_ sources: [URL],
                         to destination: URL,
                         mode: Mode,
                         job: OperationJob,
                         pathAllocator: (URL) -> URL) throws -> [URL] {
        var created: [URL] = []

        for source in sources {
            if job.isCancelled { throw TransferError.cancelled }

            let target = pathAllocator(destination.appendingPathComponent(source.lastPathComponent))
            do {
                try copyItem(source, to: target, job: job)
                created.append(target)
            } catch TransferError.cancelled {
                // Remove whatever this item produced so a cancel leaves no debris.
                try? FileManager.default.removeItem(at: target)
                throw TransferError.cancelled
            } catch {
                throw TransferError.failed(error.localizedDescription, source)
            }

            // Move = copy then delete the original, which also works across volumes.
            if mode == .move {
                if job.isCancelled {
                    try? FileManager.default.removeItem(at: target)
                    throw TransferError.cancelled
                }
                do {
                    try FileManager.default.removeItem(at: source)
                } catch {
                    throw TransferError.failed("copied, but the original could not be removed: \(error.localizedDescription)", source)
                }
            }
        }
        return created
    }

    // MARK: Recursive copy with progress

    private static func copyItem(_ source: URL, to target: URL, job: OperationJob) throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else {
            throw TransferError.failed("source no longer exists", source)
        }

        if job.isCancelled { throw TransferError.cancelled }

        if isDir.boolValue {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            copyDirectoryAttributes(from: source, to: target)

            let children = try fm.contentsOfDirectory(at: source,
                                                      includingPropertiesForKeys: nil,
                                                      options: [])
            for child in children {
                try copyItem(child,
                             to: target.appendingPathComponent(child.lastPathComponent),
                             job: job)
            }
        } else {
            try copyFile(source, to: target, job: job)
        }
    }

    private static func copyFile(_ source: URL, to target: URL, job: OperationJob) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }

        fm.createFile(atPath: target.path, contents: nil)
        guard let input = try? FileHandle(forReadingFrom: source),
              let output = try? FileHandle(forWritingTo: target) else {
            throw TransferError.failed("cannot read or write file", source)
        }
        defer {
            try? input.close()
            try? output.close()
        }

        let chunkSize = 4 * 1024 * 1024
        while true {
            if job.isCancelled { throw TransferError.cancelled }
            let data = input.readData(ofLength: chunkSize)
            if data.isEmpty { break }
            output.write(data)
            job.advance(Int64(data.count))
        }

        // Preserve timestamps, permissions and extended attributes.
        if let attributes = try? fm.attributesOfItem(atPath: source.path) {
            let keep: [FileAttributeKey] = [.modificationDate, .creationDate, .posixPermissions]
            let filtered = attributes.filter { keep.contains($0.key) }
            try? fm.setAttributes(filtered, ofItemAtPath: target.path)
        }
        // Copy extended attributes (Finder tags, quarantine, resource forks).
        copyExtendedAttributes(from: source, to: target)
    }

    private static func copyDirectoryAttributes(from source: URL, to target: URL) {
        let fm = FileManager.default
        if let attributes = try? fm.attributesOfItem(atPath: source.path) {
            let filtered = attributes.filter { [.modificationDate, .posixPermissions].contains($0.key) }
            try? fm.setAttributes(filtered, ofItemAtPath: target.path)
        }
    }

    private static func copyExtendedAttributes(from source: URL, to target: URL) {
        let listSize = listxattr(source.path, nil, 0, XATTR_NOFOLLOW)
        guard listSize > 0 else { return }
        var names = [CChar](repeating: 0, count: listSize)
        guard listxattr(source.path, &names, listSize, XATTR_NOFOLLOW) == listSize else { return }

        var index = 0
        while index < names.count {
            let namePtr = names.withUnsafeBufferPointer { $0.baseAddress! + index }
            let name = String(cString: namePtr)
            if name.isEmpty { break }

            let valueSize = getxattr(source.path, name, nil, 0, 0, XATTR_NOFOLLOW)
            if valueSize > 0 {
                var value = [UInt8](repeating: 0, count: valueSize)
                if getxattr(source.path, name, &value, valueSize, 0, XATTR_NOFOLLOW) == valueSize {
                    setxattr(target.path, name, value, valueSize, 0, XATTR_NOFOLLOW)
                }
            }
            index += strlen(namePtr) + 1
        }
    }
}
