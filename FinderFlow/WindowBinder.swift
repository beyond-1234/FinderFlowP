import SwiftUI
import AppKit

// MARK: - Resolve the hosting window
//
// SwiftUI exposes no direct access to the NSWindow a view is rendered in. Several
// features need it: the mouse router scopes highlight repaints to its own window, and
// tooltips position themselves relative to the pointer inside it.

struct WindowBinder: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> BinderView {
        let view = BinderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: BinderView, context: Context) {
        view.onWindow = onWindow
        view.report()
    }

    final class BinderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        private weak var reported: NSWindow?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        func report() {
            guard reported !== window else { return }
            reported = window
            onWindow?(window)
        }
    }
}
