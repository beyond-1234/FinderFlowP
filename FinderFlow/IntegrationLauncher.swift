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
    static func open(folder: URL, using resolved: ResolvedIntegration) {
        switch resolved.integration.kind {
        case .editor:
            if let app = resolved.appURL {
                NSWorkspace.shared.open([folder],
                                        withApplicationAt: app,
                                        configuration: NSWorkspace.OpenConfiguration())
            }

        case .terminal:
            openTerminal(folder: folder, resolved: resolved)
        }
    }

    // MARK: Terminals

    private static func openTerminal(folder: URL, resolved: ResolvedIntegration) {
        // CLI terminals that accept their own start directory: kitty, Alacritty,
        // WezTerm. Launch them through LaunchServices so the app behaves as if started
        // from Finder, with the directory passed as an argument.
        let args = resolved.integration.cliArgs
        if !args.isEmpty, resolved.cliPath != nil {
            let bundleID = resolved.appURL.flatMap(bundleIdentifier)
            launchAppWithArguments(bundleID: bundleID,
                                   appURL: resolved.appURL,
                                   arguments: args + [folder.path])
            return
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

    /// Launch a GUI-capable CLI (kitty, WezTerm) through LaunchServices so the app gets
    /// a proper session, activation and Dock presence.
    ///
    /// Running the binary with `Process` directly leaves the app without an activation
    /// policy in some cases and swallows failures silently. `open -a <app> --args …`
    /// keeps the arguments but goes through the same path as launching from Finder.
    private static func launchAppWithArguments(bundleID: String?, appURL: URL?,
                                               arguments: [String]) {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")

        // Prefer the app path: `-b` requires the bundle ID to be registered with
        // LaunchServices, which fails for apps that were never launched from Finder.
        if let appURL {
            open.arguments = ["-a", appURL.path, "--args"] + arguments
        } else if let bundleID {
            open.arguments = ["-b", bundleID, "--args"] + arguments
        } else {
            return
        }

        let stderrPipe = Pipe()
        open.standardError = stderrPipe
        do {
            try open.run()
            open.waitUntilExit()
        } catch {
            NSLog("FinderFlowP: failed to launch terminal: \(error)")
            return
        }

        if open.terminationStatus != 0 {
            let message = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
            NSLog("FinderFlowP: terminal launch exited \(open.terminationStatus): \(message)")
        }
    }

    private static func runAppleScript(_ source: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        try? p.run()
    }
}

extension Notification.Name {
    /// Posted when a CLI action could not be run in a scriptable terminal;
    /// carries the command the user should paste into the window that opened.
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
