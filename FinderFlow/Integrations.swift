import SwiftUI
import AppKit

// MARK: - Integrations: dynamic detection + manual override
//
// Everything the toolbar can launch lives here. Two rules:
//   1. A tool only gets a button when it is actually usable right now — the app
//      bundle resolves through LaunchServices, or the CLI resolves through the
//      user's *login shell* PATH (so nvm / homebrew / ~/.local/bin count).
//   2. The user can always override the result by hand in Settings; a manual
//      choice wins over detection and pins the button in place.
//
// Detection runs on every window appearance (cheap, cached per launch) so a tool
// installed later shows up without a restart.

enum IntegrationKind: String, Codable, CaseIterable, Identifiable {
    case terminal
    case editor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: return "Terminals"
        case .editor:   return "Code editors"
        }
    }
}

/// One launchable integration.
struct Integration: Identifiable, Hashable {
    let id: String                 // stable key, e.g. "editor.vscode"
    let kind: IntegrationKind
    let name: String               // button title
    let symbol: String             // SF Symbol fallback when no app icon
    /// Bundle identifiers accepted, in priority order.
    let bundleIDs: [String]
    /// Well-known app paths, in priority order.
    let appPaths: [String]
    /// CLI name to look up on PATH (used by terminals).
    let cli: String?
    /// Extra args for the CLI when launching it inside a folder.
    let cliArgs: [String]

    init(id: String,
         kind: IntegrationKind,
         name: String,
         symbol: String,
         bundleIDs: [String] = [],
         appPaths: [String] = [],
         cli: String? = nil,
         cliArgs: [String] = []) {
        self.id = id
        self.kind = kind
        self.name = name
        self.symbol = symbol
        self.bundleIDs = bundleIDs
        self.appPaths = appPaths
        self.cli = cli
        self.cliArgs = cliArgs
    }

    static func == (lhs: Integration, rhs: Integration) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A resolved integration, ready to launch.
struct ResolvedIntegration: Identifiable {
    let integration: Integration
    let appURL: URL?
    let cliPath: String?
    let icon: NSImage
    let isManual: Bool

    var id: String { integration.id }
    var canLaunch: Bool { appURL != nil || cliPath != nil }
}

// MARK: - Catalog

enum IntegrationCatalog {

    static let all: [Integration] = terminals + editors

    static let terminals: [Integration] = [
        Integration(id: "terminal.apple", kind: .terminal, name: "Terminal",
                    symbol: "terminal",
                    bundleIDs: ["com.apple.Terminal"],
                    appPaths: ["/System/Applications/Utilities/Terminal.app"]),
        Integration(id: "terminal.iterm", kind: .terminal, name: "iTerm2",
                    symbol: "terminal",
                    bundleIDs: ["com.googlecode.iterm2"],
                    appPaths: ["/Applications/iTerm.app"]),
        Integration(id: "terminal.kitty", kind: .terminal, name: "kitty",
                    symbol: "terminal",
                    bundleIDs: ["net.kovidgoyal.kitty"],
                    appPaths: ["/Applications/kitty.app"],
                    cli: "kitty", cliArgs: ["--directory"]),
        Integration(id: "terminal.ghostty", kind: .terminal, name: "Ghostty",
                    symbol: "terminal",
                    bundleIDs: ["com.mitchellh.ghostty"],
                    appPaths: ["/Applications/Ghostty.app"]),
        Integration(id: "terminal.warp", kind: .terminal, name: "Warp",
                    symbol: "terminal",
                    bundleIDs: ["dev.warp.Warp-Stable", "dev.warp.Warp"],
                    appPaths: ["/Applications/Warp.app"]),
        Integration(id: "terminal.alacritty", kind: .terminal, name: "Alacritty",
                    symbol: "terminal",
                    bundleIDs: ["org.alacritty"],
                    appPaths: ["/Applications/Alacritty.app"],
                    cli: "alacritty", cliArgs: ["--working-directory"]),
        Integration(id: "terminal.wezterm", kind: .terminal, name: "WezTerm",
                    symbol: "terminal",
                    bundleIDs: ["com.github.wez.wezterm"],
                    appPaths: ["/Applications/WezTerm.app"],
                    cli: "wezterm", cliArgs: ["start", "--cwd"]),
    ]

    static let editors: [Integration] = [
        Integration(id: "editor.vscode", kind: .editor, name: "VS Code",
                    symbol: "chevron.left.forwardslash.chevron.right",
                    bundleIDs: ["com.microsoft.VSCode"],
                    appPaths: ["/Applications/Visual Studio Code.app"]),
        Integration(id: "editor.cursor", kind: .editor, name: "Cursor",
                    symbol: "cursorarrow.rays",
                    bundleIDs: ["com.todesktop.230313mzl4w4u92", "com.cursor.macos"],
                    appPaths: ["/Applications/Cursor.app"]),
        Integration(id: "editor.zed", kind: .editor, name: "Zed",
                    symbol: "z.square",
                    bundleIDs: ["dev.zed.Zed"],
                    appPaths: ["/Applications/Zed.app"]),
        Integration(id: "editor.sublime", kind: .editor, name: "Sublime Text",
                    symbol: "s.square",
                    bundleIDs: ["com.sublimetext.4", "com.sublimetext.3"],
                    appPaths: ["/Applications/Sublime Text.app"]),
        Integration(id: "editor.nova", kind: .editor, name: "Nova",
                    symbol: "n.square",
                    bundleIDs: ["com.panic.Nova"],
                    appPaths: ["/Applications/Nova.app"]),
        Integration(id: "editor.bbedit", kind: .editor, name: "BBEdit",
                    symbol: "b.square",
                    bundleIDs: ["com.barebones.bbedit"],
                    appPaths: ["/Applications/BBEdit.app"]),
    ]
}

// MARK: - Resolver

final class IntegrationStore: ObservableObject {
    static let shared = IntegrationStore()

