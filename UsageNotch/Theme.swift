import SwiftUI

/// Colours, sizes and motion from the mockups.
enum Theme {
    /// Claude terracotta: logo, bar fill, numbers, hover. Same as the logo SVG.
    static let accent = Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255) // #D97757
    /// "5 hour limit", "Weekly limit".
    static let secondaryText = Color.white.opacity(0.45)

    /// Each AI's colour: bars, numbers, glow, hover.
    static func tint(for kind: ProviderKind) -> Color {
        switch kind {
        case .claude: accent
        case .codex: .white
        }
    }
}

/// Sizes. Everything inside the pill lines up on one inset: the logo's left edge.
enum PillLayout {
    /// Hover pill around ear items, and the gap between it and the pill edge.
    static let hoverPadding: CGFloat = 5
    static let hoverRadius: CGFloat = 8
    /// Distance from the pill's side to the content (logo, text, bars). Same on both sides.
    static let contentInset: CGFloat = hoverPadding * 2
    /// Bottom corners when open. Hover radius + its gap, so the curves are concentric.
    static let expandedRadius: CGFloat = 16
    /// Right side when the pill has moved over for long menus: room for the logo, bar and reset time.
    static let shiftedEarWidth: CGFloat = 120
    /// Only used on screens without a notch, where the floating pill is narrow.
    static let minExpandedWidth: CGFloat = 320
    /// Window height while open. Generous so two AIs and the shadow always fit.
    static let expandedWindowHeight: CGFloat = 340
    /// Shadow under the open pill.
    static let shadowOpacity: Double = 0.45
    static let shadowRadius: CGFloat = 20
    static let shadowY: CGFloat = 10
    /// Extra window width on each side while open, so the shadow and the glow spilling past
    /// the pill fade out completely before the window's edge.
    static let openMargin: CGFloat = 90
}

/// Motion, following Emil Kowalski's rules:
/// open is a spring with a little bounce (it should feel alive, like the Dynamic Island),
/// close is quicker with no bounce (the system responding should be snappy),
/// hover is a short colour fade, and Reduce Motion swaps movement for a plain fade.
enum Motion {
    // With Reduce Motion the pill changes size instantly (nil = no animation); only fades remain.
    static func open(reduced: Bool) -> Animation? {
        reduced ? nil : .spring(duration: 0.42, bounce: 0.2)
    }
    static func close(reduced: Bool) -> Animation? {
        reduced ? nil : .spring(duration: 0.3, bounce: 0)
    }
    /// Strong ease out, cubic-bezier(0.23, 1, 0.32, 1): arrives fast, settles gently.
    /// The built-in easeOut is too weak for things appearing.
    static func easeOut(_ duration: Double) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }
    /// Open content waits this long so it follows the pill's growth instead of racing it.
    static let contentDelay: Double = 0.06
    /// Sliding over for long menus and back: movement on screen, so no bounce.
    static func shift(reduced: Bool) -> Animation? {
        reduced ? nil : .spring(duration: 0.32, bounce: 0) // happens on app switches: keep it quick
    }
    /// CSS "ease", which is right for colour changes.
    static let hover = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.15)
    /// Delay between AI sections appearing (stagger).
    static let stagger: Double = 0.04
}
