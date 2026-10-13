import AppKit

/// Which AI a piece of usage data belongs to. Adding a provider later = adding a case here.
enum ProviderKind: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// One rate limit window, e.g. "5 hour limit: 7% used, resets in 4.2h".
struct UsageLimit {
    /// 0 = nothing used, 1 = limit reached.
    var usedFraction: Double
    var resetsAt: Date?
}

/// Everything the UI shows for one AI. nil values render as "–".
struct ProviderUsage: Identifiable {
    let kind: ProviderKind
    var plan: String?
    var fiveHour: UsageLimit?
    var weekly: UsageLimit?
    /// When the provider last produced these numbers.
    var updatedAt: Date?
    /// True when the last refresh failed and we're showing old numbers.
    var isStale = false
    /// False when the provider knows there's no paid plan (ended, or logged out).
    var hasSubscription = true
    var id: ProviderKind { kind }

    /// How long without fresh numbers before an AI is treated as no longer in use.
    static let inactiveAfter: TimeInterval = 7 * 86400

    /// Inactive AIs are hidden. If every AI is inactive, the whole pill disappears.
    var isActive: Bool {
        guard hasSubscription, let updatedAt else { return false }
        return Date.now.timeIntervalSince(updatedAt) < Self.inactiveAfter
    }
}

/// The single source of truth the UI watches. When `providers` changes, the pill redraws.
/// It asks every provider for numbers every 15 seconds. That's cheap: providers decide for
/// themselves when to actually hit the network (Claude: once a minute at most).
/// Everything pauses while the Mac is asleep or locked.
@MainActor
final class UsageStore: ObservableObject {
    @Published var providers: [ProviderUsage]
    /// Which AIs you've switched on in Settings. Saved between launches.
    @Published var enabledKinds: Set<ProviderKind> = UsageStore.savedEnabledKinds() {
        didSet { UserDefaults.standard.set(enabledKinds.map(\.rawValue), forKey: Self.enabledKey) }
    }
    /// What the UI shows: AIs that are switched on and actually in use. Empty = hide the pill.
    var activeProviders: [ProviderUsage] {
        providers.filter { $0.isActive && enabledKinds.contains($0.kind) }
    }

    private static let enabledKey = "enabledProviders"
    private static func savedEnabledKinds() -> Set<ProviderKind> {
        guard let saved = UserDefaults.standard.stringArray(forKey: enabledKey) else {
            return Set(ProviderKind.allCases) // first launch: everything on
        }
        return Set(saved.compactMap(ProviderKind.init(rawValue:)))
    }
    private let sources: [UsageProvider]
    private var pollTask: Task<Void, Never>?
    private var isPaused = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Real data. Starts with empty ("–") rows until the first refresh lands.
    init(sources: [UsageProvider]) {
        self.sources = sources
        self.providers = sources.map { ProviderUsage(kind: $0.kind) }
    }

    /// Fixed data, for design work.
    init(providers: [ProviderUsage]) {
        self.sources = []
        self.providers = providers
    }

    func startPolling(every interval: Duration = .seconds(15)) {
        watchSleepAndLock()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, !self.isPaused { await self.refresh() }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func refresh() async {
        for (index, source) in sources.enumerated() {
            do {
                providers[index] = try await source.fetchUsage()
            } catch {
                // Keep the last good numbers on screen, just flag them as old.
                providers[index].isStale = true
            }
        }
    }

    // MARK: Sleep / lock

    private func watchSleepAndLock() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let pauses: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.willSleepNotification),
            (workspace, NSWorkspace.screensDidSleepNotification),
            (distributed, Notification.Name("com.apple.screenIsLocked")),
        ]
        let resumes: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
            (distributed, Notification.Name("com.apple.screenIsUnlocked")),
        ]
        for (center, name) in pauses {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isPaused = true }
            }
            observers.append((center, token))
        }
        for (center, name) in resumes {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            }
            observers.append((center, token))
        }
    }

    /// Back from sleep or unlocked: check for fresh numbers right away.
    private func resume() {
        guard isPaused else { return }
        isPaused = false
        Task {
            for source in sources { await source.checkSoon() }
            await refresh()
        }
    }

    /// Made up numbers so we can design the UI without real data.
    static func fake(count: Int) -> UsageStore {
        let now = Date.now
        let claude = ProviderUsage(
            kind: .claude, plan: "Pro",
            fiveHour: UsageLimit(usedFraction: 0.07, resetsAt: now + 4.2 * 3600),
            weekly: UsageLimit(usedFraction: 0.85, resetsAt: now + 5 * 86400),
            updatedAt: now
        )
        let codex = ProviderUsage(
            kind: .codex, plan: "Plus",
            fiveHour: UsageLimit(usedFraction: 0.42, resetsAt: now + 2 * 3600),
            weekly: UsageLimit(usedFraction: 0.30, resetsAt: now + 3 * 86400),
            updatedAt: now
        )
        return UsageStore(providers: Array([claude, codex].prefix(count)))
    }
}

/// Turns a reset date into the short labels from the mockups: "35m", "2h", "4.2h", "5d".
enum ResetFormat {
    static func string(until date: Date?, now: Date = .now, precise: Bool = false) -> String {
        guard let date else { return "–" }
        let seconds = max(0, date.timeIntervalSince(now))
        let hours = seconds / 3600
        if hours >= 24 { return "\(Int((hours / 24).rounded()))d" }
        if hours >= 1 {
            let tenths = (hours * 10).rounded() / 10
            if precise && hours < 10 && tenths != tenths.rounded() {
                return String(format: "%.1fh", tenths) // "4.2h", but "2h" rather than "2.0h"
            }
            return "\(Int(hours.rounded()))h"
        }
        return "\(max(1, Int((seconds / 60).rounded())))m"
    }
}
