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
// The router resolves the item under the pointer geometrically on mouse-DOWN, applies
// the selection to the backing NSTableView *synchronously* where one exists (so the
// highlight is painted in the very same display pass, with no two-stage flash), and
// publishes the same selection for SwiftUI to adopt.

final class MouseRouter: ObservableObject {

    /// Latest selection the router wants the browser to show.
    @Published var selectionIntent: Set<String>?
    /// Item the router wants opened (middle click).
    @Published var openIntent: String?

    private var monitor: Any?
    /// The window this router serves, used to scope highlight repaints.
    private weak var activeWindow: NSWindow?
    private var orderedIDs: [String] = []
    private var currentSelection: Set<String> = []
    private var lastAnchorID: String?


    /// Bind the router to a window. Highlight repaints are scoped to it so a second
    /// window's cells are never touched.
    func bind(to window: NSWindow?) {
        activeWindow = window
    }

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
        if selectionIntent == ids { selectionIntent = nil }
        currentSelection = ids
        if ids.count == 1 { lastAnchorID = ids.first }
        // Keep the AppKit-painted highlights in step when the selection changes from
        // anywhere other than the mouse router (keyboard, Cmd+A, reveal, undo…).
        ItemHitRegistry.shared.applyHighlight(ids, in: activeWindow)
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
        let tableHit = resolveTable(at: event.locationInWindow, window: window)

        // The table's own keyboard focus ring is what made right-click flash a blue
        // border first and only then fill the row. Suppress it once per table: the
        // selection fill is the single, native-looking highlight.
        if let table = tableHit?.table, table.focusRingType != .none {
            table.focusRingType = .none
        }

        let hitID = ItemHitRegistry.shared.itemID(atWindowPoint: event.locationInWindow,
                                                  in: event.window)
            ?? tableHit?.id

        switch event.type {
        case .rightMouseDown:
            // Select the target BEFORE the menu is built so the menu actions and the
            // visible highlight always agree.
            if let id = hitID {
                if !currentSelection.contains(id) {
                    applySynchronously([id], table: tableHit)
                }
            }
            return event

        case .otherMouseDown:
            guard event.buttonNumber == 2 else { return event }
            if let id = hitID {
                applySynchronously([id], table: tableHit)
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
                    applySynchronously(next, table: tableHit)
                    return nil
                }
                if shift {
                    extendSelection(to: id, table: tableHit)
                    return nil
                }
                if currentSelection != [id] {
                    applySynchronously([id], table: tableHit)
                }
                return event   // let the row handle drag / double-click / rename
            }

            // Empty space inside the listing clears selection.
            if !command && !shift, !currentSelection.isEmpty {
                applySynchronously([], table: tableHit)
            }
            return event

        default:
            return event
        }
    }

    // MARK: - AppKit-backed instant selection

    private struct TableHit {
        let table: NSTableView
        let row: Int
        let id: String?
    }

    private func resolveTable(at windowPoint: NSPoint, window: NSWindow?) -> TableHit? {
        guard let window,
              let hit = window.contentView?.hitTest(windowPoint) else { return nil }

        var candidate: NSView? = hit
        while let view = candidate {
            if let table = view as? NSTableView {
                let local = table.convert(windowPoint, from: nil)
                let row = table.row(at: local)
                let id: String? = (row >= 0 && row < orderedIDs.count) ? orderedIDs[row] : nil
                return TableHit(table: table, row: row, id: id)
            }
            candidate = view.superview
        }
        return nil
    }

    /// Apply both the AppKit highlight and the SwiftUI intent in the same event, so
    /// there is exactly one visual transition instead of a border-then-fill flash.
    private func applySynchronously(_ ids: Set<String>, table: TableHit?) {
        currentSelection = ids
        if ids.count == 1 { lastAnchorID = ids.first }

        if let tableHit = table {
            let table = tableHit.table
            let indexes = IndexSet(ids.compactMap { orderedIDs.firstIndex(of: $0) })
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            // Paint the highlight now; while an NSMenu tracks, the SwiftUI display link
            // is paused, so anything deferred here would appear late.
            table.window?.displayIfNeeded()
        } else {
            // Icon view: no NSTableView, so the cells draw the highlight themselves.
            ItemHitRegistry.shared.applyHighlight(ids, in: activeWindow)
        }

        selectionIntent = ids
    }

    private func extendSelection(to id: String, table: TableHit?) {
        let anchor = lastAnchorID ?? currentSelection.first ?? id
        guard let start = orderedIDs.firstIndex(of: anchor),
              let end = orderedIDs.firstIndex(of: id) else {
            applySynchronously([id], table: table)
            return
        }
        let range = start <= end ? start...end : end...start
        applySynchronously(Set(range.map { orderedIDs[$0] }), table: table)
    }
}
