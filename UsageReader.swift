// UsageReader.swift
// Reads Claude subscription usage without a browser cookie.
//
// Source 1 (primary):  Claude Code's OAuth token from the macOS Keychain
//                      -> GET https://api.anthropic.com/api/oauth/usage (undocumented)
// Source 2 (fallback): snapshot file written by a Claude Code status-line script
//                      (~/.claude/usage-snapshot.json, from the documented `rate_limits` field)
//
// The token is read on every fetch, never stored, never logged, never refreshed here.
// Refreshing would rotate Claude Code's refresh token and could sign Claude Code out.

import Foundation
import Security

public struct UsageWindow: Equatable {
    public let key: String          // e.g. "five_hour", "seven_day", "seven_day_opus"
    public let percent: Double      // 0...100
    public let resetsAt: Date?

    /// Window length, inferred from the key ("five_hour" → 5h, "seven_day*" → 7d).
    public var duration: TimeInterval? {
        if key.hasPrefix("five_hour") { return 5 * 3600 }
        if key.hasPrefix("seven_day") { return 7 * 86400 }
        return nil
    }

    /// Share of the window that has elapsed, as a percentage (the "pace" line).
    public func expectedPercent(now: Date = Date()) -> Double? {
        guard let reset = resetsAt, let d = duration else { return nil }
        let elapsed = d - reset.timeIntervalSince(now)
        return min(max(elapsed / d * 100, 0), 100)
    }

    /// The first 15% of a window (45 min of 5 h, about a day of 7) is too little history:
    /// a few percent in the first minutes would project to running out.
    public func isTooEarlyToProject(now: Date = Date()) -> Bool {
        guard let reset = resetsAt, let d = duration else { return false }
        return now.timeIntervalSince(reset.addingTimeInterval(-d)) < d * 0.15
    }

    /// Linear projection: when 100% is reached at the average rate so far in this window.
    /// nil if usage is 0, the window can't be placed, it's too early to tell,
    /// or the limit won't be hit before reset.
    public func projectedLimitAt(now: Date = Date()) -> Date? {
        guard percent > 0, let reset = resetsAt, let d = duration else { return nil }
        if percent >= 100 { return now }
        guard !isTooEarlyToProject(now: now) else { return nil }
        let start = reset.addingTimeInterval(-d)
        let elapsed = now.timeIntervalSince(start)
        let hit = start.addingTimeInterval(elapsed * 100 / percent)
        return hit < reset ? hit : nil
    }

    /// Where usage lands at reset if the current rate holds (can exceed 100).
    public func projectedPercentAtReset(now: Date = Date()) -> Double? {
        guard let reset = resetsAt, let d = duration else { return nil }
        let elapsed = now.timeIntervalSince(reset.addingTimeInterval(-d))
        guard elapsed > 0 else { return nil }
        return percent * d / elapsed
    }

    /// Plain-language outlook, e.g. "Runs out Tuesday night, a day before Thursday's reset"
    /// or "Lasts until the reset at 03:20 — on track for about 45%".
    public func outlook(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let reset = resetsAt else { return String(format: "%.0f%% used", percent) }
        if percent >= 100 {
            return "Limit reached — resets \(HumanTime.moment(reset, now: now, calendar: calendar))"
        }
        if let hit = projectedLimitAt(now: now) {
            let early = HumanTime.span(reset.timeIntervalSince(hit))
            if reset.timeIntervalSince(now) < 12 * 3600 {
                return "Runs out around \(HumanTime.clock(hit, calendar.timeZone)), \(early) before the reset at \(HumanTime.clock(reset, calendar.timeZone))"
            }
            return "Runs out \(HumanTime.moment(hit, now: now, calendar: calendar)), \(early) before \(HumanTime.dayName(reset, now: now, calendar: calendar, possessive: true)) reset"
        }
        if percent > 0, isTooEarlyToProject(now: now) {
            let when = reset.timeIntervalSince(now) < 12 * 3600
                ? "at \(HumanTime.clock(reset, calendar.timeZone))"
                : HumanTime.moment(reset, now: now, calendar: calendar)
            return "Too early to project — resets \(when)"
        }
        let resetText = reset.timeIntervalSince(now) < 12 * 3600
            ? "the reset at \(HumanTime.clock(reset, calendar.timeZone))"
            : "\(HumanTime.dayName(reset, now: now, calendar: calendar, possessive: true)) reset"
        if let end = projectedPercentAtReset(now: now), percent > 0 {
            return String(format: "Lasts until %@ — on track for about %.0f%%", resetText, (end / 5).rounded() * 5)
        }
        return "Lasts until \(resetText)"
    }
}

/// Small helpers for "Tuesday night", "tomorrow morning", "1 day 3 h".
enum HumanTime {
    static let en = Locale(identifier: "en_GB")

