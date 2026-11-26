import AppKit
import Foundation
import Network

extension UsageSnapshot {
    /// Fixed numbers for layout checks (`--sample`, `--render-preview`); needs no Keychain access.
    static var sample: UsageSnapshot {
        let now = Date()
        // `full`: the session at its limit, resetting in 1 h 10 min. `burst`: 58% twenty minutes in.
        let full = CommandLine.arguments.contains("full"), burst = CommandLine.arguments.contains("burst")
        let session = full ? (100.0, 70.0 * 60) : burst ? (58, 280 * 60) : (20, 2 * 3600)
        return UsageSnapshot(source: .oauth, capturedAt: now, windows: [
            UsageWindow(key: "five_hour", percent: session.0, resetsAt: now.addingTimeInterval(session.1)),
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

    /// Pro/Max with extra usage turned on: the sample plus a monthly $ limit (`--sample extra`).
    static var sampleWithExtra: UsageSnapshot {
        let spend = Spend(used: Money(minor: 1240, exponent: 2, currency: "USD"),
                          limit: Money(minor: 5000, exponent: 2, currency: "USD"))
        let s = sample
        return UsageSnapshot(source: s.source, capturedAt: s.capturedAt, windows: s.windows + [
            UsageWindow(key: "extra_usage", percent: spend.percent, resetsAt: Spend.assumedReset(after: Date()),
                        spend: spend, resetIsAssumed: false),
        ])
    }

    /// With a model's own weekly limit added (`fable`): Fable at 35%, resetting with the week.
    var withSampleFable: UsageSnapshot {
        guard let week = window("seven_day") else { return self }
        return UsageSnapshot(source: source, capturedAt: capturedAt, windows: windows + [
            UsageWindow(key: "seven_day_fable", percent: 35, resetsAt: week.resetsAt),
        ])
    }

    func withFableIf(_ on: Bool) -> UsageSnapshot { on ? withSampleFable : self }

    /// Extra usage on a Pro/Max account: a $ limit next to the session and week windows.
    var extraUsage: UsageWindow? {
        guard !isBudgetOnly, let w = window("extra_usage"), w.spend != nil else { return nil }
        return w
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
            let fable = snap.window("seven_day_fable")   // follows the week's curve, scaled to its own number
            // Before this week's window began, the previous week was already at 55% and rising.
            var weekAcc = 55.0, session = 0.0, sessionEnd = Date.distantPast, inThisWeek = false
            for (t, r) in zip(times, rates) {
                if t.isAtOrAfter(weekStart) && !inThisWeek { inThisWeek = true; weekAcc = 0 }   // weekly reset
                weekAcc += r * (inThisWeek ? perUnit : perUnitBefore)
                if t.isAtOrAfter(sessionEnd) { session = 0; if r > 0 { sessionEnd = t.addingTimeInterval(5 * 3600) } }
                session += r * 2.2
                pts.append(HistoryPoint(t: t, key: "seven_day", percent: min(weekAcc, 100)))
                pts.append(HistoryPoint(t: t, key: "five_hour", percent: min(session, 100)))
                if let f = fable { pts.append(HistoryPoint(t: t, key: f.key, percent: min(weekAcc * f.percent / max(week.percent, 1), 100))) }
            }
            // End exactly on the snapshot's numbers.
            pts.append(HistoryPoint(t: now, key: "seven_day", percent: week.percent))
            if let s = snap.window("five_hour") { pts.append(HistoryPoint(t: now, key: "five_hour", percent: s.percent)) }
            if let f = fable { pts.append(HistoryPoint(t: now, key: f.key, percent: f.percent)) }
        }
        return UsageHistory(points: samplePast(for: snap, now: now) + pts)
    }

    /// Earlier weeks and months for the sample, so the overview and the ‹ › steps have something to
    /// show: hourly points on weekday working hours, each period rising to a fixed peak (some run out).
    private static func samplePast(for snap: UsageSnapshot, now: Date) -> [HistoryPoint] {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        func working(_ t: Date) -> Bool {
            let h = cal.component(.hour, from: t), wd = cal.component(.weekday, from: t)
            return (2...6).contains(wd) && (8..<19).contains(h)
        }
        /// Rises over `times` to `peak` at their end (or to 100 by `runsOutAt` of the way), then holds.
        func rise(_ times: [Date], key: String, from: Double = 0, peak: Double, runsOutAt: Double? = nil,
                  limitMinor: Int64? = nil) -> [HistoryPoint] {
            let busy = times.map { working($0) ? 1.0 : 0.0 }
            let cut = runsOutAt.map { Int(Double(times.count) * $0) } ?? times.count
            let total = max(busy.prefix(cut).reduce(0, +), 1)
            var acc = 0.0
            return times.enumerated().map { i, t in
                if i < cut { acc += busy[i] }
                let p = from + (peak - from) * min(acc / total, 1)
                return HistoryPoint(t: t, key: key, percent: p, usedMinor: limitMinor.map { Int64(Double($0) * p / 100) })
            }
        }
        var pts: [HistoryPoint] = []
        if let week = snap.window("seven_day"), let reset = week.resetsAt {
            let weekStart = reset.addingTimeInterval(-7 * 86400), sampleStart = now.addingTimeInterval(-7 * 86400)
            // Peaks of the 11 weeks before last week, oldest first; 100 runs out before the reset.
            let peaks: [Double] = [62, 100, 78, 45, 91, 100, 70, 52, 83, 100, 66]
            // How often the 5 h session hit its limit in each of those weeks: the busy weeks, mostly.
            let sessionHits = [0, 3, 1, 0, 2, 4, 0, 0, 1, 3, 0]
            for (i, peak) in peaks.enumerated() {
                let start = weekStart.addingTimeInterval(-Double(peaks.count + 1 - i) * 7 * 86400)
                let times = stride(from: start, to: start.addingTimeInterval(7 * 86400), by: 3600).map { $0 }
                pts += rise(times, key: "seven_day", peak: peak, runsOutAt: peak == 100 ? 0.75 : nil)
                // Afternoon sessions on the first weekdays: 13:00 at 45%, full by 14:40, reset at 18:00.
                let weekdays = (0..<7).map { start.addingTimeInterval(Double($0) * 86400) }
                    .filter { (2...6).contains(cal.component(.weekday, from: $0)) }
                for day in weekdays.prefix(sessionHits[i]) {
                    let noon = cal.date(bySettingHour: 13, minute: 0, second: 0, of: day) ?? day
                    for (h, v) in [(0.0, 45.0), (1.0, 85), (1.67, 100), (3, 100), (4.5, 100), (5, 0)] {
                        pts.append(HistoryPoint(t: noon.addingTimeInterval(h * 3600), key: "five_hour", percent: v))
                    }
                }
            }
            // Last week up to where the detailed sample starts (at 55%).
            let lastWeek = weekStart.addingTimeInterval(-7 * 86400)
            pts += rise(stride(from: lastWeek, to: sampleStart, by: 3600).map { $0 }, key: "seven_day", peak: 55)
        }
        if let w = snap.window("extra_usage"), let spend = w.spend, w.spend?.periodLength == nil,
           let current = UsageHistory.periodStart(of: w, back: 0) {
            // The 5 months before this one, oldest first, as shares of the budget.
            let shares: [Double] = [48, 71, 100, 62, 55]
            for (i, share) in shares.enumerated() {
                guard let start = Spend.utc.date(byAdding: .month, value: -(shares.count - i), to: current),
                      let end = Spend.utc.date(byAdding: .month, value: 1, to: start) else { continue }
                let times = stride(from: start, to: end, by: 3600).map { $0 }
                pts += rise(times, key: w.key, peak: share, runsOutAt: share == 100 ? 0.78 : nil,
                            limitMinor: spend.limit.minor)
            }
        }
        return pts
    }

    /// The sample, but recorded only for the last `recordedDays`: the budget before that becomes
    /// Claude Code log weights instead, so previews show the estimated part of the curve too.
    static func sampleWithLogs(for snap: UsageSnapshot, now: Date = Date(),
                               recordedDays: Double = 2.6) -> (UsageHistory, [UsageWeight]) {
        let full = sample(for: snap, now: now).points
        let cutoff = now.addingTimeInterval(-recordedDays * 86400)
        // Earlier periods stay recorded; only the current one's start becomes log weights.
        let periodStart = snap.window("extra_usage").flatMap { UsageHistory.periodStart(of: $0, back: 0) } ?? .distantPast
        func early(_ p: HistoryPoint) -> Bool { p.key == "extra_usage" && p.t < cutoff && p.t.isAtOrAfter(periodStart) }
        var weights: [UsageWeight] = [], last: Int64 = 0
        for p in full where early(p) {
            if let u = p.usedMinor { if u > last { weights.append(UsageWeight(t: p.t, weight: Double(u - last))) }; last = u }
        }
        return (UsageHistory(points: full.filter { !early($0) }), weights)
    }
}

/// Polls usage every 5 minutes (and on wake / when the panel opens).
/// Keeps the last good snapshot when a fetch fails, so the bar never goes blank.
@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    /// Why the OAuth source didn't work (set when we fell back to the status-line file or failed).
    @Published private(set) var oauthProblem: String?
    /// The numbers on show weren't fetched by the last attempt: saved from an earlier run
    /// (`LastUsage`) or kept after a failed fetch. The popup says so.
    @Published private(set) var showingSaved = false
    /// Set when no source produced data on the last attempt.
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    @Published private(set) var lastAttempt: Date?
    /// Claude Code's login can't come back without signing in again (see `LoginNudge.signInNeeded`):
    /// the popup offers Sign in… and the menu bar item fades. Cleared by the next successful fetch.
    @Published private(set) var signedOut = false
    static let signedOutMessage = "Signed out of Claude Code"

    /// The numbers on show are old: signed out of Claude Code, or more than `staleAfter` old and the
    /// latest fetch since then failed (offline, rate-limited, …). Right after waking from sleep the
    /// numbers are old too, but no fetch has failed yet: the wake fetch replaces them first.
    func isStale(now: Date = Date()) -> Bool {
        if signedOut { return true }
        guard let s = snapshot, now.timeIntervalSince(s.capturedAt) > Self.staleAfter else { return false }
        return !isLoading && (lastAttempt.map { s.capturedAt < $0.addingTimeInterval(-60) } ?? false)
    }
    /// Three missed 5-minute fetches.
    static let staleAfter: TimeInterval = 15 * 60
    /// After Sign in…: waiting for the new login, or Terminal couldn't be opened.
    enum SignInProgress: Equatable { case waiting, couldNotOpen }
    @Published private(set) var signInProgress: SignInProgress?
    private var signInPoll: Timer?
    /// Usage over time, recorded from each fetch (the endpoint has no history of its own).
    @Published private(set) var history = UsageHistory()
    private var persistsHistory = false
    /// Claude Code activity on this Mac, for estimating stretches of the budget with no recorded history.
    @Published private(set) var logWeights: [UsageWeight] = []
    private var logsCovered: [ClosedRange<Date>] = []
    private var readingLogs = false
    /// The last month start at which the app saw the budget reset (kept apart from the history).
    private var seenReset: Date?
    private static let seenResetKey = "budgetResetSeen"

    static let interval: TimeInterval = 5 * 60
    private let reader = UsageReader()
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let pathMonitor = NWPathMonitor()
    private var networkWasDown = false

    init(preview: UsageSnapshot? = nil, problem: String? = nil, saved: Bool = false, signedOut previewSignedOut: Bool = false,
         history previewHistory: UsageHistory? = nil, logWeights previewLogs: [UsageWeight]? = nil) {
        if let preview {
            snapshot = preview; oauthProblem = problem; showingSaved = saved; signedOut = previewSignedOut
            if let previewHistory {
                history = previewHistory; logWeights = previewLogs ?? []
            } else if preview.isBudgetOnly {
                (history, logWeights) = UsageHistory.sampleWithLogs(for: preview)
            } else {
                history = UsageHistory.sample(for: preview)   // Pro/Max: no log estimates (see HistoryChart)
            }
            return
        }
        history = UsageHistory.load()
        persistsHistory = true
        SignInNotifier.shared.start(model: self)
        seenReset = UserDefaults.standard.object(forKey: Self.seenResetKey) as? Date
        // The last good numbers, until the first fetch succeeds; the footer says how old they are.
        if let saved = LastUsage.load() {
            snapshot = saved.confirmingAssumedReset(seen: seenReset).withPriorPace(from: history)
            showingSaved = true
        }
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
        // Sample numbers (previews, `--sample`) never fetch: that would replace them with the real
        // ones and overwrite the saved numbers. `persistsHistory` is only set for the real model.
        guard persistsHistory, !isLoading else { return }
        isLoading = true
        let reader = self.reader
        let mayNudge = persistsHistory && lastNudge.map { Date().timeIntervalSince($0) > Self.nudgeSpacing } ?? true
        Task {
            // Keychain access can block on a permission prompt, so keep it off the main actor.
            let (snap, oauthWhy, nudged, needsSignIn) = await Task.detached { () -> (UsageSnapshot?, String?, Bool, Bool) in
                do {
                    return (try await reader.fetchOAuth(saveResponseTo: LastUsage.defaultURL), nil, false, false)
                } catch {
                    var nudge: LoginNudge.Outcome?, renewed = false, last: Error = error
                    if mayNudge && LoginNudge.isExpiredLogin(error) {
                        let r = await Self.nudgeAndRetry(reader)
                        if let s = r.snapshot { return (s, nil, true, false) }
                        (nudge, renewed, last) = (r.outcome, r.renewed, r.retryError ?? error)
                    }
                    let signIn = LoginNudge.signInNeeded(after: last, nudge: nudge, renewed: renewed,
                                                         hasCLI: LoginNudge.claudePath() != nil)
                    let why = UsageError.shortMessage(for: error)
                    return ((try? reader.readSnapshot(maxAge: reader.maxSnapshotAge)), why, nudge != nil, signIn)
                }
            }.value

            if nudged { lastNudge = Date() }
            lastAttempt = Date()
            // Signed out stays until the login works again: between nudges a fetch can't tell.
            if oauthWhy == nil { signedOut = false; endSignIn(); signInProgress = nil } else if needsSignIn { signedOut = true }
            oauthProblem = oauthWhy.map { signedOut ? Self.signedOutMessage : $0 }
            if let snap {
                recordHistory(snap)
                updateSeenReset()
                snapshot = snap.confirmingAssumedReset(seen: seenReset).withPriorPace(from: history)
                showingSaved = false
                error = nil
            } else {
                showingSaved = snapshot != nil
                error = oauthProblem ?? "No usage data"
            }
            SignInNotifier.shared.update(signedOut: signedOut, savedAt: snapshot?.capturedAt)
            isLoading = false
        }
    }

    /// Sign in…: opens Claude Code's own sign-in (`claude auth login`) in Terminal, then watches the
    /// Keychain item's expiry and fetches as soon as there's a new login. The app starts the sign-in
    /// and nothing more: it never sees the command's input or output, and logs only times and outcomes.
    func startSignIn() {
        guard persistsHistory else { return }   // previews never start anything
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UsageMeter")
        let url = dir.appendingPathComponent("sign-in.command")
        // A file the app writes itself isn't quarantined, so it opens without a Gatekeeper prompt;
        // `open` needs no Automation permission (Terminal's `do script` would).
        guard let path = LoginNudge.claudePath(),
              (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              (try? Data(LoginNudge.signInScript(claudePath: path).utf8).write(to: url, options: .atomic)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)) != nil,
              NSWorkspace.shared.open(url)
        else {
            AppLog.write("sign-in: couldn't open Terminal")
            signInProgress = .couldNotOpen
            return
        }
        AppLog.write("sign-in: opened claude auth login in Terminal")
        signInProgress = .waiting
        let deadline = Date().addingTimeInterval(Self.signInWait)
        signInPoll?.invalidate()
        signInPoll = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSignIn(deadline: deadline) }
        }
    }

    /// How long Sign in… keeps watching for the new login.
    static let signInWait: TimeInterval = 10 * 60
    private var checkingSignIn = false

    /// One look at the Keychain item's expiry (the same `security` read as a fetch; the token stays in memory).
    private func checkSignIn(deadline: Date) {
        guard !checkingSignIn else { return }
        checkingSignIn = true
        let reader = self.reader
        Task {
            let validUntil = await Task.detached { () -> Date?? in
                guard let c = try? reader.readCredentials() else { return nil }
                return .some(c.expiresAt)
            }.value
            checkingSignIn = false
            guard signInProgress == .waiting else { return }
            // A login with no expiry counts as valid; the fetch will tell.
            if let validUntil, validUntil.map({ $0 > Date() }) ?? true {
                let f = ISO8601DateFormatter(); f.timeZone = .current
                AppLog.write("sign-in: login valid until \(validUntil.map { f.string(from: $0) } ?? "unknown")")
                endSignIn()
                refresh()
            } else if Date() > deadline {
                AppLog.write("sign-in: no new login after \(Int(Self.signInWait / 60)) min")
                endSignIn()
            }
        }
    }

    private func endSignIn() {
        signInPoll?.invalidate(); signInPoll = nil
        if signInProgress == .waiting { signInProgress = nil }
    }

    /// When the app last asked Claude Code to check its expired login, and how often it may.
    private var lastNudge: Date?
    static let nudgeSpacing: TimeInterval = 30 * 60

    /// What a nudge did: the numbers if it worked; otherwise what the Sign in… check needs.
    struct NudgeResult {
        var snapshot: UsageSnapshot?
        var outcome: LoginNudge.Outcome
        var renewed: Bool
        /// The fetch after a renewal failed (a 401 there means the login was revoked).
        var retryError: Error?
    }

    /// Claude Code's login has expired: runs `claude mcp list` (see LoginNudge.swift) and, if that
    /// renewed the login, fetches again. Logs what happened to ~/Library/Logs/UsageMeter.log
    /// (times only, no account data).
    nonisolated static func nudgeAndRetry(_ reader: UsageReader) async -> NudgeResult {
        let before = (try? reader.readCredentials())?.expiresAt
        let started = Date()
        let outcome = LoginNudge.run()
        let after = (try? reader.readCredentials())?.expiresAt
        let renewed = after.map { $0 > Date() && $0 != before } ?? false
        let f = ISO8601DateFormatter(); f.timeZone = .current
        let line = String(format: "login expired (valid until %@); %@ after %.1f s; login renewed: %@",
                          before.map { f.string(from: $0) } ?? "unknown", outcome.description,
                          Date().timeIntervalSince(started),
                          renewed ? "yes, now valid until \(f.string(from: after!))" : "no")
        AppLog.write(line)
        NSLog("UsageMeter: %@", line)
        guard renewed else { return NudgeResult(outcome: outcome, renewed: false) }
        do {
            return NudgeResult(snapshot: try await reader.fetchOAuth(), outcome: outcome, renewed: true)
        } catch {
            return NudgeResult(outcome: outcome, renewed: true, retryError: error)
        }
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

    /// Windows in display order: session, week, then model-specific weeks (Opus, Sonnet, Fable, …),
    /// then extra usage.
    var orderedWindows: [UsageWindow] {
        guard let s = snapshot else { return [] }
        func rank(_ key: String) -> Int {
            switch key {
            case "five_hour": return 0
            case "seven_day": return 1
            case "extra_usage": return 3
            default: return key.hasPrefix("seven_day_") ? 2 : 4
            }
        }
        return s.windows.sorted { (rank($0.key), $0.key) < (rank($1.key), $1.key) }
    }

    /// The rows shown in the menu bar item, with what the pace colouring needs.
    func menuBarRows(now: Date = Date()) -> [MenuBarImage.Row] {
        guard let s = snapshot else { return [] }
        if s.isBudgetOnly, let w = s.window("extra_usage") {
            return [MenuBarImage.Row(w, label: "$", severity: s.severity["extra_usage"], now: now, asOf: savedAt)]
        }
        return [("five_hour", "5h"), ("seven_day", "7d")].compactMap { key, label in
            s.window(key).map { MenuBarImage.Row($0, label: label, severity: s.severity[key], now: now, asOf: savedAt) }
        }
    }
}

