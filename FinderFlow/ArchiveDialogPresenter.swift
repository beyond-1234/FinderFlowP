import SwiftUI
import AppKit

// MARK: - Archive dialog presenter
//
// SwiftUI can't attach a sheet to a context menu, so the dialog is shown by a small
// AppKit-hosted window. The window is the source of truth for closing: the dialog's
// own @Environment(\.dismiss) does nothing outside a sheet/popover context, which is
// why Cancel used to be dead.

final class ArchiveDialogPresenter: NSObject, NSWindowDelegate {
    static let shared = ArchiveDialogPresenter()

    private var window: NSWindow?
    private var hosting: NSHostingController<CompressDialog>?

    private override init() { super.init() }

    func present(urls: [URL],
                 fileOps: FileOperationsService,
                 reload: @escaping () -> Void) {
        guard !urls.isEmpty else { return }
        close()

        let dialog = CompressDialog(
            urls: urls,
            onConfirm: { tool, format, level, destination in
                fileOps.compress(urls,
                                 to: destination,
                                 using: tool,
                                 format: format,
                                 level: level,
                                 reload: reload)
            },
            onOpenInApp: { tool in
                ArchiveRunner.openInOwnUI(tool: tool, urls: urls)
            },
            onClose: { [weak self] in self?.close() }
        )

        let controller = NSHostingController(rootView: dialog)
        let panel = NSWindow(contentViewController: controller)
        panel.title = "Create Archive"
        panel.styleMask = [.titled, .closable]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center()

        window = panel
        hosting = controller
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.delegate = nil
        window?.orderOut(nil)
        window?.close()
        window = nil
        hosting = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        hosting = nil
    }
}
