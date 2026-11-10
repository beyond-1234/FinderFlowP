import SwiftUI
import AppKit

// MARK: - Launching resolved integrations
//
// One place that knows how to open a folder (or run a CLI) in whatever the user has
// configured, instead of the previous per-app special cases.

enum IntegrationLauncher {

    /// Open `folder` in the given integration.
    /// - App-based editors (VS Code, Cursor, …) get the folder handed to the app bundle.
    /// - CLI-capable terminals (kitty, alacritty, wezterm) get their native
    ///   "start in directory" flag.
    /// - Scriptable terminals (Terminal, iTerm2) get a `cd` command.
    /// - Agents run in the configured terminal inside the folder.
    static func open(folder: URL, using resolved: ResolvedIntegration) {
        let integration = resolved.integration

        switch integration.kind {
        case .editor:
            if let app = resolved.appURL {
                NSWorkspace.shared.open([folder],
                                        withApplicationAt: app,
                                        configuration: NSWorkspace.OpenConfiguration())
            }

        case .terminal:
            openTerminal(folder: folder, resolved: resolved)

        case .agent:
            runAgent(folder: folder, resolved: resolved)
        }
    }

    // MARK: Terminals

    private static func openTerminal(folder: URL, resolved: ResolvedIntegration) {
        // 1. CLI terminals that accept their own start directory.
        if let cli = resolved.cliPath {
            let args = resolved.integration.cliArgs
            if args.contains("start") {
                // WezTerm: `wezterm start --cwd <dir>`
                runProcess(cli, args + [folder.path])
                return
            }
            if !args.isEmpty {
                // kitty `--directory <dir>`, alacritty `--working-directory <dir>`
                runProcess(cli, args + [folder.path])
                return
            }
        }

        // 2. Scriptable terminals: drive them with AppleScript so we land in the folder.
        if let bundleID = resolved.appURL.flatMap(bundleIdentifier) {
            if bundleID == "com.apple.Terminal" {
                runAppleScript("""
                tell application "Terminal"
                    activate
                    do script "cd \(shellQuoted(folder.path))"
                end tell
                """)
                return
            }
            if bundleID == "com.googlecode.iterm2" {
                runAppleScript("""
                tell application "iTerm"
                    activate
                    if (count of windows) is 0 then
                        set w to create window with default profile
                        tell w
                            tell current session
                                write text "cd \(shellQuoted(folder.path))"
                            end tell
                        end tell
                    else
                        tell current window
                            create tab with default profile
                            tell current session
                                write text "cd \(shellQuoted(folder.path))"
                            end tell
                        end tell
                    end if
                end tell
                """)
                return
            }
        }

        // 3. Anything else: hand the folder to the app and let it decide.
        if let app = resolved.appURL {
            NSWorkspace.shared.open([folder],
                                    withApplicationAt: app,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Agents

    private static func runAgent(folder: URL, resolved: ResolvedIntegration) {
        guard let cli = resolved.cliPath else {
            // Desktop-only agent app: just open it at the folder.
            if let app = resolved.appURL {
                NSWorkspace.shared.open([folder],
                                        withApplicationAt: app,
                                        configuration: NSWorkspace.OpenConfiguration())
            }
            return
        }

        let args = resolved.integration.cliArgs.joined(separator: " ")
        let command = "cd \(shellQuoted(folder.path)) && \(shellQuoted(cli))"
            + (args.isEmpty ? "" : " \(args)")

        // Prefer a scriptable terminal so the command actually runs.
        if runCommandInScriptableTerminal(command) { return }

        // Otherwise launch the terminal in the folder and tell the user what to run.
        if let terminal = IntegrationStore.shared.items(of: .terminal).first {
            openTerminal(folder: folder, resolved: terminal)
        }
        NotificationCenter.default.post(
            name: .ffAgentCommandHint,
            object: nil,
            userInfo: ["command": command, "agent": resolved.integration.name]
        )
    }

    /// Returns true when a scriptable terminal accepted the command.
    @discardableResult
    private static func runCommandInScriptableTerminal(_ command: String) -> Bool {
        let preferred = UserDefaults.standard.string(forKey: "winfilesAgentTerminalID")

        // Only Terminal.app and iTerm2 can take a command via AppleScript.
        let candidates = ["terminal.apple", "terminal.iterm"]
        var ordered: [String] = []
        if let preferred, candidates.contains(preferred), let first = Optional(preferred) {
            ordered.append(first)
        }
        for id in candidates where !ordered.contains(id) {
            ordered.append(id)
        }

        for id in ordered {
            guard let terminal = IntegrationStore.shared.item(id: id) else { continue }
            guard let bundleID = terminal.appURL.flatMap(bundleIdentifier) else { continue }

            if bundleID == "com.apple.Terminal" {
                runAppleScript("""
                tell application "Terminal"
                    activate
                    do script \(appleScriptLiteral(command))
                end tell
                """)
                return true
            }
            if bundleID == "com.googlecode.iterm2" {
                runAppleScript("""
                tell application "iTerm"
                    activate
                    if (count of windows) is 0 then
                        set w to create window with default profile
                        tell w
                            tell current session
                                write text \(appleScriptLiteral(command))
                            end tell
                        end tell
                    else
                        tell current window
                            create tab with default profile
                            tell current session
                                write text \(appleScriptLiteral(command))
                            end tell
                        end tell
                    end if
                end tell
                """)
                return true
            }
        }
        return false
    }

    // MARK: Shell / AppleScript helpers

    private static func bundleIdentifier(of app: URL) -> String? {
        Bundle(url: app)?.bundleIdentifier
    }

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptLiteral(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        try? p.run()
    }

    private static func runAppleScript(_ source: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        try? p.run()
    }
}

extension Notification.Name {
    /// Posted when an agent CLI could not be run automatically; carries
    /// the command the user should paste into the terminal that just opened.
    static let ffAgentCommandHint = Notification.Name("ffAgentCommandHint")
}

/// Opens a folder in the user's preferred terminal, whatever it is.
/// Shared by every context menu and the toolbar.
@discardableResult
func openTerminalAt(_ folder: URL) -> Bool {
    guard let terminal = IntegrationStore.shared.preferredTerminal else {
        return false
    }
    IntegrationLauncher.open(folder: folder, using: terminal)
    return true
}
