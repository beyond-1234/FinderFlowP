import SwiftUI
import ServiceManagement

@main
struct FinderFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var favorites = FavoritesService()

    var body: some Scene {
        // A URL-keyed WindowGroup gives each "Open in New Window" request its own
        // window: SwiftUI presents a new scene for a value it has not seen yet.
        // Relying on NSWorkspace.open(folder) instead handed the folder to Finder,
        // because LaunchServices routes folders to the system's default handler.
        WindowGroup(for: URL.self) { $url in
            ContentView(initialPath: url)
                .environmentObject(favorites)
        } defaultValue: {
            FileManager.default.homeDirectoryForCurrentUser
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            FinderFlowCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    /// Folder requested while launching before any window is ready (cold launch).
    /// ContentView consumes this on first appear.
    static var pendingNavigationURL: URL?

    /// Folders that should open in their *own* window rather than navigating the
    /// current one. ContentView drains this list.
    static var pendingNewWindowURLs: [URL] = []

    /// Ask for a separate window showing `url`.
    @MainActor
    static func requestNewWindow(for url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        // `openWindow(value:)` is only reachable from SwiftUI; the notification is the
        // delegate-side path, handled by whichever ContentView is on screen.
        NotificationCenter.default.post(name: .openFolderInNewWindow, object: url)
    }

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        TooltipTiming.applyFastTooltips()
        UserPreferences.migrateBrowseDefaultsIfNeeded()
        _ = UpdateManager.shared
        // Sync stored toggle with actual SMAppService registration state
        if #available(macOS 13.0, *) {
            let enabled = SMAppService.mainApp.status == .enabled
            UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Open folders / finderflow:// links

    /// Handles both file URLs (folder/file opened with FinderFlow, e.g. "Open With",
    /// `open -a`, or being the default folder handler) and the custom `finderflow://`
    /// scheme posted by the Finder Sync extension's "Open in FinderFlow" item.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handleOpen(url) }
    }

    private func handleOpen(_ url: URL) {
        let source: ExternalOpenSource
        let rawPath: String?
        if url.isFileURL {
            source = .fileURL
            rawPath = url.path
        } else if url.scheme == "finderflow" {
            source = .finderFlowLink
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            rawPath = comps?.queryItems?
                .first(where: { $0.name == "path" })?.value
        } else {
            return
        }

        guard let rawPath, !rawPath.isEmpty else { return }
        let fileURL = URL(fileURLWithPath: rawPath)
        // Resolve links before deciding, so a link to an app bundle is not treated as a folder.
        let resolved = fileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) else { return }

        let facts = ExternalOpenFacts(
            isDirectory: isDir.boolValue,
            isBrowsableFolder: FileItem.isBrowsableFolder(resolved),
            isMarkdown: resolved.pathExtension.lowercased() == "md",
            isEditableText: TextFileDetector.isEditableText(resolved)
        )
        let decision = externalOpenDecision(source: source, path: resolved.path, facts: facts)

        DispatchQueue.main.async {
            switch decision {
            case .navigate(let path):
                let folder = URL(fileURLWithPath: path)
                AppDelegate.pendingNavigationURL = folder
                NotificationCenter.default.post(name: .navigateToPath, object: folder)
                NSApp.activate(ignoringOtherApps: true)
            case .launchPackage(let path):
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
                NSApp.activate(ignoringOtherApps: true)
            case .openMarkdown(let path):
                MarkdownWindowManager.shared.open(URL(fileURLWithPath: path))
                NSApp.activate(ignoringOtherApps: true)
            case .openText(let path):
                EditorWindowManager.shared.open(URL(fileURLWithPath: path))
                NSApp.activate(ignoringOtherApps: true)
            case .revealParent(let path):
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
                AppDelegate.pendingNavigationURL = parent
                NotificationCenter.default.post(name: .navigateToPath, object: parent)
                NSApp.activate(ignoringOtherApps: true)
            case .ignore:
                break
            }
        }
    }
}

struct FinderFlowCommands: Commands {
    @AppStorage("launchAtLogin") private var launchAtLogin = false

    var body: some Commands {
        CommandMenu("FinderFlow") {
            Button("New Folder") {
                NotificationCenter.default.post(name: .createNewFolder, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .option])

            Button("Toggle Hidden Files") {
                NotificationCenter.default.post(name: .toggleHiddenFiles, object: nil)
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])

            Divider()

            Button("Check for Updates…") {
                UpdateManager.shared.checkForUpdates()
            }

            Divider()

            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    launchAtLogin = newValue
                    if #available(macOS 13.0, *) {
                        if newValue {
                            try? SMAppService.mainApp.register()
                        } else {
                            try? SMAppService.mainApp.unregister()
                        }
                    }
                }
            ))
        }
    }
}

extension Notification.Name {
    static let createNewFolder   = Notification.Name("createNewFolder")
    static let createNewFile     = Notification.Name("createNewFile")
    static let toggleHiddenFiles = Notification.Name("toggleHiddenFiles")
    static let navigateToPath    = Notification.Name("navigateToPath")
    /// object: URL to show in a brand-new window.
    static let openFolderInNewWindow = Notification.Name("openFolderInNewWindow")
    static let refreshDirectory  = Notification.Name("FinderFlow.refreshDirectory")
    static let ffCopyPathFeedback = Notification.Name("FF.copyPathFeedback")
}
