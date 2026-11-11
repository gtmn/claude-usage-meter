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
          "Budget used up — resets on 1 Dec"] {
  print(Int((s as NSString).size(withAttributes: [.font: f]).width), s)
}
