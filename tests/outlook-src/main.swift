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
