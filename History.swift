// History.swift
// Usage over time, recorded by the app itself: the usage endpoint only reports "now".
// Stored as JSON in ~/Library/Application Support/UsageMeter/history.json (usage numbers
// only, no credentials). Shared by the menu bar app and the tests.

import Foundation

public struct HistoryPoint: Codable, Equatable, Sendable {
    public let t: Date
    public let key: String          // window key, e.g. "five_hour", "seven_day", "extra_usage"
    public let percent: Double
    public var usedMinor: Int64?    // money used, for the budget (same units as `Spend.used`)
    /// Not recorded but estimated from Claude Code's logs (never saved; see `filledBudget`).
    public var estimated: Bool?
    /// An estimated point with no Claude Code activity since the one before: the line is flat
    /// there (never saved either).
    public var idle: Bool?

    public init(t: Date, key: String, percent: Double, usedMinor: Int64? = nil, estimated: Bool? = nil, idle: Bool? = nil) {
        self.t = t; self.key = key; self.percent = percent; self.usedMinor = usedMinor
        self.estimated = estimated; self.idle = idle
    }
}

public struct UsageHistory: Equatable, Sendable {
    public private(set) var points: [HistoryPoint] = []

    /// Kept without a time limit, so past weeks and months can be looked back at. Points older
    /// than this are thinned to one per window per hour (`thin`), which keeps a year at about
    /// 2 MB instead of about 7.
    public static let fullDetail: TimeInterval = 60 * 86400
    /// One point per window per 10 minutes is plenty for a curve, and keeps the file small.
    /// A drop (a reset) is always recorded, so the curve falls where it really fell.
    public static let minSpacing: TimeInterval = 10 * 60

    public init(points: [HistoryPoint] = []) { self.points = points.sorted { $0.t < $1.t } }

    /// Adds one point per window. Skips a point that's too close to the previous one
    /// unless the value dropped, and anything older than the newest point (a stale fallback).
    public mutating func record(_ snap: UsageSnapshot, at time: Date? = nil) {
        let t = time ?? snap.capturedAt
        for w in snap.windows {
            let last = points.last { $0.key == w.key }
            if let last {
                if t.isAtOrBefore(last.t) { continue }
                let dropped = w.percent < last.percent - 0.5
                if !dropped && t.timeIntervalSince(last.t) < Self.minSpacing { continue }
            }
            points.append(HistoryPoint(t: t, key: w.key, percent: w.percent, usedMinor: w.spend?.used.minor))
        }
        prune(now: t)
    }

    /// Thins points older than `fullDetail` to one per window per hour. Of each hour it keeps the
    /// highest point, so a period's peak just before its reset survives (where a week or month
    /// ended); the reset itself still shows, as the next hour's lower point.
    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.fullDetail)
        guard let first = points.first, first.t < cutoff else { return }
        var kept: [String: [Int: HistoryPoint]] = [:]     // window → hour → highest point
        var recent: [HistoryPoint] = []
        for p in points {
            guard p.t < cutoff else { recent.append(p); continue }
            let hour = Int(floor(p.t.timeIntervalSince1970 / 3600))
            if let k = kept[p.key]?[hour], p.percent < k.percent { continue }
            kept[p.key, default: [:]][hour] = p
        }
        let thinned = kept.values.flatMap { $0.values }
        guard thinned.count + recent.count < points.count else { return }
        points = (thinned + recent).sorted { $0.t < $1.t }
    }

    /// Points for one window between two times, oldest first.
    public func series(_ key: String, from: Date, to: Date = .distantFuture) -> [HistoryPoint] {
        points.filter { $0.key == key && $0.t.isAtOrAfter(from) && $0.t.isAtOrBefore(to) }
    }

    // MARK: Storage

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("UsageMeter/history.json")
    }

    private static func coder() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        return (e, d)
    }

    /// An unreadable or missing file gives an empty history (it refills as the app runs).
    public static func load(from url: URL = defaultURL) -> UsageHistory {
        guard let data = try? Data(contentsOf: url),
              let pts = try? coder().1.decode([HistoryPoint].self, from: data) else { return UsageHistory() }
        return UsageHistory(points: pts)
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.coder().0.encode(points).write(to: url, options: .atomic)
    }
}

// MARK: Filling gaps and daily totals (budget only)

/// Relative usage at a moment, e.g. the list-price cost of one Claude Code request.
/// Only the shape matters: estimates are always scaled to amounts the app knows.
public struct UsageWeight: Equatable, Sendable {
    public let t: Date
    public let weight: Double
    public init(t: Date, weight: Double) { self.t = t; self.weight = weight }
}

