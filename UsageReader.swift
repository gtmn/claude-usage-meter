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

/// An amount of money in minor units (cents), as the usage endpoint reports it.
public struct Money: Equatable {
    public let minor: Int64
    public let exponent: Int        // 2 → minor units are cents
    public let currency: String     // ISO code, e.g. "USD"

    public var amount: Double { Double(minor) / pow(10, Double(exponent)) }

    /// "$116.88", "€1,000.00", "CHF 50.00" (en_US grouping, the currency's own symbol).
    public var formatted: String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .currency
        f.currencyCode = currency
        f.minimumFractionDigits = exponent
        f.maximumFractionDigits = exponent
        return f.string(from: NSNumber(value: amount)) ?? String(format: "%.\(exponent)f \(currency)", amount)
    }
}

/// A monthly spend budget: the main limit on Enterprise/Team seats, "extra usage" on Pro/Max.
public struct Spend: Equatable {
    public let used: Money
    public let limit: Money
    public var limitReached = false
    /// "monthly", "weekly" or "daily" when Claude Code reports it (status line); nil means monthly.
    public var period: String? = nil

    public var periodLength: TimeInterval? {
        switch period { case "daily": return 86400; case "weekly": return 7 * 86400; default: return nil }
    }

    /// The usage endpoint gives no reset time for the budget. Unless the status line or a
    /// `limits` row confirms one, the app assumes the calendar month in UTC: 00:00 UTC on the 1st.
    public static func assumedReset(after now: Date) -> Date {
        let start = utc.date(from: utc.dateComponents([.year, .month], from: now))!
        return utc.date(byAdding: .month, value: 1, to: start)!
    }

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()

    /// A share of the limit as an estimate, rounded to a whole 10 above 100 units: "about $490".
    func approx(percent p: Double) -> String {
        let units = limit.amount * p / 100
        let rounded = units >= 100 ? (units / 10).rounded() * 10 : units.rounded()
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US"); f.numberStyle = .currency; f.currencyCode = limit.currency
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: rounded)) ?? "\(Int(rounded)) \(limit.currency)"
    }
    public var remaining: Money {
        Money(minor: max(limit.minor - used.minor, 0), exponent: limit.exponent, currency: limit.currency)
    }
    public var percent: Double { limit.minor > 0 ? Double(used.minor) / Double(limit.minor) * 100 : 0 }
}

public struct UsageWindow: Equatable {
    public let key: String          // e.g. "five_hour", "seven_day", "seven_day_opus", "extra_usage"
    public let percent: Double      // 0...100
    public let resetsAt: Date?
    /// Money amounts for a spend budget (the "extra_usage" window); nil for 5 h / 7 d windows.
    public var spend: Spend? = nil
    /// True when `resetsAt` is the app's guess (the monthly budget), not the server's.
    public var resetIsAssumed = false

    /// Window length, inferred from the key ("five_hour" → 5h, "seven_day*" → 7d,
    /// "extra_usage" → the budget period, by default the calendar month that ends at `resetsAt`).
    public var duration: TimeInterval? {
        if key.hasPrefix("five_hour") { return 5 * 3600 }
        if key.hasPrefix("seven_day") { return 7 * 86400 }
        if key == "extra_usage", let reset = resetsAt {
            if let length = spend?.periodLength { return length }
            if let start = Spend.utc.date(byAdding: .month, value: -1, to: reset) { return reset.timeIntervalSince(start) }
        }
        return nil
    }

