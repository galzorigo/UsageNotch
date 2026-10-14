import Foundation

/// Anything that can report usage for one AI. Claude reads local files; Codex (later) can
/// do something completely different. The UI doesn't care, it only sees `ProviderUsage`.
protocol UsageProvider {
    var kind: ProviderKind { get }
    /// Throw when there's no usable data; the store then keeps the last numbers and marks them stale.
    func fetchUsage() async throws -> ProviderUsage
    /// Skip any wait and fetch fresh numbers on the next refresh (after wake / unlock).
    func checkSoon() async
}

extension UsageProvider {
    func checkSoon() async {}
}

enum ProviderError: Error {
    case noData
}

extension UsageLimit {
    /// Once the reset time has passed, the window has emptied out even if we haven't heard
    /// from the provider since. The next window starts with your next message, so its
    /// reset time is unknown until then.
    func resolved(now: Date = .now) -> UsageLimit {
        guard let resetsAt, resetsAt <= now else { return self }
        return UsageLimit(usedFraction: 0, resetsAt: nil)
    }
}

/// Small JSON helpers so providers can dig into loosely structured files without crashing
/// when a field is missing or renamed.
enum LooseJSON {
    static func object(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// Parses "2026-10-13T12:40:00.615200+00:00" (with or without fractional seconds).
    static func date(_ value: Any?) -> Date? {
        guard var text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        text = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return formatter.date(from: text)
    }
}