/// A stretch of the budget period without recorded points, with the known amounts at both ends.
public struct HistoryGap: Equatable, Sendable {
    public let start: Date, end: Date
    public let fromMinor: Int64, toMinor: Int64
}

/// Money spent on one UTC day (Claude's own usage page counts days in UTC too).
public struct DaySpend: Equatable, Sendable {
    public let day: Date               // 00:00 UTC
    public var usedMinor: Int64 = 0
    /// The part of `usedMinor` that comes from estimated points.
    public var estimatedMinor: Int64 = 0
    /// The data starts part-way through this day: earlier spending that day isn't counted.
    public var countsFrom: Date?
    /// Nothing is known about the day(s) before, so this includes spending from as early as this.
    public var includesSince: Date?
}

extension UsageHistory {
    /// Gaps longer than this are filled from the logs (the app records about every 10 minutes).
    public static let fillableGap: TimeInterval = 3600

    /// Budget points for the period, with the current amount appended when it's newer.
    public func budgetSeries(_ key: String, periodStart: Date, to end: Date = .distantFuture,
                             current: HistoryPoint? = nil) -> [HistoryPoint] {
        var pts = series(key, from: periodStart).filter { $0.usedMinor != nil && $0.t < end }
        if let c = current, c.usedMinor != nil, c.t > (pts.last?.t ?? .distantPast) { pts.append(c) }
        return pts
    }

    /// Stretches with nothing recorded: from the period start (when nothing was used yet)
    /// to the first point, and between points more than `fillableGap` apart.
    public static func gaps(in pts: [HistoryPoint], periodStart: Date) -> [HistoryGap] {
        guard let first = pts.first, let firstUsed = first.usedMinor else { return [] }
        var out: [HistoryGap] = []
        if first.t.timeIntervalSince(periodStart) > fillableGap, firstUsed > 0 {
            out.append(HistoryGap(start: periodStart, end: first.t, fromMinor: 0, toMinor: firstUsed))
        }
        for (a, b) in zip(pts, pts.dropFirst()) {
            guard let au = a.usedMinor, let bu = b.usedMinor, bu > au,
                  b.t.timeIntervalSince(a.t) > fillableGap else { continue }
            out.append(HistoryGap(start: a.t, end: b.t, fromMinor: au, toMinor: bu))
        }
        return out
    }

    /// The budget series with its gaps filled by estimated points: shaped by `weights`
    /// (when the usage happened) and scaled so each gap ends exactly at the known amount.
    /// A gap with no weights stays a gap: the spending happened somewhere the logs don't see.
    public static func filledBudget(_ pts: [HistoryPoint], periodStart: Date, weights: [UsageWeight],
                                    limitMinor: Int64, step: TimeInterval = 20 * 60) -> [HistoryPoint] {
        let gaps = gaps(in: pts, periodStart: periodStart)
        guard !gaps.isEmpty, !weights.isEmpty, let key = pts.first?.key else { return pts }
        var out = pts
        for g in gaps {
            let inGap = weights.filter { $0.t > g.start && $0.t.isAtOrBefore(g.end) }
            let total = inGap.reduce(0) { $0 + $1.weight }
            guard total > 0 else { continue }
            let span = Double(g.toMinor - g.fromMinor)
            // Every filled point is estimated: the app didn't record it, and the logs can't see
            // spending elsewhere (the Claude apps, other computers). Steps with no Claude Code
            // activity are also `idle`: the line is flat there.
            var placedBefore = 0
            func point(_ t: Date, _ acc: Double, placed: Int) -> HistoryPoint {
                let quiet = placed == placedBefore
                placedBefore = placed
                let used = placed == 0 ? g.fromMinor : placed == inGap.count ? g.toMinor
                    : Int64((Double(g.fromMinor) + span * acc / total).rounded())
                return HistoryPoint(t: t, key: key, percent: limitMinor > 0 ? Double(used) / Double(limitMinor) * 100 : 0,
                                    usedMinor: used, estimated: true, idle: quiet ? true : nil)
            }
            // A point every `step` (so the line stays unbroken), plus the period start at zero.
            var acc = 0.0, i = 0
            if g.fromMinor == 0 && g.start == periodStart { out.append(point(g.start, 0, placed: 0)) }
            var t = g.start.addingTimeInterval(step)
            while t < g.end {
                while i < inGap.count && inGap[i].t.isAtOrBefore(t) { acc += inGap[i].weight; i += 1 }
                out.append(point(t, acc, placed: i))
                t = t.addingTimeInterval(step)
            }
        }
        return out.sorted { $0.t < $1.t }
    }

