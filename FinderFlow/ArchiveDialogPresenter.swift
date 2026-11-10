import SwiftUI
import AppKit

// MARK: - Archive dialog presenter
//
// SwiftUI can't attach a sheet to a context menu, so the dialog is shown by a tiny
// AppKit-hosted window. One presenter instance keeps it out of the view tree.

final class ArchiveDialogPresenter {
    static let shared = ArchiveDialogPresenter()

    private var window: NSWindow?
    private var retained: AnyObject?

    private init() {}

    func present(urls: [URL],
                 fileOps: FileOperationsService,
                 reload: @escaping () -> Void) {
        guard !urls.isEmpty else { return }
        window?.close()

        let dialog = CompressDialog(urls: urls) { tool, format, level, destination in
            fileOps.compress(urls,
                             to: destination,
                             using: tool,
                             format: format,
                             level: level,
                             reload: reload)
            self.window?.close()
            self.window = nil
            self.retained = nil
        }

        let hosting = NSHostingController(rootView: dialog)
        let panel = NSWindow(contentViewController: hosting)
        panel.title = "Create Archive"
        panel.styleMask = [.titled, .closable]
        panel.isReleasedWhenClosed = false
        panel.center()

        self.window = panel
        self.retained = hosting
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
