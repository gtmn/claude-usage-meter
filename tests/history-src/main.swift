import Foundation
// History recording: spacing, resets, stale fallbacks, pruning, file round trip.
var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
func at(_ s: String) -> Date { let f = DateFormatter(); f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"; return f.date(from: s)! }
func snap(_ t: String, _ pairs: [(String, Double)]) -> UsageSnapshot {
  UsageSnapshot(source: .oauth, capturedAt: at(t), windows: pairs.map { UsageWindow(key: $0.0, percent: $0.1, resetsAt: nil) })
}
var failures = 0
func check(_ name: String, _ ok: Bool) { print(ok ? "ok  " : "FAIL", name); if !ok { failures += 1 } }

var h = UsageHistory()
h.record(snap("2026-11-10 10:00", [("five_hour", 10), ("seven_day", 40)]))
h.record(snap("2026-11-10 10:05", [("five_hour", 12), ("seven_day", 40)]))   // 5 min later: skipped
check("first fetch records one point per window", h.series("five_hour", from: .distantPast).count == 1 && h.series("seven_day", from: .distantPast).count == 1)
h.record(snap("2026-11-10 10:10", [("five_hour", 15), ("seven_day", 41)]))   // 10 min: recorded
check("10 minutes later is recorded", h.series("five_hour", from: .distantPast).count == 2)
h.record(snap("2026-11-10 10:12", [("five_hour", 0), ("seven_day", 41)]))    // reset: drop recorded at once
check("a reset (drop) is recorded even within 10 minutes", h.series("five_hour", from: .distantPast).last?.percent == 0)
check("…but the unchanged window is not", h.series("seven_day", from: .distantPast).count == 2)
h.record(snap("2026-11-10 09:00", [("five_hour", 50)]))                       // stale status-line fallback
check("an older snapshot is ignored", h.series("five_hour", from: .distantPast).allSatisfy { $0.percent != 50 })

let spend = Spend(used: Money(minor: 11688, exponent: 2, currency: "USD"), limit: Money(minor: 200000, exponent: 2, currency: "USD"))
var hb = UsageHistory()
hb.record(UsageSnapshot(source: .oauth, capturedAt: at("2026-11-10 17:00"),
                        windows: [UsageWindow(key: "extra_usage", percent: spend.percent, resetsAt: nil, spend: spend)]))
check("budget points keep the money used", hb.points.first?.usedMinor == 11688)

// Old points are kept; past 60 days thinned to the highest point per window per hour.
var hp = UsageHistory(points: [
    HistoryPoint(t: at("2025-06-01 00:00"), key: "seven_day", percent: 5),      // over a year old: kept
    HistoryPoint(t: at("2026-08-01 10:00"), key: "seven_day", percent: 90),     // one hour, three points:
    HistoryPoint(t: at("2026-08-01 10:20"), key: "seven_day", percent: 98),     // the highest stays (the peak
    HistoryPoint(t: at("2026-08-01 10:40"), key: "seven_day", percent: 2),      // before a reset)
    HistoryPoint(t: at("2026-08-01 10:30"), key: "five_hour", percent: 40),     // another window, same hour
    HistoryPoint(t: at("2026-08-01 11:10"), key: "seven_day", percent: 3),      // the next hour: the reset shows
    HistoryPoint(t: at("2026-10-01 10:00"), key: "seven_day", percent: 6),      // under 60 days: full detail
    HistoryPoint(t: at("2026-10-01 10:10"), key: "seven_day", percent: 7)])
hp.record(snap("2026-11-10 12:00", [("seven_day", 8)]))
check("old points are kept, thinned to the hourly peak past 60 days",
      hp.series("seven_day", from: .distantPast).map(\.percent) == [5, 98, 3, 6, 7, 8]
      && hp.series("five_hour", from: .distantPast).map(\.percent) == [40])
var hq = hp; hq.prune(now: at("2026-11-10 12:00"))
check("thinning twice changes nothing", hq == hp)

// Looking back: one summary per reset-to-reset period.
let weekNow = UsageWindow(key: "seven_day", percent: 30, resetsAt: at("2026-11-19 05:00"))
let past = UsageHistory(points: [
    HistoryPoint(t: at("2026-10-30 12:00"), key: "seven_day", percent: 20),    // 29 Oct – 5 Nov: from Thu noon
    HistoryPoint(t: at("2026-11-04 12:00"), key: "seven_day", percent: 70),
    HistoryPoint(t: at("2026-11-06 10:00"), key: "seven_day", percent: 40),    // 5–12 Nov: runs out on the 10th
    HistoryPoint(t: at("2026-11-10 14:00"), key: "seven_day", percent: 100),
    HistoryPoint(t: at("2026-11-11 09:00"), key: "seven_day", percent: 100),
    HistoryPoint(t: at("2026-11-12 06:00"), key: "seven_day", percent: 2),     // 12–19 Nov: this week
    HistoryPoint(t: at("2026-11-15 06:00"), key: "seven_day", percent: 30),
    HistoryPoint(t: at("2026-11-11 09:00"), key: "five_hour", percent: 99)])   // another window: not counted
let ps = past.periods(of: weekNow)
check("periods newest first, one per week with anything recorded",
      ps.map(\.start) == [at("2026-11-12 05:00"), at("2026-11-05 05:00"), at("2026-10-29 05:00")])
check("a week's peak and when it ran out, how early",
      ps[1].peak == 100 && ps[1].ranOutAt == at("2026-11-10 14:00") && ps[1].early == 39 * 3600)
check("a week that didn't run out", ps[2].peak == 70 && ps[2].ranOutAt == nil)
check("how much of a week was recorded", abs(ps[2].covered - 5.0 / 7) < 0.001)
check("no periods without history", UsageHistory().periods(of: weekNow).isEmpty)
let budgetNow = UsageWindow(key: "extra_usage", percent: 10, resetsAt: at("2026-12-01 00:00"),
                            spend: Spend(used: Money(minor: 100, exponent: 2, currency: "USD"),
                                         limit: Money(minor: 1000, exponent: 2, currency: "USD")))
check("budget periods are calendar months",
      UsageHistory.periodStart(of: budgetNow, back: 0) == at("2026-11-01 00:00")
      && UsageHistory.periodStart(of: budgetNow, back: 1) == at("2026-10-01 00:00"))

// Hitting the 5 h limit.
let sessions = UsageHistory(points: [
    HistoryPoint(t: at("2026-11-17 13:00"), key: "five_hour", percent: 60),
    HistoryPoint(t: at("2026-11-17 14:20"), key: "five_hour", percent: 100),    // hit
    HistoryPoint(t: at("2026-11-17 15:50"), key: "five_hour", percent: 100),
    HistoryPoint(t: at("2026-11-17 16:00"), key: "five_hour", percent: 0),      // reset: blocked 1 h 40 min
    HistoryPoint(t: at("2026-11-18 10:00"), key: "five_hour", percent: 99.6),   // hit
    HistoryPoint(t: at("2026-11-18 11:00"), key: "five_hour", percent: 100),
    HistoryPoint(t: at("2026-11-18 19:00"), key: "five_hour", percent: 10),     // asleep: reset time unknown
    HistoryPoint(t: at("2026-11-19 09:00"), key: "seven_day", percent: 100),    // another limit
    HistoryPoint(t: at("2026-11-19 09:30"), key: "five_hour", percent: 100)])   // still at 100%
let hits = sessions.limitHits()
check("each session that reached 100% counts once", hits.map(\.at) == [at("2026-11-17 14:20"), at("2026-11-18 10:00"), at("2026-11-19 09:30")])
check("blocked until the reset", hits[0].resetAt == at("2026-11-17 16:00") && hits[0].blocked == 100 * 60 && !hits[0].atLeast)
check("reset unknown after a gap: at least until the last 100%", hits[1].resetAt == nil && hits[1].atLeast && hits[1].blocked == 3600)
check("still blocked", hits[2].resetSeen == nil)
check("hits within a time span", sessions.limitHits(from: at("2026-11-18 00:00"), to: at("2026-11-19 00:00")).count == 1)

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usagemeter-test-\(getpid())")
let url = dir.appendingPathComponent("history.json")
try! h.save(to: url)
check("save and load round-trip", UsageHistory.load(from: url) == h)
try! Data("not json".utf8).write(to: url)
check("an unreadable file loads as empty", UsageHistory.load(from: url).points.isEmpty)
check("a missing file loads as empty", UsageHistory.load(from: dir.appendingPathComponent("nope.json")).points.isEmpty)
// Filling gaps from Claude Code's logs, and daily totals (UTC days).
func bp(_ t: String, _ minor: Int64) -> HistoryPoint { HistoryPoint(t: at(t), key: "extra_usage", percent: 0, usedMinor: minor) }
let period = at("2026-11-01 00:00")
let recorded = [bp("2026-11-10 18:00", 13000), bp("2026-11-10 18:10", 13100), bp("2026-11-10 22:00", 14000)]
check("the stretch before the first record is a gap, and so is a 4-hour pause",
      UsageHistory.gaps(in: recorded, periodStart: period) == [
        HistoryGap(start: period, end: at("2026-11-10 18:00"), fromMinor: 0, toMinor: 13000),
        HistoryGap(start: at("2026-11-10 18:10"), end: at("2026-11-10 22:00"), fromMinor: 13100, toMinor: 14000)])
let logs = [UsageWeight(t: at("2026-11-02 12:00"), weight: 1), UsageWeight(t: at("2026-11-05 12:00"), weight: 3)]
let filled = UsageHistory.filledBudget(recorded, periodStart: period, weights: logs, limitMinor: 200000)
let est = filled.filter { $0.estimated == true }
check("every filled point is estimated, from the period start at zero",
      filled.allSatisfy { recorded.contains($0) || $0.estimated == true } && est.first?.t == period && est.first?.usedMinor == 0)
check("the estimate is shaped by the logs", filled.first { $0.t == at("2026-11-02 12:00") }?.usedMinor == 3250)
check("…and ends exactly at the first recorded amount", est.filter { $0.t < at("2026-11-10 18:00") }.last?.usedMinor == 13000)
let active = est.filter { $0.idle != true }.map(\.t)
check("only the steps with Claude Code activity are not idle",
      active == [at("2026-11-02 12:00"), at("2026-11-05 12:00")])
let between = filled.first { $0.t == at("2026-11-03 12:00") }
check("quiet time is flat and idle", between?.usedMinor == 3250 && between?.idle == true
      && est.filter { $0.t < at("2026-11-02 12:00") }.allSatisfy { $0.usedMinor == 0 && $0.idle == true })
check("a gap with no log activity stays a gap", filled.allSatisfy { $0.t.isAtOrBefore(at("2026-11-10 18:10")) || recorded.contains($0) })
check("recorded points are kept as they are", recorded.allSatisfy(filled.contains))
check("no logs: nothing is filled", UsageHistory.filledBudget(recorded, periodStart: period, weights: [], limitMinor: 200000) == recorded)

let days = UsageHistory.dailySpend(filled)
func day(_ d: String) -> DaySpend? { days.first { $0.day == at("\(d) 00:00") } }
check("daily totals follow the estimate", day("2026-11-02")?.usedMinor == 3250 && day("2026-11-05")?.usedMinor == 9750)
check("…and say which part is estimated", day("2026-11-05")?.estimatedMinor == 9750 && day("2026-11-10")?.estimatedMinor == 0)
check("the recorded day adds up", day("2026-11-10")?.usedMinor == 1000)
check("quiet days inside the estimate are known zeros", day("2026-11-03")?.usedMinor == 0)
check("all days add up to the total", days.reduce(0) { $0 + $1.usedMinor } == 14000)

let unfilled = UsageHistory.dailySpend(recorded)
check("without an estimate, the first day counts only from the first record",
      unfilled.first?.countsFrom == at("2026-11-10 18:00") && unfilled.first?.usedMinor == 1000)
let pause = UsageHistory.dailySpend([bp("2026-11-07 10:00", 1000), bp("2026-11-09 09:00", 2000)])
check("after days with no data, the next day says what it includes",
      pause.last?.day == at("2026-11-09 00:00") && pause.last?.includesSince == at("2026-11-07 10:00"))
let reset = UsageHistory.dailySpend([bp("2026-11-30 22:00", 5000), bp("2026-11-30 23:00", 5200), bp("2026-12-01 01:00", 300)])
check("after a reset, the new amount counts as spent since it", reset.last?.usedMinor == 300 && reset.first?.usedMinor == 200)

// Seeing the budget reset: a fall close to 00:00 UTC on the 1st confirms the assumed date.
func seen(_ pts: [HistoryPoint]) -> SeenReset { UsageHistory(points: pts).seenBudgetReset() }
check("a fall at 00:00 UTC on the 1st confirms the reset",
      seen([bp("2026-11-30 23:40", 19000), bp("2026-11-30 23:50", 19050), bp("2026-12-01 00:05", 0)]) == .monthStart(at("2026-12-01 00:00")))
check("the fall may land a little after midnight with some spending",
      seen([bp("2026-11-30 23:55", 19000), bp("2026-12-01 00:15", 400)]) == .monthStart(at("2026-12-01 00:00")))
check("no fall: nothing seen", seen([bp("2026-11-30 23:50", 19000), bp("2026-12-01 00:05", 19100)]) == .unknown)
check("asleep over midnight: too long a gap to tell",
      seen([bp("2026-11-30 22:00", 19000), bp("2026-12-01 07:00", 0)]) == .unknown)
check("a fall in mid-month says the assumption is wrong",
      seen([bp("2026-12-14 09:00", 5000), bp("2026-12-14 09:10", 0)]) == .elsewhere(at("2026-12-14 09:10")))
check("a small correction isn't a reset", seen([bp("2026-12-14 09:00", 5000), bp("2026-12-14 09:10", 4990)]) == .unknown)
check("estimated points never count",
      seen([bp("2026-11-30 23:55", 19000), HistoryPoint(t: at("2026-12-01 00:05"), key: "extra_usage", percent: 0, usedMinor: 0, estimated: true)]) == .unknown)
check("the newest fall wins",
      seen([bp("2026-11-14 09:00", 5000), bp("2026-11-14 09:10", 0), bp("2026-11-30 23:55", 9000), bp("2026-12-01 00:05", 10)]) == .monthStart(at("2026-12-01 00:00")))

let budget = Spend(used: Money(minor: 100, exponent: 2, currency: "USD"), limit: Money(minor: 200000, exponent: 2, currency: "USD"))
let assumed = UsageSnapshot(source: .oauth, capturedAt: at("2026-12-02 10:00"), windows: [
  UsageWindow(key: "extra_usage", percent: 0.05, resetsAt: at("2027-01-01 00:00"), spend: budget, resetIsAssumed: true)])
let confirmed = assumed.confirmingAssumedReset(seen: at("2026-12-01 00:00")).window("extra_usage")
check("a seen reset drops (assumed) and keeps the date",
      confirmed?.resetIsAssumed == false && confirmed?.resetSeen == at("2026-12-01 00:00") && confirmed?.resetsAt == at("2027-01-01 00:00"))
check("nothing seen: still assumed", assumed.confirmingAssumedReset(seen: nil).window("extra_usage")?.resetIsAssumed == true)
var weekly = budget; weekly.period = "weekly"
let weeklySnap = UsageSnapshot(source: .oauth, capturedAt: at("2026-12-02 10:00"), windows: [
  UsageWindow(key: "extra_usage", percent: 0.05, resetsAt: at("2026-12-07 00:00"), spend: weekly, resetIsAssumed: true)])
check("a monthly reset says nothing about a weekly budget",
      weeklySnap.confirmingAssumedReset(seen: at("2026-12-01 00:00")).window("extra_usage")?.resetIsAssumed == true)

// Last period's pace: early projections start from it instead of "Too early to project".
let dec = UsageWindow(key: "extra_usage", percent: 0.75, resetsAt: at("2027-01-01 00:00"),
                      spend: Spend(used: Money(minor: 1500, exponent: 2, currency: "USD"), limit: Money(minor: 200000, exponent: 2, currency: "USD")))
let nov = UsageHistory(points: [bp("2026-11-10 12:00", 20000), bp("2026-11-30 23:50", 60000), bp("2026-12-01 00:05", 0)])
let novPace = nov.priorPace(for: dec)
check("last month's pace: November's total over the time it covers",
      novPace.map { abs($0 - 30 / at("2026-11-30 23:50").timeIntervalSince(at("2026-11-01 00:00"))) < 1e-12 } ?? false)
check("no pace when the history covers less than a quarter of last month",
      UsageHistory(points: [bp("2026-11-06 12:00", 20000)]).priorPace(for: dec) == nil)
check("a third of last month is enough",
      UsageHistory(points: [bp("2026-11-10 12:00", 20000)]).priorPeriod(for: dec)?.back == 1)
check("no pace for the 5 h session", nov.priorPace(for: UsageWindow(key: "five_hour", percent: 5, resetsAt: at("2026-12-01 05:00"))) == nil)
var early = dec; early.priorPace = novPace
let day1 = at("2026-12-01 03:00")
check("3 h into the month: projects instead of 'too early'",
      !early.isTooEarlyToProject(now: day1) && early.projectsFromPriorPace(now: day1) && dec.isTooEarlyToProject(now: day1))
let endPct = early.projectedPercentAtReset(now: day1) ?? 0
check("…to about last month's total plus a little for the busy start (\(Int(endPct * 20))$)", (31...40).contains(endPct))
check("…and says so", early.outlook(now: day1, calendar: cal) == "At last month's pace: about $720 by the reset")
let rampEnd = at("2026-12-01 00:00").addingTimeInterval(31 * 86400 * 0.15)
var atRamp = early; atRamp = UsageWindow(key: "extra_usage", percent: 10, resetsAt: early.resetsAt, spend: early.spend, priorPace: novPace)
check("at 15% of the month the pace is this month's own (no jump)",
      abs((atRamp.projectionPace(now: rampEnd) ?? 0) - 10 / rampEnd.timeIntervalSince(at("2026-12-01 00:00"))) < 1e-12)
var heavy = early; heavy.priorPace = 150 / (30 * 86400.0)
check("a heavy last month projects running out, in plain words",
      heavy.outlook(now: day1, calendar: cal).hasPrefix("At last month's pace: runs out") && heavy.projectedLimitAt(now: day1) != nil)
var fresh = early; fresh = UsageWindow(key: "extra_usage", percent: 0, resetsAt: early.resetsAt, spend: early.spend, priorPace: novPace)
check("right after the reset, with nothing spent yet, it still projects",
      fresh.outlook(now: at("2026-12-01 00:10"), calendar: cal).hasPrefix("At last month's pace: about"))
let wk = UsageHistory(points: [HistoryPoint(t: at("2026-11-11 04:50"), key: "seven_day", percent: 70)])
var week = UsageWindow(key: "seven_day", percent: 4, resetsAt: at("2026-11-18 05:00"))
week.priorPace = wk.priorPace(for: week)
check("the weekly limit uses last week's final percentage",
      week.outlook(now: at("2026-11-11 09:00"), calendar: cal).hasPrefix("At last week's pace:"))
// Last week barely recorded (Mac off): the week before stands in, and the outlook says so.
let older = UsageHistory(points: [HistoryPoint(t: at("2026-11-03 20:00"), key: "seven_day", percent: 50),
                                  HistoryPoint(t: at("2026-11-04 06:00"), key: "seven_day", percent: 2)])
let olderPrior = older.priorPeriod(for: week)
check("an earlier week stands in when last week has too little (\(olderPrior?.back ?? 0) back)",
      olderPrior?.back == 2 && olderPrior.map { abs($0.pace - 50 / at("2026-11-03 20:00").timeIntervalSince(at("2026-10-28 05:00"))) < 1e-12 } ?? false)
var weekOlder = week; weekOlder.priorPace = olderPrior?.pace; weekOlder.priorPeriodsBack = olderPrior?.back ?? 1
check("…and the outlook names it as an earlier week",
      weekOlder.outlook(now: at("2026-11-11 09:00"), calendar: cal).hasPrefix("At an earlier week's pace:"))
check("no stand-in beyond what the history holds",
      UsageHistory(points: [HistoryPoint(t: at("2026-11-04 06:00"), key: "seven_day", percent: 2)]).priorPeriod(for: week) == nil)

// Saved numbers: the outlook projects from when they were fetched, not from now.
let novBudget = UsageWindow(key: "extra_usage", percent: 14.519, resetsAt: at("2026-12-01 00:00"),
                            spend: Spend(used: Money(minor: 29038, exponent: 2, currency: "USD"), limit: Money(minor: 200000, exponent: 2, currency: "USD")))
let fetched = at("2026-11-13 23:11"), monday = at("2026-11-16 09:00")
check("saved numbers project at the pace up to their fetch time",
      novBudget.outlook(now: monday, asOf: fetched, calendar: cal) == "Lasts until the reset — on track for about $670")
check("…while treating them as current projects lower (no spending since)",
      (novBudget.projectedPercentAtReset(now: monday) ?? 0) < (novBudget.projectedPercentAtReset(now: fetched) ?? 0))
let fast = UsageWindow(key: "seven_day", percent: 80, resetsAt: at("2026-11-17 05:00"))
check("saved numbers whose pace ran out since: may be used up by now",
      fast.outlook(now: at("2026-11-16 20:00"), asOf: at("2026-11-14 05:00"), calendar: cal).hasPrefix("At that pace it may be used up by now"))

// The log reader: dedupes streamed lines, skips unpriced models and times outside the range.
let logDir = dir.appendingPathComponent("projects/p")
try! FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
func line(_ id: String, _ ts: String, _ model: String) -> String {
  #"{"type":"assistant","timestamp":"\#(ts)","requestId":"r\#(id)","message":{"id":"m\#(id)","model":"\#(model)","content":[{"type":"text","text":"never read"}],"usage":{"input_tokens":1000,"output_tokens":1000,"cache_read_input_tokens":1000000,"cache_creation_input_tokens":1000,"cache_creation":{"ephemeral_1h_input_tokens":1000,"ephemeral_5m_input_tokens":0}}}}"#
}
let jsonl = [line("1", "2026-11-05T10:00:00.000Z", "claude-opus-5-5"), line("1", "2026-11-05T10:00:00.000Z", "claude-opus-5-5"),
             line("2", "2026-11-05T11:00:00Z", "<synthetic>"), line("3", "2026-10-20T10:00:00.000Z", "claude-sonnet-5-5"),
             #"{"type":"user","message":{"content":"hi"}}"#, "not json"].joined(separator: "\n")
try! Data(jsonl.utf8).write(to: logDir.appendingPathComponent("s.jsonl"))
let w = ClaudeCodeLogs.weights(from: period, to: at("2026-11-11 00:00"), root: dir.appendingPathComponent("projects"))
check("log reader counts each request once, priced models only, in range only", w.count == 1 && w.first?.t == at("2026-11-05 10:00"))
check("list-price cost of an Opus 5.5 request", abs((w.first?.weight ?? 0) - 0.232) < 1e-9)
check("unknown versions are priced by family", ClaudeCodeLogs.cost(model: "claude-opus-9", usage: ["output_tokens": 1_000_000]) == 20)
try? FileManager.default.removeItem(at: dir)

// MARK: Last good response
let lastURL = FileManager.default.temporaryDirectory.appendingPathComponent("usage-meter-last-\(UUID().uuidString).json")
let response = #"{"five_hour":{"utilization":35,"resets_at":"2026-11-12T22:00:00Z"},"seven_day":{"utilization":22,"resets_at":"2026-11-19T04:00:00Z"},"account_note":{"name":"someone"},"spend":{"used":{"amount_minor":1},"limit":{"amount_minor":2},"balance":{"amount_minor":777}},"limits":[]}"#
LastUsage.save(Data(response.utf8), capturedAt: at("2026-11-12 18:00"), to: lastURL)
let savedText = (try? String(contentsOf: lastURL, encoding: .utf8)) ?? ""
check("last response keeps only the usage part", savedText.contains("seven_day") && !savedText.contains("someone") && !savedText.contains("777"))
let soon = LastUsage.load(from: lastURL, now: at("2026-11-12 19:00"))
check("loads both limits before any reset, with the original time",
      soon?.windows.map(\.key) == ["five_hour", "seven_day"] && soon?.capturedAt == at("2026-11-12 18:00"))
let later = LastUsage.load(from: lastURL, now: at("2026-11-13 09:00"))
check("leaves out the session once it has reset", later?.windows.map(\.key) == ["seven_day"] && later?.windows.first?.percent == 22)
check("nothing once every limit has reset", LastUsage.load(from: lastURL, now: at("2026-11-20 09:00")) == nil)
check("nothing without a file", LastUsage.load(from: lastURL.appendingPathExtension("missing")) == nil)
try? FileManager.default.removeItem(at: lastURL)

print(failures == 0 ? "history: all passed" : "history: \(failures) failed")
// The menu bar's amount: whole units, rounded down (what has been spent, not more), no thousands separator.
check("whole units for the menu bar",
      Money(minor: 41280, exponent: 2, currency: "USD").wholeUnits == "$412"
      && Money(minor: 100099, exponent: 2, currency: "EUR").wholeUnits == "€1000"
      && Money(minor: 99, exponent: 2, currency: "USD").wholeUnits == "$0")

exit(failures == 0 ? 0 : 1)
