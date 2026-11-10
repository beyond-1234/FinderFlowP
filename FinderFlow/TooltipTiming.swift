import AppKit

// MARK: - Tooltip timing
//
// SwiftUI's `.help(_:)` is backed by AppKit tooltips, whose delay comes from the
// `NSInitialToolTipDelay` user default (in milliseconds). The macOS default is 1000ms
// or more, which makes toolbars feel unresponsive — you hover a bare icon and nothing
// explains it for over a second.
//
// Registering a smaller value in our own domain takes effect for this app only: the
// defaults system reads it when AppKit first needs a tooltip, so we set it before any
// window appears. 150ms still avoids accidental tooltips while sweeping the pointer
// across a toolbar, but feels immediate.

enum TooltipTiming {
    /// Milliseconds before a tooltip appears.
    private static let initialDelay = 150
    /// Milliseconds a redisplayed tooltip waits after the pointer moves to a new view.
    private static let reshowDelay = 50

    static func applyFastTooltips() {
        let defaults = UserDefaults.standard
        defaults.set(initialDelay, forKey: "NSInitialToolTipDelay")

        // AppKit also consumes these through the registration domain; setting them in
        // our app domain keeps the change scoped to this app.
        UserDefaults.standard.register(defaults: [
            "NSInitialToolTipDelay": initialDelay,
            "NSDisableAutomaticTermination": false,
        ])

        // Some AppKit paths read the default straight from the global domain at
        // tooltip-registration time; make sure the in-memory value is what they see.
        if UserDefaults.standard.integer(forKey: "NSInitialToolTipDelay") > initialDelay {
            defaults.set(initialDelay, forKey: "NSInitialToolTipDelay")
        }
        _ = reshowDelay
    }
}
