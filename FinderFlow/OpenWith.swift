import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - "Open With" support
//
// Files are handled by whatever app the LaunchServices database lists for their type.
// The context menu shows the sensible candidates (the default handler first, then
// other apps that claim the same type), plus an escape hatch to pick any app or
// executable from disk, and a way to remember a per-extension choice.

enum OpenWithService {

    private static var appCache: [String: [URL]] = [:]

    /// Apps registered for this file's type, most relevant first.
    static func applications(for url: URL) -> [URL] {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, let hit = appCache[ext] {
            return hit
        }

        var result: [URL] = []

        let contentType = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
            ?? .data

        // All handlers for the type.
        if let handlers = LSCopyAllRoleHandlersForContentType(contentType.identifier as CFString, .editor)?
            .takeRetainedValue() as? [String] {
            for bundleID in handlers {
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                   app.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL {
                    result.append(app)
                }
            }
        }

        // The current default handler goes first.
        if let def = NSWorkspace.shared.urlForApplication(toOpen: url),
           def.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL {
            result.removeAll { $0.standardizedFileURL == def.standardizedFileURL }
            result.insert(def, at: 0)
        }

        // Fall back to "open in this app" suggestions when nothing is registered.
        if result.isEmpty,
           let apps = NSWorkspace.shared.urlsForApplications(toOpen: url) as [URL]? {
            result = apps.filter { $0.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL }
        }

        if !ext.isEmpty {
            appCache[ext] = result
        }

        return result
    }

    /// Open with a specific app bundle or executable.
    static func open(_ urls: [URL], with app: URL) {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: app.path, isDirectory: &isDir)
        guard exists else { return }

        if isDir.boolValue {
            // App bundle.
            NSWorkspace.shared.open(urls,
                                    withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration())
        } else {
            // Bare executable: pass the paths as arguments.
            let process = Process()
            process.executableURL = app
            process.arguments = urls.map(\.path)
            try? process.run()
        }
    }

    // MARK: Remembered per-extension choice

    private static let key = "ffOpenWithByExtension"

    static func rememberedApp(for url: URL) -> URL? {
        guard let map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else {
            return nil
        }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, let path = map[ext],
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func remember(app: URL, forExtension ext: String) {
        guard !ext.isEmpty else { return }
        var map = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        if app.path.hasPrefix("/Applications") || app.path.hasPrefix("/System") ||
            app.path.hasPrefix(NSHomeDirectory()) || app.path.hasPrefix("/opt") {
            map[ext.lowercased()] = app.path
            UserDefaults.standard.set(map, forKey: key)
        }
    }

    static func forget(extension ext: String) {
        var map = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        map.removeValue(forKey: ext.lowercased())
        UserDefaults.standard.set(map, forKey: key)
    }

    /// Let the user pick any app bundle or executable.
    static func chooseApp() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true        // .app bundles count as directories
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose an app or executable to open the selection with"
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }
}

// MARK: - Menu content

struct OpenWithMenuContent: View {
    let urls: [URL]
    let item: FileItem

    private var apps: [URL] { OpenWithService.applications(for: item.url) }

    private var extensionLabel: String {
        item.fileExtension.isEmpty ? "" : ".\(item.fileExtension.lowercased())"
    }

    var body: some View {
        Group {
            if let remembered = OpenWithService.rememberedApp(for: item.url) {
                Button("\(remembered.deletingPathExtension().lastPathComponent) (always)") {
                    OpenWithService.open(urls, with: remembered)
                }
                Divider()
            }

            if apps.isEmpty {
                Text("No apps registered for this file type")
            } else {
                ForEach(Array(apps.prefix(8).enumerated()), id: \.offset) { _, app in
                    Button(app.deletingPathExtension().lastPathComponent) {
                        OpenWithService.open(urls, with: app)
                    }
                }
            }

            Divider()

            Menu("Always open \(extensionLabel) with") {
                ForEach(Array(apps.prefix(8).enumerated()), id: \.offset) { _, app in
                    Button(app.deletingPathExtension().lastPathComponent) {
                        OpenWithService.remember(app: app, forExtension: item.fileExtension)
                        OpenWithService.open(urls, with: app)
                    }
                }
                if OpenWithService.rememberedApp(for: item.url) != nil {
                    Divider()
                    Button("Forget choice") {
                        OpenWithService.forget(extension: item.fileExtension)
                    }
                }
            }

            Divider()

            Button("Other App or Executable…") {
                guard let app = OpenWithService.chooseApp() else { return }
                OpenWithService.open(urls, with: app)
            }
        }
    }
}
