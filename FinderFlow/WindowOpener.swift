import Foundation
import AppKit
import SwiftUI

// MARK: - Opening a folder in a new FinderFlow window
//
// `NSWorkspace.shared.open(folderURL)` hands the folder to the *system's default folder
// handler*. Unless the user made FinderFlow that handler, LaunchServices opens Finder —
// which is exactly the bug this fixes.
//
// The app uses a URL-keyed `WindowGroup`, so presenting a new scene is a matter of
// asking SwiftUI to open a window for that URL value. `OpenWindowAction` is only
// available inside a view's environment, so views call `openNewWindow(_:)` from a
// context that has it; the helper below keeps the fallback path for the delegate.

enum WindowOpener {

    /// Called by views that have an `openWindow` action available.
    static func open(_ url: URL, using openWindow: OpenWindowAction) {
        openWindow(value: url)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Fallback when no SwiftUI action is reachable (e.g. from AppKit code):
    /// ask the running app to show a new window for this folder.
    @MainActor
    static func openWithoutAction(_ url: URL) {
        AppDelegate.requestNewWindow(for: url)
    }
}

/// A view modifier that gives any subview the ability to open folders in new windows
/// without threading `OpenWindowAction` through every call site.
struct NewWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .environment(\.winfilesOpenWindow, OpenWindowBox { url in
                WindowOpener.open(url, using: openWindow)
            })
    }
}

extension View {
    func providingNewWindowOpener() -> some View {
        modifier(NewWindowOpener())
    }
}

// MARK: - Environment plumbing

final class OpenWindowBox {
    let open: (URL) -> Void
    init(_ open: @escaping (URL) -> Void) { self.open = open }
}

private struct WinFilesOpenWindowKey: EnvironmentKey {
    static let defaultValue = OpenWindowBox { url in
        // No SwiftUI action available: fall back to the delegate path on the main queue.
        DispatchQueue.main.async {
            AppDelegate.requestNewWindow(for: url)
        }
    }
}

extension EnvironmentValues {
    var winfilesOpenWindow: OpenWindowBox {
        get { self[WinFilesOpenWindowKey.self] }
        set { self[WinFilesOpenWindowKey.self] = newValue }
    }
}
