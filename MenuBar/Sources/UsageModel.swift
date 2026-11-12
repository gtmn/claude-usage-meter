import AppKit
import Foundation
import Network

extension UsageSnapshot {
    /// Fixed numbers for layout checks (`--sample`, `--render-preview`); needs no Keychain access.
    static var sample: UsageSnapshot {
        let now = Date()
        return UsageSnapshot(source: .oauth, capturedAt: now, windows: [
            UsageWindow(key: "five_hour", percent: 20, resetsAt: now.addingTimeInterval(2 * 3600)),
            UsageWindow(key: "seven_day", percent: 60, resetsAt: now.addingTimeInterval(3 * 86400)),
        ])
    }

    /// An Enterprise seat: only a monthly $ budget, no 5 h / 7 d windows (`--sample enterprise`).
    static var sampleEnterprise: UsageSnapshot {
        let spend = Spend(used: Money(minor: 41280, exponent: 2, currency: "USD"),
                          limit: Money(minor: 200000, exponent: 2, currency: "USD"))
        return UsageSnapshot(source: .oauth, capturedAt: Date(), windows: [
            UsageWindow(key: "extra_usage", percent: spend.percent, resetsAt: Spend.assumedReset(after: Date()),
                        spend: spend, resetIsAssumed: false),
        ])
    }

    /// True when the account has no session/week windows, so the $ budget is the only limit.
    var isBudgetOnly: Bool { window("five_hour") == nil && window("seven_day") == nil && window("extra_usage")?.spend != nil }
}

extension UsageHistory {
    /// A plausible made-up history ending at the snapshot's numbers, for `--sample` and screenshots:
    /// work happens on weekdays between 08:00 and 19:00, with a fixed pseudo-random wobble.
    static func sample(for snap: UsageSnapshot, now: Date = Date()) -> UsageHistory {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        var seed: UInt64 = 42
        func wobble() -> Double {   // 0.4 ... 1.6, deterministic
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return 0.4 + Double(seed >> 33) / Double(1 << 31) * 1.2
        }
        func working(_ t: Date) -> Bool {
            let h = cal.component(.hour, from: t), wd = cal.component(.weekday, from: t)
            return (2...6).contains(wd) && (8..<19).contains(h)
        }
        let step: TimeInterval = 20 * 60
        var pts: [HistoryPoint] = []

        if let w = snap.window("extra_usage"), let spend = w.spend, let reset = w.resetsAt, let d = w.duration {
            let start = reset.addingTimeInterval(-d)
            let times = stride(from: start, through: now, by: step).map { $0 }
            let rates = times.map { working($0) ? wobble() : 0 }
            let total = max(rates.reduce(0, +), 1)
            var acc = 0.0
            for (t, r) in zip(times, rates) {
                acc += r
                let used = Double(spend.used.minor) * acc / total
                pts.append(HistoryPoint(t: t, key: w.key, percent: used / Double(spend.limit.minor) * 100,
                                        usedMinor: Int64(used.rounded())))
            }
        }
        if let week = snap.window("seven_day"), let weekReset = week.resetsAt {
            let start = now.addingTimeInterval(-7 * 86400)
            let weekStart = weekReset.addingTimeInterval(-7 * 86400)
            let times = stride(from: start, through: now, by: step).map { $0 }
            let rates = times.map { working($0) ? wobble() : 0 }
            let inWindow = zip(times, rates).filter { $0.0.isAtOrAfter(weekStart) }.map(\.1).reduce(0, +)
            let perUnit = week.percent / max(inWindow, 1)
            let before = zip(times, rates).filter { $0.0 < weekStart }.map(\.1).reduce(0, +)
            let perUnitBefore = 30 / max(before, 1)   // previous week: 55% → 85% by its reset
            // Before this week's window began, the previous week was already at 55% and rising.
            var weekAcc = 55.0, session = 0.0, sessionEnd = Date.distantPast, inThisWeek = false
            for (t, r) in zip(times, rates) {
                if t.isAtOrAfter(weekStart) && !inThisWeek { inThisWeek = true; weekAcc = 0 }   // weekly reset
                weekAcc += r * (inThisWeek ? perUnit : perUnitBefore)
                if t.isAtOrAfter(sessionEnd) { session = 0; if r > 0 { sessionEnd = t.addingTimeInterval(5 * 3600) } }
                session += r * 2.2
                pts.append(HistoryPoint(t: t, key: "seven_day", percent: min(weekAcc, 100)))
                pts.append(HistoryPoint(t: t, key: "five_hour", percent: min(session, 100)))
            }
            // End exactly on the snapshot's numbers.
            pts.append(HistoryPoint(t: now, key: "seven_day", percent: week.percent))
            if let s = snap.window("five_hour") { pts.append(HistoryPoint(t: now, key: "five_hour", percent: s.percent)) }
        }
        return UsageHistory(points: pts)
    }

