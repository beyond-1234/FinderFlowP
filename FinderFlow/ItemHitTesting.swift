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
// Every item cell registers a transparent NSView (ItemHitView) that knows its own
// item id. A single NSEvent monitor resolves the clicked item geometrically from live
// view geometry, so selection feedback happens on mouse-DOWN with no gesture
// disambiguation delay — identical behaviour for list, grouped list and icon views.
//
// The same view also draws the selection highlight itself with AppKit. That matters
// for right-click: while an NSMenu is tracking, SwiftUI's renderer can defer its own
// update (its display link only runs in the default run loop mode), so a
// SwiftUI-drawn highlight appears late. AppKit drawing inside the mouse-down event is
// flushed by displayIfNeeded() immediately, so the highlight is always in time.

final class ItemHitView: NSView {
    var itemID: String?

    var isHighlighted: Bool = false {
        didSet {
            guard oldValue != isHighlighted else { return }
            needsDisplay = true
        }
    }

    /// Corner radius of the highlight; icon view uses a cell-sized radius, list rows
    /// a thin one. Views register with whatever the calling view wants.
    var highlightCornerRadius: CGFloat = 6
    /// Inset of the drawn highlight from the view bounds.
    var highlightInset: CGFloat = 1

    /// Never intercept clicks / drags / hover; the registry only reads geometry and
    /// paints. hitTest returning nil keeps drag-and-drop and double-click intact.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted, !isInsideTableView else { return }
        let rect = bounds.insetBy(dx: highlightInset, dy: highlightInset)
        guard rect.width > 0, rect.height > 0 else { return }

        let path = NSBezierPath(roundedRect: rect,
                                xRadius: highlightCornerRadius,
                                yRadius: highlightCornerRadius)
        let active = window?.isKeyWindow ?? false
        let color = active
            ? NSColor.selectedContentBackgroundColor
            : NSColor.unemphasizedSelectedContentBackgroundColor
        color.setFill()
        path.fill()
    }

    /// Rows inside a SwiftUI Table are already highlighted by NSTableView itself;
    /// drawing here too would double-paint (and is what produced the border-then-fill
    /// flash). Only standalone cells such as the icon grid paint their own highlight.
    var isInsideTableView: Bool {
        var candidate: NSView? = superview
        while let view = candidate {
            if view is NSTableView { return true }
            candidate = view.superview
        }
        return false
    }

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

    /// Keyed by object identity so registration is O(1). The previous array-based
    /// store scanned every entry on each registration — with a lazy grid recycling
    /// cells while you scroll, that made scrolling O(n²) and dropped frames.
    private var entries: [ObjectIdentifier: ItemHitView] = [:]

    func register(_ view: ItemHitView) {
        entries[ObjectIdentifier(view)] = view
    }

    func unregister(_ view: ItemHitView) {
        entries.removeValue(forKey: ObjectIdentifier(view))
    }

    func removeAll() {
        entries.removeAll()
    }

    /// Drop entries whose view left its window. Called opportunistically, never in a
    /// per-cell hot path.
    private func pruneDetached() {
        guard entries.count > 64 else { return }
        entries = entries.filter { $0.value.window != nil }
    }

    /// Resolve which item sits under a window-space point.
    /// Picks the smallest matching frame so nested cells win over containers.
    ///
    /// `window` scopes the search: cells register from every open window, and without
    /// this filter a point in one window could match a cell in another.
    func itemID(atWindowPoint point: NSPoint, in window: NSWindow?) -> String? {
        var bestID: String?
        var bestArea = CGFloat.greatestFiniteMagnitude

        for (_, view) in entries {
            guard let id = view.itemID,
                  let viewWindow = view.window,
                  window == nil || viewWindow === window,
                  !view.isHiddenOrHasHiddenAncestor else { continue }
            let localPoint = view.convert(point, from: nil)
            guard view.bounds.contains(localPoint) else { continue }
            let area = view.bounds.width * view.bounds.height
            if area > 0, area < bestArea {
                bestArea = area
                bestID = id
            }
        }
        return bestID
    }

    /// Paint the highlight with AppKit and flush it before the event returns.
    /// This is what makes right-click selection feel immediate in the icon view,
    /// where there is no NSTableView to do the drawing for us.
    func applyHighlight(_ ids: Set<String>) {
        pruneDetached()
        var dirtyWindow: NSWindow?

        for (_, view) in entries {
            let shouldHighlight = view.itemID.map { ids.contains($0) } ?? false
            if view.isHighlighted != shouldHighlight {
                view.isHighlighted = shouldHighlight
                if dirtyWindow == nil { dirtyWindow = view.window }
            }
        }

        dirtyWindow?.displayIfNeeded()
    }
}

/// Transparent registration layer used behind an item cell.
///
/// `isSelected` is the authoritative SwiftUI selection: the AppKit view repaints
/// whenever SwiftUI's state changes, so highlights stay correct for *every* way the
/// selection can change (mouse router, keyboard, Cmd-click, select-all, reveal).
/// The mouse router may paint optimistically first for right/middle click latency;
/// the next SwiftUI update confirms it.
struct ItemHitArea: NSViewRepresentable {
    let itemID: String
    var isSelected: Bool = false
    var cornerRadius: CGFloat = 6
    var inset: CGFloat = 1

    func makeNSView(context: Context) -> ItemHitView {
        let v = ItemHitView()
        v.itemID = itemID
        v.isHighlighted = isSelected
        v.highlightCornerRadius = cornerRadius
        v.highlightInset = inset
        return v
    }

    func updateNSView(_ view: ItemHitView, context: Context) {
        view.itemID = itemID
        view.highlightCornerRadius = cornerRadius
        view.highlightInset = inset
        // Outside an NSTableView the cell owns its highlight, so mirror SwiftUI.
        if !view.isInsideTableView {
            view.isHighlighted = isSelected
        }
    }
}

extension View {
    /// Register this cell's geometry so the global click router can resolve it, and
    /// let it draw the selection highlight in AppKit for instant feedback.
    func itemHitArea(_ itemID: String,
                     isSelected: Bool = false,
                     cornerRadius: CGFloat = 6,
                     inset: CGFloat = 1) -> some View {
        background(ItemHitArea(itemID: itemID,
                               isSelected: isSelected,
                               cornerRadius: cornerRadius,
                               inset: inset))
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