    /// The same window with a different reset (and assumed-flag).
    func withReset(_ reset: Date?, assumed: Bool, period: String? = nil) -> UsageWindow {
        var s = spend
        if let period { s?.period = period }
        return UsageWindow(key: key, percent: percent, resetsAt: reset, spend: s, resetIsAssumed: assumed)
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
        // A monthly reset falls around midnight, which `moment` would call "the night before"
        // ("resets on 30 Nov" for 00:00 on 1 Dec), so it's named by its date instead.
        let resetMoment = spend == nil
            ? HumanTime.moment(reset, now: now, calendar: calendar)
            : HumanTime.onDay(reset, now: now, calendar: calendar)
        if percent >= 100 || (spend?.limitReached ?? false) {
            let what = spend == nil ? "Limit reached" : "Budget used up"
            return "\(what) — resets \(resetMoment)"
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
                : resetMoment
            return "Too early to project — resets \(when)"
        }
        let resetText = reset.timeIntervalSince(now) < 12 * 3600
            ? "the reset at \(HumanTime.clock(reset, calendar.timeZone))"
            : "\(HumanTime.dayName(reset, now: now, calendar: calendar, possessive: true)) reset"
        if let end = projectedPercentAtReset(now: now), percent > 0 {
            if let spend { return "Lasts until \(resetText) — on track for about \(spend.approx(percent: end))" }
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

    /// "today", "tomorrow", "on Tuesday", "on 1 Dec": the day only, no part of day.
    static func onDay(_ d: Date, now: Date, calendar: Calendar) -> String {
        let name = dayName(d, now: now, calendar: calendar)
        return name == "today" || name == "tomorrow" ? name : "on \(name)"
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
        let snap = try Self.parseOAuth(try await fetchOAuthRaw())
        // The status-line file may be old for usage numbers, but a reset still in the future is valid.
        return Self.confirmingBudgetReset(snap, from: try? readSnapshot())
    }

    /// Replaces an assumed budget reset with the one Claude Code passed to the status line
    /// (`rate_limits.spend_limit.resets_at`, from the server's overage-reset header),
    /// as long as that reset hasn't passed yet.
    static func confirmingBudgetReset(_ snap: UsageSnapshot, from statusLine: UsageSnapshot?,
                                      now: Date = Date()) -> UsageSnapshot {
        guard let i = snap.windows.firstIndex(where: { $0.key == "extra_usage" && $0.resetIsAssumed }),
              let seen = statusLine?.window("extra_usage"), let reset = seen.resetsAt, reset > now
        else { return snap }
        var windows = snap.windows
        windows[i] = windows[i].withReset(reset, assumed: false, period: seen.spend?.period)
        return UsageSnapshot(source: snap.source, capturedAt: snap.capturedAt, windows: windows,
                             serverPace: snap.serverPace, serverIndicator: snap.serverIndicator,
                             severity: snap.severity)
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
        if let i = windows.firstIndex(where: { $0.key == "extra_usage" }), let spend = parseSpend(root) {
            let w = windows[i]
            // A `limits` row of kind "spend" carries the real reset and period (gateway spec);
            // prefer the active one when there are several.
            let rows = (root["limits"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "spend" }
            let row = rows.first { $0["is_active"] as? Bool == true } ?? rows.first
            let rowReset = (row?["resets_at"] as? String).flatMap(parseISO)
            var s = spend
            if let group = row?["group"] as? String { s.period = group }
            let real = w.resetsAt ?? rowReset
            windows[i] = UsageWindow(key: w.key, percent: w.percent, resetsAt: real ?? Spend.assumedReset(after: now),
                                     spend: s, resetIsAssumed: real == nil)
        }
        guard !windows.isEmpty else {
            throw UsageError.badResponse("no utilization fields (keys: \(root.keys.sorted()))")
        }
        var snap = UsageSnapshot(source: .oauth, capturedAt: now, windows: windows.sorted { $0.key < $1.key })
        if let sev = (root["spend"] as? [String: Any])?["severity"] as? String { snap.severity["extra_usage"] = sev }
        snap.serverPace = root["pace"].flatMap { $0 is NSNull ? nil : $0 }
        snap.serverIndicator = root["indicator"].flatMap { $0 is NSNull ? nil : $0 }
        let kindToKey = ["session": "five_hour", "weekly_all": "seven_day",
                         "weekly_opus": "seven_day_opus", "weekly_sonnet": "seven_day_sonnet",
                         "spend": "extra_usage"]
        for limit in root["limits"] as? [[String: Any]] ?? [] {
            if let kind = limit["kind"] as? String, let sev = limit["severity"] as? String {
                snap.severity[kindToKey[kind] ?? kind] = sev
            }
        }
        return snap
    }

    /// Reads `spend.used` / `spend.limit` ({amount_minor, currency, exponent}); falls back to
    /// `extra_usage.used_credits` / `monthly_limit` (minor units, `decimal_places`, `currency`).
    static func parseSpend(_ root: [String: Any]) -> Spend? {
        func money(_ any: Any?, currency fallback: String?) -> Money? {
            guard let o = any as? [String: Any],
                  let minor = (o["amount_minor"] as? NSNumber)?.int64Value,
                  let currency = (o["currency"] as? String) ?? fallback else { return nil }
            return Money(minor: minor, exponent: (o["exponent"] as? NSNumber)?.intValue ?? 2, currency: currency)
        }
        let extra = root["extra_usage"] as? [String: Any]
        let reached = (extra?["spend_limit_reached"] as? Bool) ?? false
        if let s = root["spend"] as? [String: Any],
           let used = money(s["used"], currency: nil),
           let limit = money(s["limit"], currency: used.currency), limit.minor > 0 {
            return Spend(used: used, limit: limit, limitReached: reached)
        }
        guard let extra,
              let used = (extra["used_credits"] as? NSNumber)?.doubleValue,
              let limit = (extra["monthly_limit"] as? NSNumber)?.doubleValue, limit > 0,
              let currency = extra["currency"] as? String else { return nil }
        let exp = (extra["decimal_places"] as? NSNumber)?.intValue ?? 2
        return Spend(used: Money(minor: Int64(used.rounded()), exponent: exp, currency: currency),
                     limit: Money(minor: Int64(limit.rounded()), exponent: exp, currency: currency),
                     limitReached: reached)
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
            if key == "spend_limit" {
                // {used_percentage, resets_at, used_usd?, limit_usd?, period?}; amounts are USD only.
                var spend: Spend?
                if let used = (obj["used_usd"] as? NSNumber)?.doubleValue,
                   let limit = (obj["limit_usd"] as? NSNumber)?.doubleValue, limit > 0 {
                    spend = Spend(used: Money(minor: Int64((used * 100).rounded()), exponent: 2, currency: "USD"),
                                  limit: Money(minor: Int64((limit * 100).rounded()), exponent: 2, currency: "USD"),
                                  limitReached: pct >= 100, period: obj["period"] as? String)
                }
                windows.append(UsageWindow(key: "extra_usage", percent: pct, resetsAt: reset, spend: spend))
                continue
            }
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
