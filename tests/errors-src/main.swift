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
          "Lasts until the reset — on track for about 45%",
          "Lasts until the reset — on track for about 100%",
          "Limit reached — resets Wednesday afternoon",
          "Limit reached — resets at 13:50, in 1 h 10 min",
          "Limit reached — resets Wednesday at 05:00",
          "Lasts until the reset — on track for about $1,990",
          "Runs out on 24 Nov, 7 days before the 1 Dec reset",
          "Too early to project",
          "Budget used up — resets on 1 Dec",
          "At last month's pace: about $1,990 by the reset",
          "At last week's pace: about 100% by the reset",
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

print("--- update check")
expect("0.1.10 is newer than 0.1.9", UpdateCheck.isNewer("0.1.10", than: "0.1.9"))
expect("the same version isn't newer", !UpdateCheck.isNewer("0.1.11", than: "0.1.11") && !UpdateCheck.isNewer("0.1.11", than: "0.1.11.0"))
expect("an older one isn't", !UpdateCheck.isNewer("0.1.9", than: "0.1.10"))
expect("a dev build is never offered one", !UpdateCheck.isNewer("0.2.0", than: "0.1.11-3-gabc1234-dirty") && UpdateCheck.numbers("0.1.11-3-gabc1234") == nil)
let latestJSON = Data(#"{"tag_name": "v0.1.12", "name": "Usage Meter 0.1.12", "draft": false}"#.utf8)
let rel = UpdateCheck.release(fromLatest: latestJSON)
expect("the latest release is read from its tag", rel?.version == "0.1.12")
expect("…with its files named as package.sh makes them",
       rel?.appZip.absoluteString == "https://github.com/gtmn/claude-usage-meter/releases/download/v0.1.12/UsageMeter-0.1.12.zip"
       && rel?.sums.lastPathComponent == "SHA256SUMS.txt" && rel?.page.absoluteString.hasSuffix("/releases/tag/v0.1.12") == true)
expect("a tag that isn't a version is ignored", UpdateCheck.release(fromLatest: Data(#"{"tag_name": "nightly"}"#.utf8)) == nil)
let formula = """
class ClaudeUsageMeter < Formula
  homepage "https://github.com/gtmn/claude-usage-meter"
  url "https://github.com/gtmn/claude-usage-meter/archive/refs/tags/v0.1.13.tar.gz"
  sha256 "cdd6"
  head "https://github.com/gtmn/claude-usage-meter.git", branch: "main"
"""
expect("a Homebrew copy reads the version from the tap's formula", UpdateCheck.release(fromFormula: formula)?.version == "0.1.13")
expect("…and nothing from a formula without a tagged url",
       UpdateCheck.release(fromFormula: "class X < Formula\n  url \"https://example.com/x.tar.gz\"\n") == nil)
let sums = "AB12  claude-usage-0.1.12.zip\ncd34  UsageMeter-0.1.12.zip\n"
expect("the zip's checksum is found in SHA256SUMS.txt", UpdateCheck.checksum(for: "UsageMeter-0.1.12.zip", in: sums) == "cd34"
       && UpdateCheck.checksum(for: "missing.zip", in: sums) == nil)
let sumFile = FileManager.default.temporaryDirectory.appendingPathComponent("usagemeter-sha-test")
try? Data("abc".utf8).write(to: sumFile)
expect("sha256 of a file", (try? UpdateCheck.sha256(of: sumFile)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
let now = Date(timeIntervalSince1970: 1_800_000_000)
expect("never checked: due", UpdateCheck.isDue(last: nil, now: now))
expect("checked 23 h ago: not due", !UpdateCheck.isDue(last: now.addingTimeInterval(-23 * 3600), now: now))
expect("checked 24 h ago: due", UpdateCheck.isDue(last: now.addingTimeInterval(-24 * 3600), now: now))
expect("last check in the future (clock moved back): due", UpdateCheck.isDue(last: now.addingTimeInterval(3600), now: now))
try? FileManager.default.removeItem(at: sumFile)
exit(nudgeFailures == 0 ? 0 : 1)
