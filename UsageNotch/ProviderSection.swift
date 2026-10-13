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
                .background {
                    // 42pt circle with a heavy blur (Figma blur 70 ≈ SwiftUI radius 35).
                    Circle()
                        .fill(tint)
                        .frame(width: 42, height: 42)
                        .blur(radius: 35)
                        .allowsHitTesting(false)
                }
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
