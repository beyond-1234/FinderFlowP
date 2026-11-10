import Foundation
import AppKit
import SwiftUI

// MARK: - Opening a folder in a new FinderFlow window
//
// `NSWorkspace.shared.open(folderURL)` hands the folder to the system's default folder
// handler — i.e. Finder unless the user changed it. The app instead uses a URL-keyed
// `WindowGroup`, so a new window is requested through SwiftUI's `openWindow` action.
//
// That action only exists in a view's environment, and an environment value injected
// by a modifier applied to a view is *not* visible to that same view — only to its
// descendants. The previous wrapper therefore handed `ContentView` the default
// (no-op) implementation, which is why "Open in New Window" did nothing.
//
// The fix: `ContentView` reads `openWindow` itself and passes the action down.

enum WindowOpener {

    /// Present `url` in its own window.
    static func open(_ url: URL, using openWindow: OpenWindowAction) {
        openWindow(value: url)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Fallback for AppKit-side callers with no SwiftUI action at hand.
    @MainActor
    static func openWithoutAction(_ url: URL) {
        AppDelegate.requestNewWindow(for: url)
    }
}

/// Boxed `openWindow` action so it can travel through the custom environment entry
/// that subviews read via `@Environment(\.ffOpenWindow)`.
final class OpenWindowBox {
    let open: (URL) -> Void
    init(_ open: @escaping (URL) -> Void) { self.open = open }
}

private struct FFOpenWindowKey: EnvironmentKey {
    static let defaultValue: OpenWindowBox? = nil
}

extension EnvironmentValues {
    /// Nil when no SwiftUI action has been supplied; callers fall back to the delegate.
    var ffOpenWindow: OpenWindowBox? {
        get { self[FFOpenWindowKey.self] }
        set { self[FFOpenWindowKey.self] = newValue }
    }
}

/// Applies the environment entry to a subtree. Must be placed *inside* ContentView
/// (or on a child), because a modifier cannot supply values to the view it wraps.
struct ProvidingOpenWindow: ViewModifier {
    let box: OpenWindowBox

    func body(content: Content) -> some View {
        content.environment(\.ffOpenWindow, box)
    }
}

extension View {
    func providingOpenWindow(_ box: OpenWindowBox) -> some View {
        modifier(ProvidingOpenWindow(box: box))
    }
}
