import SwiftUI
import AppKit

// MARK: - Unified mouse router
//
// One monitor for the whole window, shared by list / grouped list / icon views.
//
// Why not SwiftUI gestures:
//   * `.onTapGesture` + `.onTapGesture(count: 2)` forces a ~300ms double-click
//     disambiguation wait before a single click is reported -> visible lag.
//   * Right-click does not update the SwiftUI selection at all, so the context menu
//     acts on the item while the UI still highlights the previous one.
//   * Clicking empty space does not clear the selection.
//
// The router resolves the item under the pointer geometrically on mouse-DOWN and
// publishes an *intent*. The owning view applies it. Publishing (instead of calling a
// captured closure) keeps SwiftUI struct capture semantics out of the picture.

final class MouseRouter: ObservableObject {
    static let shared = MouseRouter()

    /// Latest selection the router wants the browser to show.
    @Published var selectionIntent: Set<String>?
    /// Item the router wants opened (middle click).
    @Published var openIntent: String?

    private var monitor: Any?
    private var orderedIDs: [String] = []
    private var currentSelection: Set<String> = []
    private var lastAnchorID: String?

    private init() {}

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    // MARK: - View-provided state

    func updateItems(_ files: [FileItem]) {
        orderedIDs = files.map(\.id)
        if let anchor = lastAnchorID, !orderedIDs.contains(anchor) {
            lastAnchorID = nil
        }
    }

    func syncSelection(_ ids: Set<String>) {
        // Ignore the echo of our own intent.
        if selectionIntent == ids {
            selectionIntent = nil
        }
        currentSelection = ids
        if ids.count == 1 { lastAnchorID = ids.first }
    }

    // MARK: - Event handling

    private func handle(_ event: NSEvent) -> NSEvent? {
        // Never interfere with text editing / inline rename.
        if let responder = event.window?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            return event
        }

        // Only route events landing inside a file listing area.
        guard BrowserAreaLocator.contains(event.locationInWindow, in: event.window) else {
            return event
        }

        let window = event.window
        let hitID = ItemHitRegistry.shared.itemID(atWindowPoint: event.locationInWindow)
            ?? tableRowFallback(at: event.locationInWindow, window: window)

        switch event.type {
        case .rightMouseDown:
            // Select the target BEFORE the menu is built so the menu actions and the
            // visible highlight always agree.
            if let id = hitID, !currentSelection.contains(id) {
                apply([id])
            }
            return event

        case .otherMouseDown:
            guard event.buttonNumber == 2 else { return event }
            if let id = hitID {
                apply([id])
                openIntent = id
                return nil
            }
            return event

        case .leftMouseDown:
            let shift = event.modifierFlags.contains(.shift)
            let command = event.modifierFlags.contains(.command)

            if let id = hitID {
                if command {
                    var next = currentSelection
                    if next.contains(id) { next.remove(id) } else { next.insert(id) }
                    apply(next)
                    return nil
                }
                if shift {
                    extendSelection(to: id)
                    return nil
                }
                if currentSelection != [id] {
                    apply([id])
                }
                return event   // let the row handle drag / double-click / rename
            }

            // Empty space inside the listing clears selection.
            if !command && !shift, !currentSelection.isEmpty {
                apply([])
            }
            return event

        default:
            return event
        }
    }

    private func apply(_ ids: Set<String>) {
        currentSelection = ids
        if ids.count == 1 { lastAnchorID = ids.first }
        selectionIntent = ids
    }

    // MARK: - NSTableView fallback
    //
    // SwiftUI `Table` is backed by NSTableView, which knows the row under the pointer
    // even before a cell has registered geometry.

    private func tableRowFallback(at windowPoint: NSPoint, window: NSWindow?) -> String? {
        guard let window,
              let hit = window.contentView?.hitTest(windowPoint) else { return nil }

        var candidate: NSView? = hit
        while let view = candidate {
            if let table = view as? NSTableView {
                let local = table.convert(windowPoint, from: nil)
                let row = table.row(at: local)
                guard row >= 0, row < orderedIDs.count else { return nil }
                return orderedIDs[row]
            }
            candidate = view.superview
        }
        return nil
    }

    private func extendSelection(to id: String) {
        let anchor = lastAnchorID ?? currentSelection.first ?? id
        guard let start = orderedIDs.firstIndex(of: anchor),
              let end = orderedIDs.firstIndex(of: id) else {
            apply([id])
            return
        }
        let range = start <= end ? start...end : end...start
        apply(Set(range.map { orderedIDs[$0] }))
    }
}
