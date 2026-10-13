import SwiftUI

/// Small reusable pieces: provider logos, the progress bar, and the hover pill.

/// Your logo SVGs, from Assets.xcassets (kept in their own colours).
struct ProviderIcon: View {
    let kind: ProviderKind
    var size: CGFloat = 16

    var body: some View {
        Image(kind.rawValue) // "claude" or "codex"
            .resizable()
            .frame(width: size, height: size)
    }
}

/// A capsule progress bar. nil fraction (no data) shows just the empty track.
struct UsageBar: View {
    let fraction: Double?
    var tint: Color = Theme.accent

    var body: some View {
        GeometryReader { geo in
            let f = min(max(fraction ?? 0, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.22))
                if f > 0 {
                    Capsule().fill(tint)
                        .frame(width: max(geo.size.height, geo.size.width * f))
                }
            }
        }
    }
}

/// Wraps an ear item and shows a 15% tinted rounded background while the mouse is over it.
struct HoverPill<Content: View>: View {
    let tint: Color
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .padding(PillLayout.hoverPadding)
            .background(
                RoundedRectangle(cornerRadius: PillLayout.hoverRadius, style: .continuous)
                    .fill(tint.opacity(hovering ? 0.15 : 0))
            )
            .onHover { inside in
                withAnimation(Motion.hover) { hovering = inside }
            }
    }
}