    static func clock(_ d: Date, _ tz: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = en; f.timeZone = tz; f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    /// Rounded to one unit, since these are estimates: "40 min", "5 h", "a day", "3 days".
    static func span(_ s: TimeInterval) -> String {
        let mins = Int((s / 60).rounded())
        if mins < 60 { return "\(max(mins, 1)) min" }
        let hours = Int((Double(mins) / 60).rounded())
        if hours < 24 { return "\(hours) h" }
        let days = Int((Double(hours) / 24).rounded())
        return days == 1 ? "a day" : "\(days) days"
    }

    /// Times after midnight and before 05:00 count as the previous day's night.
    static func partOfDay(_ d: Date, calendar: Calendar) -> (day: Date, part: String) {
        let h = calendar.component(.hour, from: d)
        switch h {
        case 0..<5:  return (calendar.date(byAdding: .day, value: -1, to: d)!, "night")
        case 5..<12: return (d, "morning")
        case 12..<17: return (d, "afternoon")
        case 17..<21: return (d, "evening")
        default:     return (d, "night")
        }
    }

    /// "Thursday", "tomorrow", "today" (+ "'s" when possessive), or "14 Nov" beyond 6 days.
    static func dayName(_ d: Date, now: Date, calendar: Calendar, possessive: Bool = false) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: d)).day ?? 0
        let f = DateFormatter(); f.locale = en; f.timeZone = calendar.timeZone
        let name: String
        switch days {
        case 0: name = "today"
        case 1: name = "tomorrow"
        case 2...6: f.dateFormat = "EEEE"; name = f.string(from: d)
        default: f.dateFormat = "d MMM"; name = f.string(from: d)
        }
        guard possessive else { return name }
        return (0...6).contains(days) ? "\(name)'s" : "the \(name)"   // "the 15 Nov reset"
    }

    /// "tonight", "this afternoon", "tomorrow morning", "Tuesday night", "on 14 Nov".
    static func moment(_ d: Date, now: Date, calendar: Calendar) -> String {
        // Only the target is shifted (02:00 Wed → "Tuesday night"); "now" stays on its
        // calendar day, so at 00:49 Sunday, Sunday 19:00 is "this evening", not "tomorrow".
        let (day, part) = partOfDay(d, calendar: calendar)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: day)).day ?? 0
        switch days {
        case ...0: return part == "night" ? "tonight" : "this \(part)"
        case 1: return "tomorrow \(part)"
        case 2...6: return "\(dayName(day, now: now, calendar: calendar)) \(part)"
        default: return "on \(dayName(day, now: now, calendar: calendar))"
        }
    }
}

public struct UsageSnapshot {
    public enum Source: String { case oauth, statusLine = "status-line" }
    public let source: Source
    public let capturedAt: Date
    public let windows: [UsageWindow]
    /// Server-side `pace` / `indicator` objects (OAuth only). Observed as null so far;
    /// kept raw so the app can show them once Anthropic fills them in.
    public var serverPace: Any? = nil
    public var serverIndicator: Any? = nil
    /// `limits[].severity` keyed by window ("five_hour", "seven_day"), e.g. "normal".
    public var severity: [String: String] = [:]

    public func window(_ key: String) -> UsageWindow? { windows.first { $0.key == key } }
}

public enum UsageError: Error, CustomStringConvertible {
    case noCredentials
    case tokenExpired(Date)
    case http(Int)
    case badResponse(String)
    case noSnapshot
    case staleSnapshot(Date)

    public var description: String {
        switch self {
        case .noCredentials:           return "No Claude Code credentials in Keychain (run `claude` and sign in)"
        case .tokenExpired(let d):     return "Claude Code token expired at \(d); it refreshes the next time Claude Code runs"
        case .http(let code):          return "Usage endpoint returned HTTP \(code)"
        case .badResponse(let why):    return "Unexpected usage response: \(why)"
        case .noSnapshot:              return "No status-line snapshot yet"
        case .staleSnapshot(let d):    return "Status-line snapshot is stale (from \(d))"
        }
    }
}

extension UsageError {
    /// One short line for the UI, for any error a fetch can throw.
    public static func shortMessage(for error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return "Offline"
            case .timedOut:
                return "Request timed out"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Can't reach Claude's servers"
            default:
                return "Network error"
            }
        }
        guard let e = error as? UsageError else { return "Couldn't fetch usage" }
        switch e {
        case .noCredentials:             return "Not signed in: run claude in Terminal"
        case .tokenExpired:              return "Login expired: run claude in Terminal"
        case .http(401), .http(403):     return "Login expired: run claude in Terminal"
        case .http(429):                 return "Too many requests, will retry"
        case .http(let c) where c >= 500: return "Claude's usage service is down"
        case .http(let c):               return "Usage request failed (HTTP \(c))"
        case .badResponse:               return "Usage data format changed"
        case .noSnapshot, .staleSnapshot: return "No usage data yet"
        }
    }
}

