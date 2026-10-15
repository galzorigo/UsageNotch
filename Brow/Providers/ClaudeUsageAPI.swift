import Foundation

/// Live Claude usage from Anthropic's usage endpoint (the one Claude Code's /usage reads),
/// signed in with the login Claude Code already keeps in your Keychain.
///
/// Rules this follows:
/// - Only ever talks to api.anthropic.com.
/// - Reads the login, never saves or refreshes it. It's held in memory only, until it expires.
///   When it expires, Claude Code refreshes it the next time you use Claude.
/// - Polite polling: every 3 minutes while your usage is changing, every 10 minutes once it's
///   been quiet for 30 minutes. Claude Code checks this same endpoint with the same login, so
///   asking more often than that gets both of them rate limited.
/// - When refused (429), waits 5, then 10, 20, up to 60 minutes. Anthropic's Retry-After is
///   often 0, which would mean hammering it, so it's only used when it asks for longer.
/// - The endpoint is undocumented. Any surprise just means "no data", never a crash.
actor ClaudeUsageAPI {
    struct Snapshot {
        var savedAt: Date
        var fiveHour: UsageLimit?
        var weekly: UsageLimit?
    }

    private enum APIError: Error {
        case noLogin, loginExpired, unauthorized, rateLimited(retryAfter: TimeInterval), badResponse
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let activeInterval: TimeInterval = 3 * 60
    private static let idleInterval: TimeInterval = 10 * 60
    private static let idleAfter: TimeInterval = 30 * 60
    private static let errorInterval: TimeInterval = 2 * 60
    private static let firstBackoff: TimeInterval = 5 * 60
    private static let maxBackoff: TimeInterval = 60 * 60
    /// How long to wait after the next refusal. Doubles each time, resets after a success.
    private var backoff: TimeInterval = ClaudeUsageAPI.firstBackoff

    /// Ephemeral: no cookies or cache written to disk.
    private let session = URLSession(configuration: .ephemeral)
    private var last: Snapshot?
    private var nextAttempt = Date.distantPast
    private var lastChange = Date.now
    private var login: (token: String, expiresAt: Date)?

    /// The latest numbers. Only actually calls Anthropic when the next check is due;
    /// otherwise returns what it already has.
    func latest() async -> Snapshot? {
        guard Date.now >= nextAttempt else { return last }
        do {
            let fresh = try await fetch()
            if fresh.fiveHour?.usedFraction != last?.fiveHour?.usedFraction
                || fresh.weekly?.usedFraction != last?.weekly?.usedFraction {
                lastChange = .now
            }
            last = fresh
            let quiet = Date.now.timeIntervalSince(lastChange) > Self.idleAfter
            nextAttempt = .now + (quiet ? Self.idleInterval : Self.activeInterval)
            backoff = Self.firstBackoff
        } catch APIError.rateLimited(let retryAfter) {
            nextAttempt = .now + max(retryAfter, backoff)
            backoff = min(backoff * 2, Self.maxBackoff)
        } catch {
            if case APIError.unauthorized = error { login = nil } // re-read the login next time
            nextAttempt = .now + Self.errorInterval
        }
        return last
    }

    /// Check again on the next call (e.g. right after you unlock your Mac).
    /// Unless Anthropic has recently refused us: then the back off wait still applies.
    func checkSoon() {
        guard backoff == Self.firstBackoff else { return }
        nextAttempt = .distantPast
        lastChange = .now
    }

    // MARK: Request

    private func fetch() async throws -> Snapshot {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: 15)
        request.setValue("Bearer \(try await currentToken())", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Brow", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw APIError.unauthorized
        case 429:
            let retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? Self.idleInterval
            throw APIError.rateLimited(retryAfter: retryAfter)
        default: throw APIError.badResponse
        }

        // {"five_hour": {"utilization": 15, "resets_at": "2026-…"}, "seven_day": {...}, ...}
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError.badResponse
        }
        func limit(_ key: String) -> UsageLimit? {
            guard let window = json[key] as? [String: Any],
                  let percent = LooseJSON.number(window["utilization"]) else { return nil }
            return UsageLimit(usedFraction: percent / 100, resetsAt: LooseJSON.date(window["resets_at"]))
        }
        let snapshot = Snapshot(savedAt: .now, fiveHour: limit("five_hour"), weekly: limit("seven_day"))
        guard snapshot.fiveHour != nil || snapshot.weekly != nil else { throw APIError.badResponse }
        return snapshot
    }

    // MARK: Login (read-only)

    private func currentToken() async throws -> String {
        if let login, login.expiresAt > .now + 60 { return login.token }
        // Apple's own `security` tool reads the item Claude Code created. The first time,
        // macOS may ask permission: choose "Always Allow".
        let raw = try await Self.readKeychain(service: "Claude Code-credentials")
        guard let json = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { throw APIError.noLogin }
        let expiresAt = LooseJSON.number(oauth["expiresAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
            ?? .now + 3600
        guard expiresAt > .now else { throw APIError.loginExpired }
        login = (token, expiresAt)
        return token
    }

    /// Runs `security` off the main thread; it can wait on a Keychain permission prompt.
    private static func readKeychain(service: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = ["find-generic-password", "-s", service, "-w"]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = Pipe()
                do {
                    try process.run()
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: APIError.noLogin)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
