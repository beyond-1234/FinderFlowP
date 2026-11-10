import SwiftUI
import AppKit

// MARK: - Control + scroll zoom for icon view
//
// Finder zooms its icon view with ⌃-scroll (and ⌘+ / ⌘−). A SwiftUI ScrollView does
// not forward scroll events, so this attaches an AppKit view that watches the scroll
// wheel and only consumes it when Control is held — plain scrolling keeps working.

extension Notification.Name {
    /// object: Double zoom step (0.25 = +25%).
    static let winfilesZoomIcons = Notification.Name("winfilesZoomIcons")
}

struct IconZoomScrollCatcher: NSViewRepresentable {
    let onZoom: (Double) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onZoom = onZoom
        return v
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onZoom = onZoom
    }

    final class CatcherView: NSView {
        var onZoom: ((Double) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { removeMonitor() } else { installMonitor() }
        }

        private func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      event.modifierFlags.contains(.control),
                      self.window?.isKeyWindow == true,
                      let win = self.window,
                      self.boundsInWindow.contains(win.mouseLocationOutsideOfEventStream)
                        || event.window === win else {
                    return event
                }
                // Trackpad reports precise deltas; a mouse wheel reports lines.
                let raw = event.hasPreciseScrollingDeltas
                    ? event.scrollingDeltaY
                    : event.scrollingDeltaY * 8
                guard abs(raw) > 0.5 else { return nil }
                self.onZoom?(Double(raw) / 400.0)
                return nil
            }
        }

        private func removeMonitor() {
            if let m = monitor { NSEvent.removeMonitor(m) }
            monitor = nil
        }

        private var boundsInWindow: NSRect {
            convert(bounds, to: nil)
        }
    }
}