public final class UsageReader {
    public static let keychainService = "Claude Code-credentials"
    public static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let snapshotURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/usage-snapshot.json")

    /// Snapshots older than this are ignored by `fetch()` when falling back.
    public var maxSnapshotAge: TimeInterval = 6 * 3600

    public init() {}

    // MARK: Combined

    /// Tries the OAuth endpoint first, then the status-line snapshot.
    public func fetch() async -> Result<UsageSnapshot, UsageError> {
        do {
            return .success(try await fetchOAuth())
        } catch let oauthError as UsageError {
            if let snap = try? readSnapshot(maxAge: maxSnapshotAge) { return .success(snap) }
            return .failure(oauthError)
        } catch {
            if let snap = try? readSnapshot(maxAge: maxSnapshotAge) { return .success(snap) }
            return .failure(.badResponse(error.localizedDescription))
        }
    }

    // MARK: Source 1 — OAuth

    struct Credentials { let accessToken: String; let expiresAt: Date? }

    func readCredentials() throws -> Credentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { throw UsageError.noCredentials }

        var expires: Date?
        if let ms = oauth["expiresAt"] as? Double { expires = Date(timeIntervalSince1970: ms / 1000) }
        return Credentials(accessToken: token, expiresAt: expires)
    }

    public func fetchOAuth() async throws -> UsageSnapshot {
        try Self.parseOAuth(try await fetchOAuthRaw())
    }

    /// Raw response body (usage data only; contains no credentials).
    public func fetchOAuthRaw() async throws -> Data {
        let creds = try readCredentials()
        if let exp = creds.expiresAt, exp < Date() { throw UsageError.tokenExpired(exp) }

        var req = URLRequest(url: Self.usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UsageError.http(code) }
        return data
    }

    /// Every top-level object that has a numeric `utilization` becomes a window,
    /// so new buckets show up without code changes.
    static func parseOAuth(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.badResponse("not a JSON object")
        }
        var windows: [UsageWindow] = []
        for (key, value) in root {
            guard let obj = value as? [String: Any],
                  let util = (obj["utilization"] as? NSNumber)?.doubleValue else { continue }
            windows.append(UsageWindow(key: key, percent: util,
                                       resetsAt: (obj["resets_at"] as? String).flatMap(parseISO)))
        }
        guard !windows.isEmpty else {
            throw UsageError.badResponse("no utilization fields (keys: \(root.keys.sorted()))")
        }
        var snap = UsageSnapshot(source: .oauth, capturedAt: now, windows: windows.sorted { $0.key < $1.key })
        snap.serverPace = root["pace"].flatMap { $0 is NSNull ? nil : $0 }
        snap.serverIndicator = root["indicator"].flatMap { $0 is NSNull ? nil : $0 }
        let kindToKey = ["session": "five_hour", "weekly_all": "seven_day",
                         "weekly_opus": "seven_day_opus", "weekly_sonnet": "seven_day_sonnet"]
        for limit in root["limits"] as? [[String: Any]] ?? [] {
            if let kind = limit["kind"] as? String, let sev = limit["severity"] as? String {
                snap.severity[kindToKey[kind] ?? kind] = sev
            }
        }
        return snap
    }

    // MARK: Source 2 — status-line snapshot

    public func readSnapshot(maxAge: TimeInterval? = nil) throws -> UsageSnapshot {
        guard let data = try? Data(contentsOf: Self.snapshotURL) else { throw UsageError.noSnapshot }
        let snap = try Self.parseSnapshot(data)
        if let maxAge, Date().timeIntervalSince(snap.capturedAt) > maxAge {
            throw UsageError.staleSnapshot(snap.capturedAt)
        }
        return snap
    }

    /// Expects `{ "captured_at": <epoch s>, "rate_limits": { "five_hour": {"used_percentage", "resets_at"}, ... } }`.
    static func parseSnapshot(_ data: Data) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else {
            throw UsageError.badResponse("snapshot has no rate_limits")
        }
        let captured = (root["captured_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? .distantPast
        var windows: [UsageWindow] = []
        for (key, value) in limits {
            guard let obj = value as? [String: Any],
                  let pct = (obj["used_percentage"] as? NSNumber)?.doubleValue else { continue }
            let reset = ((obj["resets_at"] ?? obj["reset_at"]) as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }
            windows.append(UsageWindow(key: key, percent: pct, resetsAt: reset))
        }
        guard !windows.isEmpty else { throw UsageError.badResponse("snapshot rate_limits empty") }
        return UsageSnapshot(source: .statusLine, capturedAt: captured, windows: windows.sorted { $0.key < $1.key })
    }

    private static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
