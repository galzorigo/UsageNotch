import AppKit
import SwiftUI

/// In a full screen app the whole menu bar strip is black, so the open pill meets the bottom of
/// that strip at a sharp corner. These two small curves round it off.
///
/// They live in their own little window that belongs to the full screen app's Space, not in the
/// pill's always-on-top window. So when you swipe to another Space they slide away together with
/// that app's black strip, in step with your fingers, and they're simply not there on the desktop.
@MainActor
final class FullScreenCorners {
    private let panel: NSPanel
    private var wantsVisible = false

    init() {
        panel = CornerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true // purely visual, clicks go straight through
        panel.hidesOnDeactivate = false
        // An ordinary floating level, above the full screen app but below the menu bar levels.
        // Windows at menu bar levels stay pinned to the screen while you swipe between Spaces,
        // which kept the corners in place. At this level they travel with the app's Space.
        panel.level = .floating
        // No .canJoinAllSpaces: it stays in the Space it was shown in.
        // .moveToActiveSpace: showing it again moves it to wherever you are now.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.alphaValue = 0
    }

    /// Fades the corners in under the strip, at the sides of the open pill.
    /// `pill` is the closed pill's frame: its bottom edge is the strip's bottom edge.
    func show(pill: CGRect, radius: CGFloat) {
        // Directly under the strip, as wide as the pill.
        panel.setFrame(CGRect(x: pill.minX, y: pill.minY - radius, width: pill.width, height: radius),
                       display: false)
        panel.contentView = NSHostingView(rootView: CornerFillets(radius: radius).fill(Color.black))
        panel.orderFrontRegardless()
        wantsVisible = true
        // Wait for the pill to start growing down to meet the corners, like the open content does.
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.contentDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.wantsVisible else { return }
                self.fade(to: 1, duration: 0.2)
            }
        }
    }

    /// Fades out quickly as the pill closes.
    func hide() {
        wantsVisible = false
        fade(to: 0, duration: 0.1) { [weak self] in
            guard let self, !self.wantsVisible else { return } // shown again meanwhile
            self.panel.orderOut(nil)
        }
    }

    private func fade(to alpha: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1) // strong ease out
            panel.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { completion?() }
        }
    }
}

/// Two concave fillets: the strip's bottom edge on top, the pill's sides `radius` in from each edge.
/// The same curve as the pill's shoulders at the top of the screen.
private struct CornerFillets: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = radius
        var p = Path()
        // Left: from the strip edge, along the strip, down the pill's side, curve back.
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: rect.minX + r, y: rect.minY))
        p.closeSubpath()
        // Right: the mirror image.
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// macOS nudges ordinary windows down so they never touch the menu bar, which left a thin gap
/// between the corners and the black strip. These corners are meant to touch it.
private final class CornerPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
