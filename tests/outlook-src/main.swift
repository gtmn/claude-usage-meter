import Foundation
var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
func at(_ s: String) -> Date { let f = DateFormatter(); f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"; return f.date(from: s)! }
let now = at("2026-11-08 00:49")  // Sunday just after midnight
let cases: [(String, UsageWindow, Date)] = [
  ("weekly 48%",         UsageWindow(key: "seven_day", percent: 48, resetsAt: at("2026-11-12 05:00")), now),
  ("5h 19%",             UsageWindow(key: "five_hour", percent: 19, resetsAt: at("2026-11-08 03:20")), now),
  ("5h burning fast",    UsageWindow(key: "five_hour", percent: 70, resetsAt: at("2026-11-08 03:20")), now),
  ("weekly very heavy",  UsageWindow(key: "seven_day", percent: 80, resetsAt: at("2026-11-12 05:00")), now),
  ("weekly safe",        UsageWindow(key: "seven_day", percent: 20, resetsAt: at("2026-11-12 05:00")), now),
  ("weekly fresh 0%",    UsageWindow(key: "seven_day", percent: 0,  resetsAt: at("2026-11-14 05:00")), now),
  ("limit reached",      UsageWindow(key: "seven_day", percent: 100, resetsAt: at("2026-11-12 05:00")), now),
  ("hit this evening",   UsageWindow(key: "seven_day", percent: 90, resetsAt: at("2026-11-09 10:00")), at("2026-11-08 09:00")),
  ("hit tomorrow morn.", UsageWindow(key: "seven_day", percent: 75, resetsAt: at("2026-11-10 10:00")), at("2026-11-08 09:00")),
]
for (name, w, n) in cases { print(name.padding(toLength: 20, withPad: " ", startingAt: 0), "→", w.outlook(now: n, calendar: cal)) }
print("--- edge cases")
print("same night, after midnight →", UsageWindow(key: "five_hour", percent: 60, resetsAt: at("2026-11-08 04:30")).outlook(now: at("2026-11-08 01:30"), calendar: cal))
print("hit 02:00 tonight at 22:00 →", UsageWindow(key: "seven_day", percent: 95, resetsAt: at("2026-11-09 12:00")).outlook(now: at("2026-11-07 22:00"), calendar: cal))
print("--- early window (first 15%)")
let r5 = at("2026-11-08 15:00")   // 5h window started 10:00; 15% = 10:45
print("5h 5% at +10 min    →", UsageWindow(key: "five_hour", percent: 5, resetsAt: r5).outlook(now: at("2026-11-08 10:10"), calendar: cal), "| projected:", UsageWindow(key: "five_hour", percent: 5, resetsAt: r5).projectedLimitAt(now: at("2026-11-08 10:10")) != nil)
print("5h 30% at +44 min   →", UsageWindow(key: "five_hour", percent: 30, resetsAt: r5).outlook(now: at("2026-11-08 10:44"), calendar: cal))
print("5h 30% at +45 min   →", UsageWindow(key: "five_hour", percent: 30, resetsAt: r5).outlook(now: at("2026-11-08 10:45"), calendar: cal))
print("5h 100% at +20 min  →", UsageWindow(key: "five_hour", percent: 100, resetsAt: r5).outlook(now: at("2026-11-08 10:20"), calendar: cal))
print("week 6% at +12 h    →", UsageWindow(key: "seven_day", percent: 6, resetsAt: at("2026-11-15 05:00")).outlook(now: at("2026-11-08 17:00"), calendar: cal))
print("week 0% at +12 h    →", UsageWindow(key: "seven_day", percent: 0, resetsAt: at("2026-11-15 05:00")).outlook(now: at("2026-11-08 17:00"), calendar: cal))
print("--- monthly $ budget (Enterprise seat: no 5h/7d windows)")
func parse(_ json: String) -> UsageSnapshot { try! UsageReader.parseOAuth(Data(json.utf8), now: now) }
func describe(_ s: UsageSnapshot) {
  for w in s.windows {
    let money = w.spend.map { "\($0.used.formatted) of \($0.limit.formatted), \($0.remaining.formatted) left" } ?? "no $"
    print("  \(w.key.padding(toLength: 12, withPad: " ", startingAt: 0)) \(String(format: "%5.1f%%", w.percent))  \(money)  → \(w.outlook(now: now, calendar: cal))")
  }
  if !s.severity.isEmpty { print("  severity:", s.severity.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) }
}
let enterprise = """
{"five_hour":null,"seven_day":null,"limits":[],
 "extra_usage":{"is_enabled":true,"monthly_limit":200000,"used_credits":11688.0,"utilization":5.844,"currency":"USD","decimal_places":2,"spend_limit_reached":false},
 "spend":{"used":{"amount_minor":11688,"currency":"USD","exponent":2},"limit":{"amount_minor":200000,"currency":"USD","exponent":2},"percent":6,"severity":"normal"}}
"""
print("enterprise, spend block:"); describe(parse(enterprise))
print("enterprise, extra_usage only (fallback):")
describe(parse(#"{"extra_usage":{"monthly_limit":200000,"used_credits":11688.0,"utilization":5.844,"currency":"USD","decimal_places":2}}"#))
print("budget used up:")
describe(parse(#"{"extra_usage":{"monthly_limit":50000,"used_credits":50000,"utilization":100,"currency":"USD","decimal_places":2,"spend_limit_reached":true},"spend":{"used":{"amount_minor":50000,"currency":"USD","exponent":2},"limit":{"amount_minor":50000,"currency":"USD","exponent":2},"severity":"critical"}}"#))
print("Pro/Max with extra usage on (windows stay, $ added to extra_usage):")
describe(parse(#"{"five_hour":{"utilization":19,"resets_at":"2026-11-08T03:20:00Z"},"seven_day":{"utilization":48,"resets_at":"2026-11-12T05:00:00Z"},"extra_usage":{"monthly_limit":2000,"used_credits":350,"utilization":17.5,"currency":"EUR","decimal_places":2}}"#))
print("currencies:", [Money(minor: 123456789, exponent: 2, currency: "USD"), Money(minor: 5000, exponent: 2, currency: "CHF"), Money(minor: 1200, exponent: 0, currency: "JPY")].map(\.formatted).joined(separator: " | "))
print("--- monthly budget projection (reset assumed 00:00 UTC on the 1st)")
func budget(_ usedCents: Int, of limitCents: Int, at when: String, reached: Bool = false) {
  let n = at(when)
  let json = #"{"extra_usage":{"utilization":\#(Double(usedCents) / Double(limitCents) * 100),"spend_limit_reached":\#(reached)},"spend":{"used":{"amount_minor":\#(usedCents),"currency":"USD","exponent":2},"limit":{"amount_minor":\#(limitCents),"currency":"USD","exponent":2}}}"#
  let w = try! UsageReader.parseOAuth(Data(json.utf8), now: n).window("extra_usage")!
  let pace = w.expectedPercent(now: n).map { String(format: "pace %4.1f%%", $0) } ?? "no pace"
  print("  \(when)  \(w.spend!.used.formatted.padding(toLength: 9, withPad: " ", startingAt: 0)) \(pace)  assumed=\(w.resetIsAssumed)  → \(w.outlook(now: n, calendar: cal))")
}
budget(11688, of: 200000, at: "2026-11-10 17:00")   // this laptop today
budget(11688, of: 200000, at: "2026-11-08 00:49")
budget(3000,  of: 200000, at: "2026-11-02 10:00")   // day 2: too early
budget(130000, of: 200000, at: "2026-11-15 12:00")  // heavy: runs out before 1 Dec
budget(190000, of: 200000, at: "2026-11-29 20:00")  // near the end: runs out tomorrow?
budget(200000, of: 200000, at: "2026-11-20 09:00", reached: true)
budget(5000,  of: 200000, at: "2026-12-31 23:30")   // reset rolls into next year
budget(0,     of: 200000, at: "2026-11-10 17:00")
print("--- confirmed budget reset (no \"(assumed)\")")
let nowB = at("2026-11-10 17:00")
let budgetJSON = #"{"extra_usage":{"utilization":5.844},"spend":{"used":{"amount_minor":11688,"currency":"USD","exponent":2},"limit":{"amount_minor":200000,"currency":"USD","exponent":2}}}"#
func show(_ label: String, _ s: UsageSnapshot, _ n: Date = nowB) {
  let w = s.window("extra_usage")!
  let f = DateFormatter(); f.timeZone = cal.timeZone; f.dateFormat = "yyyy-MM-dd HH:mm"
  print("  \(label.padding(toLength: 30, withPad: " ", startingAt: 0)) reset \(w.resetsAt.map(f.string) ?? "-") assumed=\(w.resetIsAssumed) period=\(w.spend?.period ?? "-")  → \(w.outlook(now: n, calendar: cal))")
}
let plain = try! UsageReader.parseOAuth(Data(budgetJSON.utf8), now: nowB)
show("usage endpoint only", plain)
let withRow = #"{"extra_usage":{"utilization":5.844},"spend":{"used":{"amount_minor":11688,"currency":"USD","exponent":2},"limit":{"amount_minor":200000,"currency":"USD","exponent":2}},"limits":[{"kind":"spend","group":"monthly","percent":6,"resets_at":"2026-11-25T00:00:00.000Z","severity":"normal","is_active":true}]}"#
show("limits row (spend, monthly)", try! UsageReader.parseOAuth(Data(withRow.utf8), now: nowB))
func statusLine(_ json: String) -> UsageSnapshot { try! UsageReader.parseSnapshot(Data(json.utf8)) }
let slFuture = statusLine(#"{"captured_at":1762000000,"rate_limits":{"spend_limit":{"used_percentage":5,"resets_at":\#(Int(at("2026-12-01 00:00").timeIntervalSince1970)),"used_usd":110.5,"limit_usd":2000,"period":"monthly"}}}"#)
show("status line, reset 1 Dec", UsageReader.confirmingBudgetReset(plain, from: slFuture, now: nowB))
let slPast = statusLine(#"{"captured_at":1759000000,"rate_limits":{"spend_limit":{"used_percentage":90,"resets_at":\#(Int(at("2026-11-01 00:00").timeIntervalSince1970))}}}"#)
show("status line, reset passed", UsageReader.confirmingBudgetReset(plain, from: slPast, now: nowB))
let slWeekly = statusLine(#"{"captured_at":1762780000,"rate_limits":{"spend_limit":{"used_percentage":5,"resets_at":\#(Int(at("2026-11-16 00:00").timeIntervalSince1970)),"used_usd":110,"limit_usd":2000,"period":"weekly"}}}"#)
show("status line, weekly cap", UsageReader.confirmingBudgetReset(plain, from: slWeekly, now: nowB))
show("no status line file", UsageReader.confirmingBudgetReset(plain, from: nil, now: nowB))
let slOnly = slFuture.window("extra_usage")!
print("  status-line fallback window: \(slOnly.spend.map { "\($0.used.formatted) of \($0.limit.formatted)" } ?? "no $"), \(String(format: "%.0f%%", slOnly.percent)), assumed=\(slOnly.resetIsAssumed)")