    /// One day of the budget (the Day view): the points from `from` to `to`, led by the amount
    /// already used at `from` (the last point before it, moved there), so the line starts where the
    /// day did. A drop within the day (the period's reset) stays in. `pts`: oldest first.
    public static func budgetDay(_ pts: [HistoryPoint], from: Date, to: Date) -> [HistoryPoint] {
        let used = pts.filter { $0.usedMinor != nil }
        var day = used.filter { $0.t.isAtOrAfter(from) && $0.t < to }
        if let before = used.last(where: { $0.t < from }), day.first?.t != from {
            day.insert(HistoryPoint(t: from, key: before.key, percent: before.percent, usedMinor: before.usedMinor,
                                    estimated: before.estimated, idle: before.idle), at: 0)
        }
        return day
    }

    /// Money spent over `pts`: each increase, and after a reset (a drop) the new amount.
    public static func spent(_ pts: [HistoryPoint]) -> Int64 {
        let used = pts.compactMap(\.usedMinor)
        return zip(used, used.dropFirst()).reduce(0) { sum, pair in
            sum + (pair.1 < pair.0 ? pair.1 : pair.1 - pair.0)
        }
    }

    /// Money spent per UTC day. Each increase counts on the day it was seen; a reset (a drop)
    /// counts the new amount as spent since the reset.
    public static func dailySpend(_ pts: [HistoryPoint]) -> [DaySpend] {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let used = pts.filter { $0.usedMinor != nil }
        guard let first = used.first else { return [] }
        var days: [DaySpend] = []
        func index(for t: Date) -> Int {
            let d = cal.startOfDay(for: t)
            if let i = days.lastIndex(where: { $0.day == d }) { return i }
            days.append(DaySpend(day: d))
            return days.count - 1
        }
        let firstDay = index(for: first.t)
        if first.t.timeIntervalSince(days[firstDay].day) > 5 * 60 && (first.usedMinor ?? 0) >= 0 && first.estimated != true {
            days[firstDay].countsFrom = first.t
        }
        for (a, b) in zip(used, used.dropFirst()) {
            let au = a.usedMinor!, bu = b.usedMinor!
            let delta = bu >= au ? bu - au : bu
            let i = index(for: b.t)
            // Spending since `a` lands here; if `a` is older than the day before, earlier days are folded in.
            if days[i].usedMinor == 0 && days[i].includesSince == nil,
               a.t < days[i].day.addingTimeInterval(-86400) {
                days[i].includesSince = a.t
            }
            days[i].usedMinor += delta
            if b.estimated == true { days[i].estimatedMinor += delta }
        }
        return days.sorted { $0.day < $1.day }
    }
}

// MARK: Seeing the budget reset

/// What the recorded history says about when the budget last reset. The usage data has no
/// reset date, so the app assumes 00:00 UTC on the 1st; seeing the amount fall then confirms it.
public enum SeenReset: Equatable, Sendable {
    /// No reset recorded, or one with too long a gap around it to tell when it happened.
    case unknown
    /// The amount fell between two points close to 00:00 UTC on the 1st (that month start).
    case monthStart(Date)
    /// The amount fell with no month start nearby (the point after the fall): the assumption is wrong.
    case elsewhere(Date)
}

extension UsageHistory {
    /// How close to the month start the points on both sides of the fall must be
    /// (the app fetches every 5 minutes and records every 10, a fall right away).
    public static let resetTolerance: TimeInterval = 20 * 60

    /// The newest budget reset in the recorded points (estimated ones never count).
    public func seenBudgetReset(_ key: String = "extra_usage") -> SeenReset {
        let pts = points.filter { $0.key == key && $0.usedMinor != nil && $0.estimated != true }
        for (a, b) in zip(pts, pts.dropFirst()).reversed() {
            let before = a.usedMinor!, after = b.usedMinor!
            // A reset, not a correction of a few cents: at least half the amount is gone.
            guard before > 0, after * 2 < before else { continue }
            let monthStart = Spend.utc.date(from: Spend.utc.dateComponents([.year, .month], from: b.t))!
            guard a.t < monthStart else { return .elsewhere(b.t) }
            guard monthStart.timeIntervalSince(a.t) <= Self.resetTolerance,
                  b.t.timeIntervalSince(monthStart) <= Self.resetTolerance else { return .unknown }
            return .monthStart(monthStart)
        }
        return .unknown
    }
}

