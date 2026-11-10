import SwiftUI
import AppKit

// MARK: - Reset a stuck column-resize cursor
//
// NSTableHeaderView sets `NSCursor.resizeLeftRight` when the pointer is over a column
// divider, but nothing resets it when the pointer moves down into the rows — the cursor
// stays a resize arrow over the file list until you leave the window.
//
// This installs a mouse-moved tracking area on top of the table. It only ever calls
// NSCursor.set(), so unlike the old SwiftUI `.onContinuousHover` approach it never
// invalidates a view or triggers a re-render (that version caused the click latency we
// had to remove).
//
// The header is left untouched: while the pointer is over an NSTableHeaderView the
// resize cursor must stay so dividers remain draggable.

struct RowCursorEnforcer: NSViewRepresentable {
    func makeNSView(context: Context) -> EnforcerView { EnforcerView() }
    func updateNSView(_ view: EnforcerView, context: Context) {}
}

final class EnforcerView: NSView {
    private var tracking: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard !bounds.isEmpty else { tracking = nil; return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        guard let window = event.window ?? self.window,
              let hit = window.contentView?.hitTest(event.locationInWindow) else { return }

        // Pointer over a column header (or its divider): leave the cursor alone so the
        // resize affordance keeps working.
        if isInsideHeader(hit) { return }

        // Pointer over the row area: the cursor must be the plain arrow.
        if NSCursor.current != NSCursor.arrow {
            NSCursor.arrow.set()
        }
    }

    private func isInsideHeader(_ view: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current is NSTableHeaderView { return true }
            candidate = current.superview
        }
        return false
    }
}
