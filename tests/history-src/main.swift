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

var hp = UsageHistory(points: [HistoryPoint(t: at("2026-09-01 00:00"), key: "seven_day", percent: 5),
                               HistoryPoint(t: at("2026-10-15 00:00"), key: "seven_day", percent: 6)])
hp.record(snap("2026-11-10 12:00", [("seven_day", 7)]))
check("points older than 40 days are pruned", hp.points.map(\.percent) == [6, 7])

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
check("estimated points start at zero and are shaped by the logs",
      est.first?.usedMinor == 0 && est.first { $0.t > at("2026-11-03 00:00") }?.usedMinor == 3250)
check("…and end exactly at the first recorded amount", est.filter { $0.t < at("2026-11-10 18:00") }.last?.usedMinor == 13000)
check("a gap with no log activity stays a gap", est.allSatisfy { $0.t < at("2026-11-10 18:00") })
check("recorded points are kept as they are", filled.filter { $0.estimated != true } == recorded)
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

print(failures == 0 ? "history: all passed" : "history: \(failures) failed")
exit(failures == 0 ? 0 : 1)
