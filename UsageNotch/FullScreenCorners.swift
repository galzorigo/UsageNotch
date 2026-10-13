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

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true // purely visual, clicks go straight through
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        // No .canJoinAllSpaces: it stays in the Space it was shown in.
        // .moveToActiveSpace: showing it again moves it to wherever you are now.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        panel.alphaValue = 0
    }

    /// Fades the corners in under the strip, at the sides of the open pill.
    func show(geometry: NotchGeometry) {
        guard geometry.hasNotch else { return } // no strip to blend into
        let radius = geometry.topFlare
        let notch = geometry.notchRect
        let width = geometry.pillWidth
        // Directly under the strip (notch.minY is the strip's bottom edge), as wide as the pill.
        panel.setFrame(CGRect(x: notch.midX - width / 2, y: notch.minY - radius, width: width, height: radius),
                       display: false)
        panel.contentView = NSHostingView(rootView: CornerFillets(radius: radius).fill(Color.black))
        panel.orderFrontRegardless()
        fade(to: 1, duration: 0.2)
    }

    /// Fades out quickly as the pill closes.
    func hide() {
        fade(to: 0, duration: 0.1) { [weak self] in
            guard let self, self.panel.alphaValue == 0 else { return } // shown again meanwhile
            self.panel.orderOut(nil)
        }
    }

    private func fade(to alpha: CGFloat, duration: TimeInterval, completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
