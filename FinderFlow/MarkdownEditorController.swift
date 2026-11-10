import Foundation
import AppKit
import Combine

/// Shared handle so the format toolbar can reach the live `NSTextView`.
///
/// Not @MainActor: every entry point is already main-thread (SwiftUI views, and
/// NotificationCenter observers registered with `queue: .main`). Annotating the class
/// made those @Sendable observer closures unprovable under Swift 5.8.
final class MarkdownEditorController: ObservableObject {
    weak var textView: NSTextView?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoObserver: NSObjectProtocol?
    private var redoObserver: NSObjectProtocol?

    func attach(_ tv: NSTextView) {
        textView = tv
        refreshUndoState()
        let nc = NotificationCenter.default
        if let undoObserver { nc.removeObserver(undoObserver) }
        if let redoObserver { nc.removeObserver(redoObserver) }
        func observe(_ name: Notification.Name, object: Any?) -> NSObjectProtocol {
            nc.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                self?.refreshUndoState()
            }
        }

        undoObserver = observe(.NSUndoManagerDidCloseUndoGroup, object: tv.undoManager)
        redoObserver = observe(.NSUndoManagerDidUndoChange,     object: tv.undoManager)
        _ = observe(.NSUndoManagerDidRedoChange,               object: tv.undoManager)
        _ = observe(NSText.didChangeNotification,              object: tv)
    }

    func refreshUndoState() {
        canUndo = textView?.undoManager?.canUndo ?? false
        canRedo = textView?.undoManager?.canRedo ?? false
    }

    func run(_ action: (NSTextView) -> Void) {
        guard let tv = textView else { return }
        action(tv)
        refreshUndoState()
    }
}
