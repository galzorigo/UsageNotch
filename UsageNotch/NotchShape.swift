import SwiftUI

/// The notch outline: concave "shoulders" where it meets the top edge of the screen,
/// straight sides, and rounded bottom corners, like the hardware notch.
///
///   ╮                    ╭   ← topRadius: curves outward into the screen edge
///   │                    │
///   ╰────────────────────╯   ← bottom corners
///
/// The top curves are always there. Over a full screen app's black strip they're invisible,
/// and FullScreenCorners rounds off the bottom of that strip instead.
///
/// The bottom corners follow the height: compact size when closed, growing to
/// `expandedRadius` only as the pill actually gets taller. Tying the radius to the
/// height (instead of animating it separately) stops the bottom from pinching
/// inward at the start of the open animation.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var compactHeight: CGFloat
    var compactRadius: CGFloat
    var expandedRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let t = topRadius
        let growth = min(max((rect.height - compactHeight) / 40, 0), 1)
        let target = compactRadius + (expandedRadius - compactRadius) * growth
        let shoulder = rect.minY
        let b = max(0, min(target, (rect.width - 2 * t) / 2, rect.height - t))

        var p = Path()
        // SwiftUI's y axis points down: minY is the top of the screen.
        p.move(to: CGPoint(x: rect.minX, y: shoulder))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: shoulder + t),
                       control: CGPoint(x: rect.minX + t, y: shoulder))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: shoulder + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: shoulder),
                       control: CGPoint(x: rect.maxX - t, y: shoulder))
        p.closeSubpath()
        return p
    }
}