    /// The sample, but recorded only for the last `recordedDays`: the budget before that becomes
    /// Claude Code log weights instead, so previews show the estimated part of the curve too.
    static func sampleWithLogs(for snap: UsageSnapshot, now: Date = Date(),
                               recordedDays: Double = 2.6) -> (UsageHistory, [UsageWeight]) {
        let full = sample(for: snap, now: now).points
        let cutoff = now.addingTimeInterval(-recordedDays * 86400)
        var weights: [UsageWeight] = [], last: Int64 = 0
        for p in full where p.key == "extra_usage" && p.t < cutoff {
            if let u = p.usedMinor { if u > last { weights.append(UsageWeight(t: p.t, weight: Double(u - last))) }; last = u }
        }
        return (UsageHistory(points: full.filter { $0.key != "extra_usage" || $0.t.isAtOrAfter(cutoff) }), weights)
    }
}

/// Polls usage every 5 minutes (and on wake / when the panel opens).
/// Keeps the last good snapshot when a fetch fails, so the bar never goes blank.
@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    /// Why the OAuth source didn't work (set when we fell back to the status-line file or failed).
    @Published private(set) var oauthProblem: String?
    /// Set when no source produced data on the last attempt.
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    @Published private(set) var lastAttempt: Date?
    /// Usage over time, recorded from each fetch (the endpoint has no history of its own).
    @Published private(set) var history = UsageHistory()
    private var persistsHistory = false
    /// Claude Code activity on this Mac, for estimating stretches of the budget with no recorded history.
    @Published private(set) var logWeights: [UsageWeight] = []
    private var logsCovered: [ClosedRange<Date>] = []
    private var readingLogs = false
    /// The last month start at which the app saw the budget reset (kept beyond the 40 days of history).
    private var seenReset: Date?
    private static let seenResetKey = "budgetResetSeen"

    static let interval: TimeInterval = 5 * 60
    private let reader = UsageReader()
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let pathMonitor = NWPathMonitor()
    private var networkWasDown = false

    init(preview: UsageSnapshot? = nil, problem: String? = nil, history previewHistory: UsageHistory? = nil,
         logWeights previewLogs: [UsageWeight]? = nil) {
        if let preview {
            snapshot = preview; oauthProblem = problem
            if let previewHistory {
                history = previewHistory; logWeights = previewLogs ?? []
            } else {
                (history, logWeights) = UsageHistory.sampleWithLogs(for: preview)
            }
            return
        }
        history = UsageHistory.load()
        persistsHistory = true
        seenReset = UserDefaults.standard.object(forKey: Self.seenResetKey) as? Date
        refresh()
        // Fetch as soon as the network returns (a fetch right after wake often finds none yet).
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(up: up) }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func networkChanged(up: Bool) {
        if up && networkWasDown { refresh() }
        networkWasDown = !up
    }

    func refreshIfStale(olderThan age: TimeInterval = 60) {
        if let last = lastAttempt, Date().timeIntervalSince(last) < age { return }
        refresh()
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let reader = self.reader
        let mayNudge = persistsHistory && lastNudge.map { Date().timeIntervalSince($0) > Self.nudgeSpacing } ?? true
        Task {
            // Keychain access can block on a permission prompt, so keep it off the main actor.
            let (snap, oauthWhy, nudged) = await Task.detached { () -> (UsageSnapshot?, String?, Bool) in
                do {
                    return (try await reader.fetchOAuth(), nil, false)
                } catch {
                    var nudged = false
                    if mayNudge && LoginNudge.isExpiredLogin(error) {
                        nudged = true
                        if let s = await Self.nudgeAndRetry(reader) { return (s, nil, true) }
                    }
                    let why = UsageError.shortMessage(for: error)
                    return ((try? reader.readSnapshot(maxAge: reader.maxSnapshotAge)), why, nudged)
                }
            }.value

            if nudged { lastNudge = Date() }
            lastAttempt = Date()
            oauthProblem = oauthWhy
            if let snap {
                recordHistory(snap)
                updateSeenReset()
                snapshot = snap.confirmingAssumedReset(seen: seenReset).withPriorPace(from: history)
                error = nil
            } else {
                error = oauthWhy ?? "No usage data"
            }
            isLoading = false
        }
    }

    /// When the app last asked Claude Code to check its expired login, and how often it may.
    private var lastNudge: Date?
    static let nudgeSpacing: TimeInterval = 30 * 60

    /// Claude Code's login has expired: runs `claude auth status` (see LoginNudge.swift) and,
    /// if that renewed the login, fetches again. Logs what happened (times only, no account data).
    nonisolated static func nudgeAndRetry(_ reader: UsageReader) async -> UsageSnapshot? {
        let before = (try? reader.readCredentials())?.expiresAt
        let started = Date()
        let outcome = LoginNudge.run()
        let after = (try? reader.readCredentials())?.expiresAt
        let renewed = after.map { $0 > Date() && $0 != before } ?? false
        let f = ISO8601DateFormatter(); f.timeZone = .current
        NSLog("UsageMeter: login expired (valid until %@); %@ after %.1f s; login renewed: %@",
              before.map { f.string(from: $0) } ?? "unknown", outcome.description, Date().timeIntervalSince(started),
              renewed ? "yes, now valid until \(f.string(from: after!))" : "no")
        guard renewed else { return nil }
        return try? await reader.fetchOAuth()
    }

    private func recordHistory(_ snap: UsageSnapshot) {
        let before = history.points.count
        history.record(snap)
        readLogsForGaps(snap)
        guard persistsHistory, history.points.count != before || before == 0 else { return }
        let copy = history
        // One serial queue, so saves land in order and a newer history is never overwritten by an older one.
        Self.saveQueue.async {
            do { try copy.save() } catch { NSLog("UsageMeter: history save failed: \(error.localizedDescription)") }
        }
    }

    /// Remembers a reset seen at 00:00 UTC on the 1st; forgets it when one is seen at another time.
    private func updateSeenReset() {
        guard persistsHistory else { return }
        switch history.seenBudgetReset() {
        case .monthStart(let t) where seenReset.map({ t > $0 }) ?? true:
            seenReset = t
            UserDefaults.standard.set(t, forKey: Self.seenResetKey)
        case .elsewhere(let t) where seenReset.map({ t > $0 }) ?? false:
            seenReset = nil
            UserDefaults.standard.removeObject(forKey: Self.seenResetKey)
        default: break
        }
    }

    private static let saveQueue = DispatchQueue(label: "UsageMeter.history", qos: .utility)

    /// The budget period a snapshot's $ window covers, if it has one.
    static func budgetPeriod(_ snap: UsageSnapshot) -> (key: String, start: Date)? {
        guard snap.isBudgetOnly, let w = snap.window("extra_usage"), w.spend != nil,
              let reset = w.resetsAt, let d = w.duration else { return nil }
        return (w.key, reset.addingTimeInterval(-d))
    }

    /// Reads Claude Code's logs for stretches of the budget period the app didn't record
    /// (before it first ran, while the Mac was off). Each stretch is read once, off the main actor.
    private func readLogsForGaps(_ snap: UsageSnapshot) {
        guard persistsHistory, !readingLogs, let period = Self.budgetPeriod(snap) else { return }
        let pts = history.budgetSeries(period.key, periodStart: period.start)
        let missing = UsageHistory.gaps(in: pts, periodStart: period.start).filter { g in
            !logsCovered.contains { $0.contains(g.start) && $0.contains(g.end) }
        }
        guard let from = missing.map(\.start).min(), let to = missing.map(\.end).max() else { return }
        readingLogs = true
        Task {
            let found = await Task.detached(priority: .utility) { ClaudeCodeLogs.weights(from: from, to: to) }.value
            let covered = logsCovered
            let new = found.filter { w in !covered.contains { $0.contains(w.t) } }
            logWeights = (logWeights + new).filter { $0.t.isAtOrAfter(period.start) }.sorted { $0.t < $1.t }
            logsCovered.append(from...to)
            readingLogs = false
        }
    }

    // MARK: Derived

    /// Windows in display order: session, week, then model-specific weeks.
    var orderedWindows: [UsageWindow] {
        guard let s = snapshot else { return [] }
        let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "extra_usage"]
        return s.windows.sorted {
            (order.firstIndex(of: $0.key) ?? 99, $0.key) < (order.firstIndex(of: $1.key) ?? 99, $1.key)
        }
    }

    /// The rows shown in the menu bar item; warns when nearly full or projected to run out.
    func menuBarRows(now: Date = Date()) -> [MenuBarImage.Row] {
        guard let s = snapshot else { return [] }
        if s.isBudgetOnly, let w = s.window("extra_usage") {
            let warn = w.percent >= 90 || (w.spend?.limitReached ?? false) || w.projectedLimitAt(now: now) != nil
                || (s.severity["extra_usage"].map { $0 != "normal" } ?? false)
            return [MenuBarImage.Row(label: "$", percent: w.percent, warn: warn)]
        }
        return [("five_hour", "5h"), ("seven_day", "7d")].compactMap { key, label in
            s.window(key).map {
                MenuBarImage.Row(label: label, percent: $0.percent,
                                 warn: $0.percent >= 90 || $0.projectedLimitAt(now: now) != nil)
            }
        }
    }
}

extension UsageWindow: Identifiable {
    public var id: String { key }

    /// `budgetOnly`: the account's only limit is the $ budget (Enterprise/Team seat).
    func title(budgetOnly: Bool) -> String {
        if key == "extra_usage" {
            let (adj, unit) = switch spend?.period {
                case "daily": ("Daily", "day")
                case "weekly": ("Weekly", "week")
                default: ("Monthly", "month")
            }
            return budgetOnly ? "\(adj) budget" : "Extra usage · \(unit)"
        }
        return title
    }

    var title: String {
        switch key {
        case "five_hour":        return "Session · 5 h"
        case "seven_day":        return "Week · all models"
        case "seven_day_opus":   return "Week · Opus"
        case "seven_day_sonnet": return "Week · Sonnet"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
