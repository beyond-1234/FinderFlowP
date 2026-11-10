import SwiftUI
import AppKit

// MARK: - Archive tools
//
// The built-in zipper is /usr/bin/zip: it produces .zip only, shows no progress and
// takes no options. Users with 7-Zip, Keka, BetterZip or Entropy usually want those
// tools' formats and their right-click depth.
//
// This registry finds installed archivers via LaunchServices and the login-shell PATH,
// so the archive dialog can offer real choices instead of one fixed behaviour.

struct ArchiveTool: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleIDs: [String]
    let appPaths: [String]
    let cli: String?

    /// Formats this tool can produce, given to the dialog.
    let formats: [ArchiveFormat]

    static func == (lhs: ArchiveTool, rhs: ArchiveTool) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ArchiveFormat: Identifiable, Hashable {
    let id: String          // extension, e.g. "zip"
    let title: String       // "ZIP (.zip)"
    /// Optional extra sub-choice, e.g. compression level.
    let levels: [ArchiveLevel]

    static func == (lhs: ArchiveFormat, rhs: ArchiveFormat) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ArchiveLevel: Identifiable, Hashable {
    let id: String
    let title: String

    static func == (lhs: ArchiveLevel, rhs: ArchiveLevel) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum ArchiveToolCatalog {

    static let levels: [ArchiveLevel] = [
        ArchiveLevel(id: "store",  title: "Store (no compression)"),
        ArchiveLevel(id: "fast",   title: "Fast"),
        ArchiveLevel(id: "normal", title: "Normal"),
        ArchiveLevel(id: "best",   title: "Best compression"),
    ]

    static let zipFormats: [ArchiveFormat] = [
        ArchiveFormat(id: "zip", title: "ZIP (.zip)", levels: levels),
        ArchiveFormat(id: "7z",  title: "7-Zip (.7z)", levels: levels),
    ]

    static let all: [ArchiveTool] = [
        ArchiveTool(id: "builtin", name: "Built-in (macOS zip)",
                    bundleIDs: [], appPaths: [], cli: nil,
                    formats: [ArchiveFormat(id: "zip", title: "ZIP (.zip)", levels: levels)]),
        ArchiveTool(id: "tool.sevenzip", name: "7-Zip",
                    bundleIDs: [], appPaths: ["/Applications/7z.app",
                                              "/Applications/7-Zip.app"],
                    cli: "7zz",
                    formats: [
                        ArchiveFormat(id: "7z",   title: "7-Zip (.7z)", levels: levels),
                        ArchiveFormat(id: "zip",  title: "ZIP (.zip)", levels: levels),
                        ArchiveFormat(id: "tar",  title: "TAR (.tar)", levels: []),
                        ArchiveFormat(id: "tar.gz", title: "TAR.GZ (.tar.gz)", levels: levels),
                        ArchiveFormat(id: "xz",   title: "XZ (.xz)", levels: levels),
                    ]),
        ArchiveTool(id: "tool.keka", name: "Keka",
                    bundleIDs: ["com.aone.keka"],
                    appPaths: ["/Applications/Keka.app"],
                    cli: nil,
                    formats: [
                        ArchiveFormat(id: "7z",   title: "7-Zip (.7z)", levels: levels),
                        ArchiveFormat(id: "zip",  title: "ZIP (.zip)", levels: levels),
                        ArchiveFormat(id: "tar.gz", title: "TAR.GZ (.tar.gz)", levels: levels),
                        ArchiveFormat(id: "tar.bz2", title: "TAR.BZ2 (.tar.bz2)", levels: levels),
                        ArchiveFormat(id: "tar.xz", title: "TAR.XZ (.tar.xz)", levels: levels),
                    ]),
        ArchiveTool(id: "tool.betterzip", name: "BetterZip",
                    bundleIDs: ["com.macitbetter.betterzip", "com.macitbetter.betterzip.setapp"],
                    appPaths: ["/Applications/BetterZip.app"],
                    cli: nil,
                    formats: [
                        ArchiveFormat(id: "zip", title: "ZIP (.zip)", levels: levels),
                        ArchiveFormat(id: "7z",  title: "7-Zip (.7z)", levels: levels),
                        ArchiveFormat(id: "tar", title: "TAR (.tar)", levels: []),
                    ]),
        ArchiveTool(id: "tool.archiver", name: "Archiver",
                    bundleIDs: ["com.macpaw.Archiver"],
                    appPaths: ["/Applications/Archiver.app"],
                    cli: nil,
                    formats: [
                        ArchiveFormat(id: "zip", title: "ZIP (.zip)", levels: levels),
                        ArchiveFormat(id: "7z",  title: "7-Zip (.7z)", levels: levels),
                        ArchiveFormat(id: "rar", title: "RAR (.rar)", levels: levels),
                    ]),
    ]

    /// Tools installed on this machine.
    static func installed() -> [ArchiveTool] {
        let shellPath = IntegrationStore.loginShellPATH()
        return all.filter { tool in
            if tool.id == "builtin" { return true }
            if !tool.bundleIDs.isEmpty {
                for bid in tool.bundleIDs where NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) != nil {
                    return true
                }
            }
            for path in tool.appPaths where FileManager.default.fileExists(atPath: path) {
                return true
            }
            if let cli = tool.cli,
               IntegrationStore.resolveCLI(cli, shellPath: shellPath) != nil {
                return true
            }
            return false
        }
    }

    static func tool(id: String) -> ArchiveTool? {
        all.first { $0.id == id }
    }
}
