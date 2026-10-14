import SwiftUI

/// Whether the pill is open. Shared by the window controller (which resizes the window)
/// and the view (which draws the right layout).
final class NotchState: ObservableObject {
    @Published var isExpanded = false
    /// Moved right of the notch because the app in front has long menus.
    @Published var isShifted = false
    /// Where the window currently starts on screen. The pill is placed in screen coordinates,
    /// so it can slide between layouts while the window around it changes size.
    @Published var windowMinX: CGFloat = 0
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
    /// Lets the logo and bar glide from the left side to the right side when the pill shifts.
    @Namespace private var ears

    private var expanded: Bool { state.isExpanded }
    private var shifted: Bool { state.isShifted }

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
            .frame(width: geometry.width(expanded: expanded, shifted: shifted))
            .background(Color.black)
            .clipShape(shape) // content and glow are clipped to the pill while it grows
            .contentShape(shape)
            .onTapGesture(perform: onTap)
            .contextMenu { // right-click the pill
                Button("Settings…", action: onSettings)
                Divider()
                Button("Quit UsageNotch") { NSApp.terminate(nil) }
            }
            // Behind the pill, back to front: the drop shadow, then copies of the glows, then a
            // black pill that hides the copies inside it. Inside you see the real glow (clipped),
            // outside you see the copy, and they meet seamlessly at the edge.
            .background(shape.fill(Color.black))
            .backgroundPreferenceValue(GlowSpots.self) { spots in
                GeometryReader { proxy in
                    ForEach(spots) { spot in
                        Glow(tint: Theme.tint(for: spot.kind))
                            .position(proxy[spot.center])
                            .transition(fadeTransition(index: index(of: spot.kind)))
                    }
                }
            }
            // Drop shadow under the open pill, faded in and out with it.
            .background(
                shape.fill(Color.black)
                    .shadow(color: .black.opacity(expanded ? PillLayout.shadowOpacity : 0),
                            radius: PillLayout.shadowRadius, y: PillLayout.shadowY)
            )
            .offset(x: geometry.pillMinX(expanded: expanded, shifted: shifted) - state.windowMinX)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        let providers = store.activeProviders
        return HStack(spacing: 0) {
            if !shifted, let first = providers.first {
                HoverPill(tint: Theme.tint(for: first.kind)) { icon(first) }
            }
            Spacer(minLength: geometry.notchRect.width) // camera lives here
            if shifted, providers.count >= 2 {
                // Long menus, two AIs: a pill each, logo and bar, no reset time.
                ForEach(providers) { usage in
                    HoverPill(tint: Theme.tint(for: usage.kind)) { icon(usage) }
                }
            } else if shifted, let only = providers.first {
                // Long menus, one AI: logo, bar and reset time together in one pill.
                HoverPill(tint: Theme.tint(for: only.kind)) {
                    HStack(spacing: 8) {
                        icon(only)
                        time(only, now: now)
                    }
                }
            } else if providers.count >= 2 {
                HoverPill(tint: Theme.tint(for: providers[1].kind)) { icon(providers[1]) }
            } else if let only = providers.first {
                HoverPill(tint: Theme.tint(for: only.kind)) { time(only, now: now) }
            }
        }
        .padding(.horizontal, PillLayout.hoverPadding)
    }

    /// Logo + tiny bar. Tagged so it glides between sides when the pill shifts.
    private func icon(_ usage: ProviderUsage) -> some View {
        IconWithBar(usage: usage)
            .matchedGeometryEffect(id: usage.kind.rawValue, in: ears)
    }

    private func time(_ usage: ProviderUsage, now: Date) -> some View {
        // Compact shows "4h"; open shows the precise "4.2h".
        Text(ResetFormat.string(until: usage.fiveHour?.resetsAt, now: now, precise: expanded))
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Theme.tint(for: usage.kind))
            .contentTransition(.numericText())
            .frame(height: 16) // same height as the logo, so the hover pills match
            .matchedGeometryEffect(id: "time", in: ears)
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
        return .asymmetric(insertion: insertion.animation(appear(index)), removal: .opacity.animation(Motion.easeOut(0.1)))
    }

    /// The glow copies outside the pill fade exactly in step with their section,
    /// so the inside and outside glow always match at the pill's edge.
    private func fadeTransition(index: Int) -> AnyTransition {
        .asymmetric(insertion: .opacity.animation(appear(index)), removal: .opacity.animation(Motion.easeOut(0.1)))
    }

    private func appear(_ index: Int) -> Animation {
        Motion.easeOut(0.25).delay(Motion.contentDelay + Double(index) * Motion.stagger)
    }

    private func index(of kind: ProviderKind) -> Int {
        store.activeProviders.firstIndex { $0.kind == kind } ?? 0
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