    /// Resolved entries, already filtered to what can actually launch.
    @Published private(set) var resolved: [ResolvedIntegration] = []

    /// User overrides: integration id -> app path chosen by hand.
    @Published private(set) var manualPaths: [String: String] = [:]

    /// Which terminal the plain "Open in Terminal" action uses.
    @Published var defaultTerminalID: String {
        didSet { UserDefaults.standard.set(defaultTerminalID, forKey: Self.defaultTerminalKey) }
    }

    private static let manualKey = "winfilesIntegrationOverrides"
    private static let defaultTerminalKey = "winfilesDefaultTerminalID"
    private var hasResolvedThisLaunch = false

    private init() {
        manualPaths = UserDefaults.standard.dictionary(forKey: Self.manualKey) as? [String: String] ?? [:]
        defaultTerminalID = UserDefaults.standard.string(forKey: Self.defaultTerminalKey)
            ?? "terminal.apple"
    }

    /// The terminal used by generic "Open in Terminal" actions.
    var preferredTerminal: ResolvedIntegration? {
        item(id: defaultTerminalID) ?? items(of: .terminal).first
    }

    // MARK: Manual configuration

    func setManualPath(_ path: String?, for id: String) {
        if let path {
            manualPaths[id] = path
        } else {
            manualPaths.removeValue(forKey: id)
        }
        UserDefaults.standard.set(manualPaths, forKey: Self.manualKey)
        refresh(force: true)
    }

    func manualPath(for id: String) -> String? { manualPaths[id] }

    /// Let the user pick an .app for one integration slot.
    func chooseApp(for integration: Integration) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose the app for “\(integration.name)”"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        setManualPath(url.path, for: integration.id)
        return true
    }

    // MARK: Resolution

    /// Resolve everything once per launch, then only when asked (settings changes).
    func resolveIfNeeded() {
        guard !hasResolvedThisLaunch else { return }
        hasResolvedThisLaunch = true
        refresh(force: true)
    }

    func refresh(force: Bool = false) {
        if force { hasResolvedThisLaunch = true }

        DispatchQueue.global(qos: .userInitiated).async {
            // Resolve the login-shell PATH once; multiple tools need it.
            let shellPath = Self.loginShellPATH()

            var byKind: [IntegrationKind: [ResolvedIntegration]] = [:]

            for integration in IntegrationCatalog.all {
                if let manual = self.manualPaths[integration.id] {
                    // A manual choice always wins and always shows.
                    guard FileManager.default.fileExists(atPath: manual) else { continue }
                    let url = URL(fileURLWithPath: manual)
                    byKind[integration.kind, default: []].append(
                        ResolvedIntegration(integration: integration,
                                            appURL: url,
                                            cliPath: nil,
                                            icon: NSWorkspace.shared.icon(forFile: manual),
                                            isManual: true))
                    continue
                }

                let appURL = Self.resolveApp(integration)
                let cli = integration.cli.flatMap { Self.resolveCLI($0, shellPath: shellPath) }

                guard appURL != nil || cli != nil else { continue }

                let icon: NSImage
                if let appURL {
                    icon = NSWorkspace.shared.icon(forFile: appURL.path)
                } else {
                    icon = NSImage(systemSymbolName: integration.symbol,
                                   accessibilityDescription: integration.name)
                        ?? NSImage()
                }

                byKind[integration.kind, default: []].append(
                    ResolvedIntegration(integration: integration,
                                        appURL: appURL,
                                        cliPath: cli,
                                        icon: icon,
                                        isManual: false))
            }

            var ordered: [ResolvedIntegration] = []
            for kind in IntegrationKind.allCases {
                ordered.append(contentsOf: byKind[kind] ?? [])
            }

            DispatchQueue.main.async {
                self.resolved = ordered
            }
        }
    }

    func items(of kind: IntegrationKind) -> [ResolvedIntegration] {
        resolved.filter { $0.integration.kind == kind }
    }

    func item(id: String) -> ResolvedIntegration? {
        resolved.first { $0.integration.id == id }
    }

    // MARK: Detection primitives

    static func resolveApp(_ integration: Integration) -> URL? {
        for bid in integration.bundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                return url
            }
        }
        for path in integration.appPaths where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Resolve a CLI the way the user's shell would: known install dirs first
    /// (fast, no subprocess), then a login-shell `which` so nvm / asdf / poetry
    /// managed binaries are found too.
    static func resolveCLI(_ name: String, shellPath: String?) -> String? {
        let home = NSHomeDirectory()
        let dirs = [
            "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/.local/bin", "\(home)/bin",
            "\(home)/.cargo/bin", "\(home)/.bun/bin",
            "\(home)/.volta/bin", "\(home)/.nix-profile/bin",
            "\(home)/.local/share/mise/shims",
        ]
        for dir in dirs {
            let p = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }

        // Fall back to PATH from a login shell, then probe it directly.
        if let shellPath {
            for dir in shellPath.split(separator: ":") {
                let p = (String(dir) as NSString).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    private static var cachedShellPATH: String?

    static func loginShellPATH() -> String {
        if let cachedShellPATH { return cachedShellPATH }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        var result = ""
        if (try? p.run()) != nil {
            p.waitUntilExit()
            result = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        }
        if result.isEmpty {
            result = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        }
        cachedShellPATH = result
        return result
    }
}
