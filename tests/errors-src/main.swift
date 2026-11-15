import AppKit
let cases: [(String, Error)] = [
  ("-1009 offline", URLError(.notConnectedToInternet)), ("lost", URLError(.networkConnectionLost)),
  ("timeout", URLError(.timedOut)), ("dns", URLError(.cannotFindHost)), ("other url", URLError(.badServerResponse)),
  ("expired", UsageError.tokenExpired(Date())), ("none", UsageError.noCredentials), ("401", UsageError.http(401)),
  ("429", UsageError.http(429)), ("503", UsageError.http(503)), ("418", UsageError.http(418)),
  ("bad", UsageError.badResponse("x")), ("no snap", UsageError.noSnapshot),
]
for (n, e) in cases { print(n.padding(toLength: 14, withPad: " ", startingAt: 0), "→", UsageError.shortMessage(for: e)) }
print("--- widths at 11 pt (popup inner width: 326)")
let f = NSFont.systemFont(ofSize: 11)
for s in ["Runs out Wednesday afternoon, 3 days before Saturday's reset",
          "Runs out Wednesday night, 2 h before Thursday's reset",
          "Runs out around 01:52, 40 min before the reset at 03:20",
          "Lasts until the reset at 14:00 — on track for about 45%",
          "Lasts until Wednesday's reset — on track for about 100%",
          "Limit reached — resets Wednesday afternoon",
          "Lasts until the 1 Dec reset — on track for about $1,990",
          "Runs out on 24 Nov, 7 days before the 1 Dec reset",
          "Too early to project — resets on 1 Dec",
          "Budget used up — resets on 1 Dec",
          "At last month's pace: about $1,990 by the 1 Jan reset",
          "At last week's pace: about 100% by Wednesday's reset",
          "At last month's pace: runs out Wednesday afternoon",
          "At last month's pace: runs out on 24 Dec"] {
  print(Int((s as NSString).size(withAttributes: [.font: f]).width), s)
}

print("--- expired login: which errors run claude mcp list")
var nudgeFailures = 0
for (name, e, want) in [("expired", UsageError.tokenExpired(Date()) as Error, true), ("401", UsageError.http(401), true),
                        ("403", UsageError.http(403), false), ("offline", URLError(.notConnectedToInternet), false),
                        ("none", UsageError.noCredentials, false)] {
  let ok = LoginNudge.isExpiredLogin(e) == want
  if !ok { nudgeFailures += 1 }
  print(ok ? "ok  " : "FAIL", name, want ? "→ nudge" : "→ no nudge")
}
print("claude command:", LoginNudge.claudePath() ?? "not found")
func expect(_ name: String, _ ok: Bool) { if !ok { nudgeFailures += 1 }; print(ok ? "ok  " : "FAIL", name) }
expect("the log line names the command", LoginNudge.Outcome.exited(0).description == "claude mcp list exited with 0")
let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("usagemeter-log-test/UsageMeter.log")
try? FileManager.default.removeItem(at: logURL)
AppLog.write("first", to: logURL); AppLog.write("second", to: logURL)
let logText = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
expect("log lines are appended with a time", logText.split(separator: "\n").count == 2 && logText.hasSuffix(" second\n"))
for i in 0..<4000 { AppLog.write("line \(i) " + String(repeating: "x", count: 60), to: logURL) }
let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int) ?? 0
let trimmed = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
expect("a big log drops its oldest half (\(size) bytes)", size <= AppLog.maxBytes + 200 && !trimmed.contains(" first\n") && trimmed.hasSuffix(" line 3999 " + String(repeating: "x", count: 60) + "\n"))
try? FileManager.default.removeItem(at: logURL.deletingLastPathComponent())
exit(nudgeFailures == 0 ? 0 : 1)
