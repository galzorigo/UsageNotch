import SwiftUI

/// One AI's section in the open pill, sitting directly on the black (no inner card):
///
///   Claude (Pro)            ← soft glow behind the name
///   5 hour limit        Weekly limit
///   ▬───────────        ▬▬▬▬▬▬▬▬───
///   7%        4.2h      85%        5d
struct ProviderSection: View {
    let usage: ProviderUsage
    let now: Date

    private var tint: Color { Theme.tint(for: usage.kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(spacing: 24) {
                LimitColumn(title: "5 hour limit", limit: usage.fiveHour, now: now, tint: tint)
                LimitColumn(title: "Weekly limit", limit: usage.weekly, now: now, tint: tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(usage.kind.displayName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                // The glow inside the pill. NotchView draws a matching copy behind the pill
                // at this same spot, so the part past the pill's edge shows too.
                .background { Glow(tint: tint) }
                .anchorPreference(key: GlowSpots.self, value: .center) { [GlowSpot(kind: usage.kind, center: $0)] }
            if let plan = usage.plan {
                Text(plan)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
            }
            Spacer(minLength: 0)
            if usage.isStale {
                // Shown when the last refresh failed and these numbers are old.
                Label("Not updated", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

private struct LimitColumn: View {
    let title: String
    let limit: UsageLimit?
    let now: Date
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
            UsageBar(fraction: limit?.usedFraction, tint: tint)
                .frame(height: 4)
            HStack {
                Text(limit.map { "\(Int(($0.usedFraction * 100).rounded()))%" } ?? "–")
                Spacer(minLength: 4)
                Text(ResetFormat.string(until: limit?.resetsAt, now: now, precise: true))
            }
            .font(.system(size: 13, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The soft light behind an AI's name: a 42pt circle with a heavy blur
/// (Figma blur 70 ≈ SwiftUI radius 35).
struct Glow: View {
    let tint: Color

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 42, height: 42)
            .blur(radius: 35)
            .allowsHitTesting(false)
    }
}

/// Where each glow is centred, passed up to NotchView so it can draw the part outside the pill.
struct GlowSpot: Identifiable {
    let kind: ProviderKind
    let center: Anchor<CGPoint>
    var id: ProviderKind { kind }
}

struct GlowSpots: PreferenceKey {
    static var defaultValue: [GlowSpot] = []
    static func reduce(value: inout [GlowSpot], nextValue: () -> [GlowSpot]) {
        value.append(contentsOf: nextValue())
    }
}
