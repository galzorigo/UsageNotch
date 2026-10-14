import AppKit

/// Where the hardware notch is, measured from the screen instead of hardcoded.
/// All rects use AppKit's global coordinates (origin at the bottom-left of the main screen).
struct NotchGeometry {
    let screen: NSScreen
    /// The notch area the pill wraps around: notch width × menu bar height
    /// (or, without a notch, the empty middle of the floating pill).
    let notchRect: CGRect
    /// false on external monitors / Macs without a notch → we show a floating pill instead.
    let hasNotch: Bool

    /// How far the pill sticks out on each side of the notch. Short, so menu bar items stay visible.
    static let earWidth: CGFloat = 62

    /// Approximates the curve of the hardware notch's bottom corners. macOS doesn't expose it.
    var bottomCornerRadius: CGFloat { hasNotch ? notchRect.height * 0.32 : notchRect.height / 2 }

    /// The small outward curve where the pill meets the top edge of the screen.
    var topFlare: CGFloat { hasNotch ? 6 : 0 }

    /// Total window width: flare + ear + notch + ear + flare.
    var pillWidth: CGFloat { notchRect.width + (Self.earWidth + topFlare) * 2 }

    /// Open and closed share one width, so the pill only grows downward.
    /// (The floating pill is narrow, so it gets a minimum width when open.)
    ///
    /// `shifted`: the app in front has menus long enough to reach the pill's left side.
    /// Then the pill's left edge lines up with the real notch's left edge and everything
    /// sits to the right of the camera instead. Only on screens with a notch.
    func width(expanded: Bool, shifted: Bool) -> CGFloat {
        if shifted && hasNotch { return notchRect.width + PillLayout.shiftedEarWidth + topFlare * 2 }
        return expanded && !hasNotch ? max(pillWidth, PillLayout.minExpandedWidth) : pillWidth
    }

    /// The pill's left edge, in screen coordinates (the top curve sits just outside the notch).
    func pillMinX(expanded: Bool, shifted: Bool) -> CGFloat {
        if shifted && hasNotch { return notchRect.minX - topFlare }
        return notchRect.midX - width(expanded: expanded, shifted: false) / 2
    }

    /// Prefers the screen that actually has a notch, so an external monitor set as "main" doesn't win.
    static func current() -> NotchGeometry? {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        guard let screen = notched ?? NSScreen.main else { return nil }

        let notchHeight = screen.safeAreaInsets.top
        if notchHeight > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // The menu bar strips left and right of the notch are "auxiliary areas".
            // Whatever is between them is the notch.
            let minX = screen.frame.minX + left.width
            let maxX = screen.frame.maxX - right.width
            // The menu bar (and the black strip above full-screen apps) is a few points
            // taller than the notch itself, so match whichever is taller.
            let menuBarHeight = NSApp.mainMenu?.menuBarHeight ?? 0
            let height = max(notchHeight, menuBarHeight)
            let rect = CGRect(x: minX, y: screen.frame.maxY - height, width: maxX - minX, height: height)
            return NotchGeometry(screen: screen, notchRect: rect, hasNotch: true)
        }

        // No notch: a floating pill centred just below the menu bar.
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let pillHeight: CGFloat = 32
        let gapWidth: CGFloat = 24
        let rect = CGRect(
            x: screen.frame.midX - gapWidth / 2,
            y: screen.frame.maxY - menuBarHeight - 6 - pillHeight,
            width: gapWidth,
            height: pillHeight
        )
        return NotchGeometry(screen: screen, notchRect: rect, hasNotch: false)
    }
}
