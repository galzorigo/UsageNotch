import Foundation

/// Claude usage. Three sources, newest wins:
/// 1. Live: Anthropic's usage endpoint, about once a minute (see ClaudeUsageAPI).
/// 2. ~/.claude/usagenotch/usage.json: written by our status line hook
///    (~/.claude/usagenotch/statusline.sh) after every response in terminal Claude Code.
/// 3. ~/.claude.json → cachedUsageUtilization: Claude Code's own cache of the same numbers.
/// The two files are local backups for when the live source is unavailable (offline,
/// login expired, endpoint changed).
struct ClaudeCodeProvider: UsageProvider {
    let kind = ProviderKind.claude
    private let api = ClaudeUsageAPI()

    /// Older than this and the numbers get the "Not updated" mark.
    private static let staleAfter: TimeInterval = 15 * 60

    private var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private var hookFile: URL { home.appending(path: ".claude/usagenotch/usage.json") }
    private var configFile: URL { home.appending(path: ".claude.json") }

    private typealias Snapshot = ClaudeUsageAPI.Snapshot

    func fetchUsage() async throws -> ProviderUsage {
        let config = LooseJSON.object(at: configFile)
        let candidates = [await api.latest(), fromHook(), fromCache(config)].compactMap { $0 }
        guard let newest = candidates.max(by: { $0.savedAt < $1.savedAt }) else {
            throw ProviderError.noData
        }
        let plan = plan(from: config)
        return ProviderUsage(
            kind: .claude,
            plan: plan,
            fiveHour: newest.fiveHour?.resolved(),
            weekly: newest.weekly?.resolved(),
            updatedAt: newest.savedAt,
            isStale: Date.now.timeIntervalSince(newest.savedAt) > Self.staleAfter,
            // No plan in Claude Code's account info (logged out) or a free plan = no subscription.
            hasSubscription: plan != nil && plan?.lowercased() != "free"
        )
    }

    func checkSoon() async {
        await api.checkSoon()
    }

    // MARK: Sources

    /// {"five_hour": {"used_percentage": 23.5, "resets_at": 1738425600}, "seven_day": {...}, "saved_at": ...}
    private func fromHook() -> Snapshot? {
        guard let json = LooseJSON.object(at: hookFile),
              let savedAt = LooseJSON.number(json["saved_at"]) else { return nil }
        func limit(_ key: String) -> UsageLimit? {
            guard let window = json[key] as? [String: Any],
                  let percent = LooseJSON.number(window["used_percentage"]) else { return nil }
            let reset = LooseJSON.number(window["resets_at"]).map { Date(timeIntervalSince1970: $0) }
            return UsageLimit(usedFraction: percent / 100, resetsAt: reset)
        }
        return Snapshot(savedAt: Date(timeIntervalSince1970: savedAt),
                        fiveHour: limit("five_hour"), weekly: limit("seven_day"))
    }

    /// {"fetchedAtMs": ..., "utilization": {"five_hour": {"utilization": 15, "resets_at": "2026-…"}, ...}}
    private func fromCache(_ config: [String: Any]?) -> Snapshot? {
        guard let cache = config?["cachedUsageUtilization"] as? [String: Any],
              let fetchedAtMs = LooseJSON.number(cache["fetchedAtMs"]),
              let utilization = cache["utilization"] as? [String: Any] else { return nil }
        func limit(_ key: String) -> UsageLimit? {
            guard let window = utilization[key] as? [String: Any],
                  let percent = LooseJSON.number(window["utilization"]) else { return nil }
            return UsageLimit(usedFraction: percent / 100, resetsAt: LooseJSON.date(window["resets_at"]))
        }
        return Snapshot(savedAt: Date(timeIntervalSince1970: fetchedAtMs / 1000),
                        fiveHour: limit("five_hour"), weekly: limit("seven_day"))
    }

    /// "claude_pro" → "Pro", "claude_max" → "Max", etc. Read from ~/.claude.json (not a secret).
    private func plan(from config: [String: Any]?) -> String? {
        guard let account = config?["oauthAccount"] as? [String: Any],
              let type = account["organizationType"] as? String else { return nil }
        let name = type.replacingOccurrences(of: "claude_", with: "")
        return name.isEmpty ? nil : name.prefix(1).uppercased() + name.dropFirst()
    }
}
