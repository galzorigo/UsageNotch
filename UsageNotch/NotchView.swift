import SwiftUI

/// Whether the pill is open. Shared by the window controller (which resizes the window)
/// and the view (which draws the right layout).
final class NotchState: ObservableObject {
    @Published var isExpanded = false
}

/// The pill: black notch shape with an "ear" on each side of the camera.
/// Click it and it grows downward, one section per AI.
///
/// One AI:   [✳︎ ▬▬]  (camera)  [2h]
/// Two AIs:  [✳︎ ▬▬]  (camera)  [❁ ▬▬]
struct NotchView: View {
    let geometry: NotchGeometry
    @ObservedObject var store: UsageStore
    @ObservedObject var state: NotchState
    var onTap: () -> Void
    var onSettings: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var expanded: Bool { state.isExpanded }

    var body: some View {
        // Re-renders every 30 seconds so "2h" counts down on its own.
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(spacing: 0) {
                topRow(now: timeline.date)
                    .frame(height: geometry.notchRect.height)
                if expanded {
                    sections(now: timeline.date)
                }
            }
            .padding(.horizontal, geometry.topFlare)
            .frame(width: geometry.width(expanded: expanded))
            .background(Color.black)
            .clipShape(shape) // content and glow are clipped to the pill while it grows
            .contentShape(shape)
            .onTapGesture(perform: onTap)
            .contextMenu { // right-click the pill
                Button("Settings…", action: onSettings)
                Divider()
                Button("Quit UsageNotch") { NSApp.terminate(nil) }
            }
            // Drop shadow under the open pill, faded in and out with it.
            // Sits outside the clip so it can spill past the pill's edges.
            .background(
                shape.fill(Color.black)
                    .shadow(color: .black.opacity(expanded ? PillLayout.shadowOpacity : 0),
                            radius: PillLayout.shadowRadius, y: PillLayout.shadowY)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // The window is a bit bigger than the pill while open (room for the shadow).
            // Clicking that empty margin closes the pill, like clicking anywhere else.
            .background {
                if expanded {
                    Color.clear.contentShape(Rectangle()).onTapGesture(perform: onTap)
                }
            }
        }
    }

    // MARK: Top row (always visible, the "compact" pill)

    private func topRow(now: Date) -> some View {
        HStack(spacing: 0) {
            leftEar
            Spacer(minLength: geometry.notchRect.width) // camera lives here
            rightEar(now: now)
        }
        .padding(.horizontal, PillLayout.hoverPadding)
    }

    @ViewBuilder private var leftEar: some View {
        if let first = store.activeProviders.first {
            HoverPill(tint: Theme.tint(for: first.kind)) { IconWithBar(usage: first) }
        }
    }

    @ViewBuilder private func rightEar(now: Date) -> some View {
        if store.activeProviders.count >= 2 {
            let second = store.activeProviders[1]
            HoverPill(tint: Theme.tint(for: second.kind)) { IconWithBar(usage: second) }
        } else if let only = store.activeProviders.first {
            HoverPill(tint: Theme.tint(for: only.kind)) {
                // Compact shows "4h"; open shows the precise "4.2h".
                Text(ResetFormat.string(until: only.fiveHour?.resetsAt, now: now, precise: expanded))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.tint(for: only.kind))
                    .contentTransition(.numericText())
                    .frame(height: 16) // same height as the logo, so both hover pills match
            }
        }
    }

    // MARK: Open state

    /// Content lines up with the logo's left edge, with the same inset on the right.
    private func sections(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(Array(store.activeProviders.enumerated()), id: \.element.id) { index, usage in
                ProviderSection(usage: usage, now: now)
                    .transition(sectionTransition(index: index))
            }
        }
        .padding(.horizontal, PillLayout.contentInset)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    /// Sections fade in from slightly small and blurred (never from scale 0), one after another.
    /// They leave with a quick fade so closing feels snappy.
    private func sectionTransition(index: Int) -> AnyTransition {
        let insertion: AnyTransition = reduceMotion
            ? .opacity
            : .modifier(active: SoftAppear(progress: 0), identity: SoftAppear(progress: 1))
        return .asymmetric(
            insertion: insertion.animation(.easeOut(duration: 0.25).delay(0.06 + Double(index) * Motion.stagger)),
            removal: .opacity.animation(.easeOut(duration: 0.1))
        )
    }

    // MARK: Shape

    private var shape: AnyShape {
        if geometry.hasNotch {
            return AnyShape(NotchShape(
                topRadius: geometry.topFlare,
                compactHeight: geometry.notchRect.height,
                compactRadius: geometry.bottomCornerRadius,
                expandedRadius: PillLayout.expandedRadius
            ))
        }
        // Floating pill on screens without a notch.
        return AnyShape(RoundedRectangle(
            cornerRadius: expanded ? PillLayout.expandedRadius : geometry.notchRect.height / 2,
            style: .continuous
        ))
    }
}

/// Opacity + scale 0.95 + blur, driven by one progress value (0 = hidden, 1 = shown).
private struct SoftAppear: ViewModifier {
    let progress: Double
    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .scaleEffect(0.95 + 0.05 * progress, anchor: .top)
            .blur(radius: 4 * (1 - progress))
    }
}

/// Logo + tiny 5 hour bar, as in the compact mockups. Dimmed when the data is stale.
private struct IconWithBar: View {
    let usage: ProviderUsage

    var body: some View {
        HStack(spacing: 5) {
            ProviderIcon(kind: usage.kind)
            UsageBar(fraction: usage.fiveHour?.usedFraction, tint: Theme.tint(for: usage.kind))
                .frame(width: 20, height: 4)
        }
        .opacity(usage.isStale ? 0.45 : 1)
    }
}