extension UsageSnapshot {
    /// Drops "(assumed)" from the monthly budget's reset once the app has seen one happen at
    /// 00:00 UTC on the 1st (`seen`). A real reset date (status line) already isn't assumed.
    public func confirmingAssumedReset(seen: Date?) -> UsageSnapshot {
        guard let seen, let i = windows.firstIndex(where: { $0.key == "extra_usage" && $0.resetIsAssumed }),
              windows[i].spend?.periodLength == nil else { return self }
        var ws = windows
        ws[i] = ws[i].withReset(ws[i].resetsAt, assumed: false)
        ws[i].resetSeen = seen
        return UsageSnapshot(source: source, capturedAt: capturedAt, windows: ws,
                             serverPace: serverPace, serverIndicator: serverIndicator, severity: severity)
    }
}

// MARK: Last period's pace (early projections)

extension UsageHistory {
    /// The previous period's average pace, in percent of the limit per second, for the limits that
    /// reset on a fixed cycle (the weekly windows and the budget; a 5 h session says little about
    /// the next one). Taken from the last recorded point of the most recent earlier period it
    /// covers well enough (see `priorPeriod`). The budget is measured against today's limit, so a
    /// raised or lowered budget still projects in today's terms.
    public func priorPace(for w: UsageWindow) -> Double? { priorPeriod(for: w)?.pace }

    /// The most recent earlier period with enough recorded for a pace (`priorPace`), and how many
    /// periods back it is. Tries the last period first, then older ones up to `priorLookback` back
    /// (about six weeks, or one month): an older period says little about the current pace. A
    /// period counts once its last recorded point is at least `priorCoverage` of the way through it.
    public func priorPeriod(for w: UsageWindow) -> (pace: Double, back: Int)? {
        guard w.key == "extra_usage" || w.key.hasPrefix("seven_day"),
              let reset = w.resetsAt, let d = w.duration else { return nil }
        let start = reset.addingTimeInterval(-d)
        let monthly = w.key == "extra_usage" && w.spend?.periodLength == nil
        func periodStart(_ back: Int) -> Date {
            monthly ? Spend.utc.date(byAdding: .month, value: -back, to: start)! : start.addingTimeInterval(-Double(back) * d)
        }
        let own = points.filter { $0.key == w.key && $0.estimated != true }
        guard let oldest = own.first?.t else { return nil }
        var back = 1
        let earliest = start.addingTimeInterval(-Self.priorLookback)
        while back <= 6, periodStart(back - 1) > oldest, periodStart(back).isAtOrAfter(earliest) {
            let (from, to) = (periodStart(back), periodStart(back - 1))
            if let last = own.last(where: { $0.t < to && $0.t > from }) {
                let covered = last.t.timeIntervalSince(from)
                if covered >= to.timeIntervalSince(from) * Self.priorCoverage {
                    let used: Double
                    if w.key == "extra_usage" {
                        guard let minor = last.usedMinor, let limit = w.spend?.limit.minor, limit > 0 else { return nil }
                        used = Double(minor) / Double(limit) * 100
                    } else {
                        used = last.percent
                    }
                    return (used / covered, back)
                }
            }
            back += 1
        }
        return nil
    }

    /// How far into a period its last recorded point must be for the period's pace to count.
    /// The pace is the usage over the time covered, so a quarter still gives a fair rate.
    public static let priorCoverage = 0.25
    /// How far back an earlier period may start to stand in for the last one (the history itself
    /// is kept without a limit).
    public static let priorLookback: TimeInterval = 45 * 86400
}

extension UsageSnapshot {
    /// Each window with its previous period's pace from the history, for early projections.
    public func withPriorPace(from history: UsageHistory) -> UsageSnapshot {
        let ws = windows.map { w -> UsageWindow in
            var w = w
            let prior = history.priorPeriod(for: w)
            w.priorPace = prior?.pace; w.priorPeriodsBack = prior?.back ?? 1
            return w
        }
        return UsageSnapshot(source: source, capturedAt: capturedAt, windows: ws,
                             serverPace: serverPace, serverIndicator: serverIndicator, severity: severity)
    }
}

// MARK: Looking back: past periods

/// One reset-to-reset period of a window, summed up for looking back: how high it got and whether
/// (and when) it ran out. Only what the app recorded counts; estimates from the logs don't.
public struct PeriodSummary: Equatable, Sendable {
    public let start: Date
    /// The reset that ended it (for the current period: the next reset).
    public let end: Date
    /// The highest recorded percentage, and the money used at that point (budgets).
    public let peak: Double
    public let peakUsedMinor: Int64?
    /// The first recorded point at 100%.
    public let ranOutAt: Date?
    public let firstRecorded: Date, lastRecorded: Date

