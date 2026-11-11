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

    public init(t: Date, key: String, percent: Double, usedMinor: Int64? = nil, estimated: Bool? = nil) {
        self.t = t; self.key = key; self.percent = percent; self.usedMinor = usedMinor; self.estimated = estimated
    }
}

public struct UsageHistory: Equatable, Sendable {
    public private(set) var points: [HistoryPoint] = []

    /// Long enough for a whole month plus a few days of the one before.
    public static let keep: TimeInterval = 40 * 86400
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

    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.keep)
        points.removeAll { $0.t < cutoff }
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
    public func budgetSeries(_ key: String, periodStart: Date, current: HistoryPoint? = nil) -> [HistoryPoint] {
        var pts = series(key, from: periodStart).filter { $0.usedMinor != nil }
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
            func point(_ t: Date, _ acc: Double) -> HistoryPoint {
                let used = Int64((Double(g.fromMinor) + span * acc / total).rounded())
                return HistoryPoint(t: t, key: key, percent: limitMinor > 0 ? Double(used) / Double(limitMinor) * 100 : 0,
                                    usedMinor: used, estimated: true)
            }
            // A point every `step` (so the line stays unbroken), plus the period start at zero.
            var acc = 0.0, i = 0
            if g.fromMinor == 0 && g.start == periodStart { out.append(point(g.start, 0)) }
            var t = g.start.addingTimeInterval(step)
            while t < g.end {
                while i < inGap.count && inGap[i].t.isAtOrBefore(t) { acc += inGap[i].weight; i += 1 }
                out.append(point(t, acc))
                t = t.addingTimeInterval(step)
            }
        }
        return out.sorted { $0.t < $1.t }
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