extension UsageModel {
    /// When the numbers shown were fetched, while they're saved ones (rate-limited, offline):
    /// projections run from then, as in the popup.
    var savedAt: Date? { showingSaved ? snapshot?.capturedAt : nil }

    /// The menu bar's extra-usage item on a Pro/Max account, when it has extra usage turned on.
    func extraRow(now: Date = Date()) -> MenuBarImage.Row? {
        guard let s = snapshot, let w = s.extraUsage else { return nil }
        return MenuBarImage.Row(w, label: "$", severity: s.severity["extra_usage"], now: now, asOf: savedAt)
    }

    /// The Compact style's rings, outer first: the budget alone on an Enterprise/Team seat;
    /// otherwise the week, then the 5 h session. The week is the weekly limit (all models, Opus,
    /// Sonnet, …) furthest ahead of pace, so a model-specific week that's about to run out isn't
    /// hidden behind a quiet all-models week.
    func compactRings(now: Date = Date()) -> [MenuBarImage.Row] {
        guard let s = snapshot else { return [] }
        if s.isBudgetOnly { return menuBarRows(now: now) }
        let session = menuBarRows(now: now).filter { $0.label == "5h" }
        return (worstWeek(s, now: now).map { [$0] } ?? []) + session
    }

    private func worstWeek(_ s: UsageSnapshot, now: Date) -> MenuBarImage.Row? {
        let weeks = s.windows.filter { $0.key.hasPrefix("seven_day") && $0.resetsAt != nil }.map { w in
            MenuBarImage.Row(w, label: "7d", severity: s.severity[w.key], now: now, asOf: savedAt)
        }
        func gap(_ r: MenuBarImage.Row) -> Double { r.expected.map { r.percent - $0 } ?? 0 }
        let worst = weeks.max { a, b in
            let (sa, sb) = (MenuBarImage.paceState(a), MenuBarImage.paceState(b))
            return sa != sb ? sa < sb : gap(a) < gap(b)
        }
        return worst
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
        default:
            // A model's own weekly limit: "seven_day_opus" → "Week · Opus", "seven_day_fable" → "Week · Fable".
            if key.hasPrefix("seven_day_") {
                return "Week · " + key.dropFirst("seven_day_".count).replacingOccurrences(of: "_", with: " ").capitalized
            }
            return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
