import SwiftUI
import AppKit

// MARK: - Item hit testing registry
//
// Why this exists:
// SwiftUI Table / LazyVGrid / List do not expose "which item is under the pointer"
// in a uniform way. A SwiftUI gesture-based selection also forces the system to wait
// for the double-click window (~300ms) before reporting a single click, which makes
// clicking feel laggy.
//
// Instead every item cell registers a transparent NSView (ItemHitView) that knows its
// own item id. A single NSEvent monitor then resolves the clicked item geometrically
// from the live view geometry, so selection feedback happens on mouse-DOWN with no
// gesture disambiguation delay — and the exact same code works for list, grouped
// list, and icon views.

final class ItemHitView: NSView {
    var itemID: String?

    /// Never intercept clicks / drags / hover; the registry only reads geometry.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            ItemHitRegistry.shared.unregister(self)
        } else {
            ItemHitRegistry.shared.register(self)
        }
    }
}

final class ItemHitRegistry {
    static let shared = ItemHitRegistry()

    private struct Entry {
        weak var view: ItemHitView?
    }

    private var entries: [Entry] = []
    private var lastCompact = 0

    func register(_ view: ItemHitView) {
        entries.removeAll { $0.view === view || $0.view == nil }
        entries.append(Entry(view: view))
    }

    func unregister(_ view: ItemHitView) {
        entries.removeAll { $0.view === view || $0.view == nil }
    }

    func removeAll() {
        entries.removeAll()
    }

    /// Resolve which item sits under a window-space point.
    /// Picks the smallest matching frame so nested cells win over containers.
    func itemID(atWindowPoint point: NSPoint) -> String? {
        compactIfNeeded()

        var bestID: String?
        var bestArea = CGFloat.greatestFiniteMagnitude

        for entry in entries {
            guard let view = entry.view,
                  let id = view.itemID,
                  let window = view.window,
                  window.isVisible else {
                continue
            }
            let localPoint = view.convert(point, from: nil)
            guard view.bounds.contains(localPoint) else { continue }
            let area = view.bounds.width * view.bounds.height
            if area > 0 && area < bestArea {
                bestArea = area
                bestID = id
            }
        }
        return bestID
    }

    private func compactIfNeeded() {
        lastCompact += 1
        guard lastCompact % 32 == 0 else { return }
        entries.removeAll { $0.view == nil }
    }
}

/// Transparent registration layer used behind an item cell.
struct ItemHitArea: NSViewRepresentable {
    let itemID: String

    func makeNSView(context: Context) -> ItemHitView {
        let v = ItemHitView()
        v.itemID = itemID
        return v
    }

    func updateNSView(_ view: ItemHitView, context: Context) {
        view.itemID = itemID
    }
}

extension View {
    /// Register this cell's geometry so the global click router can resolve it.
    func itemHitArea(_ itemID: String) -> some View {
        background(ItemHitArea(itemID: itemID))
    }
}

// MARK: - Browser area marker
//
// Marks the region that counts as "the file listing". Clicks inside it on an empty
// spot clear the selection; clicks outside it (sidebar, toolbar, path bar) are
// ignored by the router.

final class BrowserAreaView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

struct BrowserAreaMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> BrowserAreaView { BrowserAreaView() }
    func updateNSView(_ view: BrowserAreaView, context: Context) {}
}

extension View {
    func browserAreaMarker() -> some View { background(BrowserAreaMarker()) }
}

enum BrowserAreaLocator {
    /// True when the window-space point lies inside any registered browser area.
    static func contains(_ point: NSPoint, in window: NSWindow?) -> Bool {
        guard let window else { return false }
        var found = false
        func walk(_ view: NSView) {
            if found { return }
            if let area = view as? BrowserAreaView {
                let local = area.convert(point, from: nil)
                if area.bounds.contains(local) { found = true; return }
            }
            for sub in view.subviews { walk(sub) }
        }
        if let root = window.contentView { walk(root) }
        return found
    }
}