    /// How long before the reset it ran out.
    public var early: TimeInterval? { ranOutAt.map { end.timeIntervalSince($0) } }
    /// The share of the period between its first and last recorded point.
    public var covered: Double {
        let length = end.timeIntervalSince(start)
        return length > 0 ? min(lastRecorded.timeIntervalSince(firstRecorded) / length, 1) : 0
    }
}

extension UsageHistory {
    /// The start of the period `back` periods before the window's current one (0: the current
    /// one). Calendar months (UTC) for a budget without a stated length, else fixed lengths.
    public static func periodStart(of w: UsageWindow, back: Int) -> Date? {
        guard let reset = w.resetsAt, let d = w.duration else { return nil }
        let start = reset.addingTimeInterval(-d)
        if w.key == "extra_usage" && w.spend?.periodLength == nil {
            return Spend.utc.date(byAdding: .month, value: -back, to: start)
        }
        return start.addingTimeInterval(-Double(back) * d)
    }

    /// The window's periods with anything recorded, newest first: the current one (so far) and
    /// earlier ones, at most `limit`.
    public func periods(of w: UsageWindow, limit: Int = 520) -> [PeriodSummary] {
        let own = points.filter { $0.key == w.key && $0.estimated != true }
        guard let oldest = own.first?.t, let current = Self.periodStart(of: w, back: 0) else { return [] }
        var out: [PeriodSummary] = []
        var back = 0
        var end = w.resetsAt ?? current
        while out.count < limit, let start = Self.periodStart(of: w, back: back), oldest < end {
            let pts = own.filter { $0.t.isAtOrAfter(start) && $0.t < end }
            if let first = pts.first, let last = pts.last, let top = pts.max(by: { $0.percent < $1.percent }) {
                out.append(PeriodSummary(start: start, end: end, peak: top.percent, peakUsedMinor: top.usedMinor,
                                         ranOutAt: pts.first { !($0.percent < 99.5) }?.t,
                                         firstRecorded: first.t, lastRecorded: last.t))
            }
            end = start
            back += 1
        }
        return out
    }
}

// MARK: Hitting the 5 h limit

/// A session that ran into its limit: when it reached 100%, and when it reset (usage dropped), so
/// how long new requests were blocked.
public struct LimitHit: Equatable, Sendable {
    /// The first recorded point at 100%.
    public let at: Date
    /// The last recorded point at 100% before the reset (or so far).
    public let lastFull: Date
    /// The first recorded point after the reset; nil while still at 100%.
    public let resetSeen: Date?

    /// When it reset, as close as the history says: the first lower point, unless nothing was
    /// recorded for more than `resetUnknownAfter` before it (the Mac was asleep or off).
    public var resetAt: Date? {
        guard let seen = resetSeen, seen.timeIntervalSince(lastFull) <= Self.resetUnknownAfter else { return nil }
        return seen
    }
    /// How long it was blocked; when the reset time isn't known, at least this long (`atLeast`).
    public var blocked: TimeInterval { (resetAt ?? lastFull).timeIntervalSince(at) }
    public var atLeast: Bool { resetAt == nil }
    public static let resetUnknownAfter: TimeInterval = 30 * 60
}

extension UsageHistory {
    /// The times a limit (by default the 5 h session) reached 100%, oldest first, each session
    /// once; those that reached it between `from` and `to`.
    public func limitHits(_ key: String = "five_hour", from: Date = .distantPast, to: Date = .distantFuture) -> [LimitHit] {
        var hits: [LimitHit] = []
        var at: Date?, lastFull: Date?
        for p in points where p.key == key && p.estimated != true {
            let full = !(p.percent < 99.5)
            if full {
                if at == nil { at = p.t }
                lastFull = p.t
            } else if let a = at, let l = lastFull {
                hits.append(LimitHit(at: a, lastFull: l, resetSeen: p.t))
                at = nil; lastFull = nil
            }
        }
        if let a = at, let l = lastFull { hits.append(LimitHit(at: a, lastFull: l, resetSeen: nil)) }
        return hits.filter { $0.at.isAtOrAfter(from) && $0.at < to }
    }
}

extension UsageHistory {
    /// When a limit reset (by default the 5 h session), as close as the history says: the first
    /// recorded point after its value dropped. Those between `from` and `to`, oldest first.
    public func resets(_ key: String = "five_hour", from: Date = .distantPast, to: Date = .distantFuture) -> [Date] {
        var out: [Date] = []
        var last: Double?
        for p in points where p.key == key && p.estimated != true {
            if let l = last, p.percent < l - 0.5, p.t.isAtOrAfter(from), p.t < to { out.append(p.t) }
            last = p.percent
        }
        return out
    }
}
