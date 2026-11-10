import SwiftUI
import AppKit

// MARK: - Fast tooltip
//
// `.help(_:)` is AppKit's tooltip machinery: the delay comes from
// `NSInitialToolTipDelay`, and once a tooltip has been shown it will not re-show for
// the neighbouring view until the pointer stops moving for a while. On a dense toolbar
// that reads as "tooltips take forever".
//
// This modifier shows its own small floating panel after a short, fixed delay, follows
// the pointer to the next control immediately, and hides on click — the behaviour you
// get from Windows Explorer / KDE toolbars.

private let kTooltipDelay: TimeInterval = 0.18
private let kTooltipGap: CGFloat = 6

extension View {
    /// Attach a fast, self-drawn tooltip. Replaces `.help(_:)` for toolbar controls.
    func fastTooltip(_ text: String) -> some View {
        modifier(FastTooltipModifier(text: text))
    }
}

private struct FastTooltipModifier: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside {
                    TooltipPresenter.shared.schedule(text)
                } else {
                    TooltipPresenter.shared.cancel(for: text)
                }
            }
            .onDisappear { TooltipPresenter.shared.cancel(for: text) }
    }
}

final class TooltipPresenter {
    static let shared = TooltipPresenter()

    private var panel: NSPanel?
    private var label: NSTextField?
    private var pending: DispatchWorkItem?
    private var shownFor: String?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    private init() {}

    func schedule(_ text: String) {
        guard shownFor != text else { return }
        pending?.cancel()

        // Already visible for another control: swap immediately, no second delay.
        if shownFor != nil {
            show(text)
            return
        }

        let work = DispatchWorkItem { [weak self] in self?.show(text) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + kTooltipDelay, execute: work)
    }

    func cancel(for text: String) {
        // Always tear down. The previous guard skipped the hide whenever a *different*
        // tooltip was on screen (shownFor != text) with no pending work, which left a
        // .popUpMenu-level panel floating above every window forever.
        pending?.cancel()
        pending = nil
        if shownFor == text || shownFor != nil {
            hide()
        }
    }

    private func show(_ text: String) {
        pending = nil
        shownFor = text

        let field: NSTextField
        if let existing = label {
            field = existing
            field.stringValue = text
        } else {
            field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: 11)
            field.textColor = .labelColor
            field.lineBreakMode = .byTruncatingTail
            label = field
        }

        let fitted = field.sizeThatFits(NSSize(width: 400, height: 40))
        let padding: CGFloat = 8
        let size = NSSize(width: ceil(fitted.width) + padding * 2,
                          height: ceil(fitted.height) + 8)

        let panel = self.panel ?? makePanel()
        self.panel = panel

        field.frame = NSRect(x: padding, y: 4, width: size.width - padding * 2, height: size.height - 8)
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)

        position(panel, size: size)
        panel.orderFront(nil)
        installDismissMonitor()
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.hasShadow = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = true

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.layer?.cornerRadius = 5
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor

        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 11)
        container.addSubview(field)
        self.label = field
        p.contentView = container
        return p
    }

    private func position(_ panel: NSPanel, size: NSSize) {
        let mouse = NSEvent.mouseLocation
        var x = mouse.x - size.width / 2
        var y = mouse.y - size.height - kTooltipGap

        if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            let visible = screen.visibleFrame
            x = min(max(x, visible.minX + 4), visible.maxX - size.width - 4)
            if y < visible.minY + 4 {
                y = mouse.y + kTooltipGap   // not enough room below: flip above
            }
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installDismissMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            self?.hide()
            return event
        }
        // Moving the pointer off every tracked control, or switching apps, must also
        // remove the panel. A global monitor covers the cases the local one cannot see.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            self?.hide()
        }
    }

    private func removeDismissMonitor() {
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        localMonitor = nil
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
    }

    private func hide() {
        shownFor = nil
        panel?.orderOut(nil)
        removeDismissMonitor()
    }
}
