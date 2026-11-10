// CLI to try both sources:  ./usage [oauth|snapshot|auto]
import Foundation

func show(_ s: UsageSnapshot) {
    let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short
    print("source: \(s.source.rawValue)   captured: \(df.string(from: s.capturedAt))")
    for w in s.windows {
        var extra = w.resetsAt.map { "resets \(df.string(from: $0))" } ?? ""
        if let pace = w.expectedPercent() { extra += String(format: "  pace %.0f%%", pace) }
        if let hit = w.projectedLimitAt() { extra += "  ⚠️ limit ~\(df.string(from: hit))" }
        else if w.resetsAt != nil && w.percent > 0 && !w.isTooEarlyToProject() { extra += "  ok until reset" }
        let name = w.key.padding(toLength: max(w.key.count, 18), withPad: " ", startingAt: 0)
        if let sev = s.severity[w.key] { extra += "  [\(sev)]" }
        print("  \(name) \(String(format: "%5.1f%%", w.percent))  \(extra)")
        print("  \(String(repeating: " ", count: name.count))        → \(w.outlook())")
    }
    for (label, obj) in [("server pace", s.serverPace), ("server indicator", s.serverIndicator)] {
        guard let obj, let d = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]) else { continue }
        print("  \(label): \(String(decoding: d, as: UTF8.self))")
    }
}

let mode = CommandLine.arguments.dropFirst().first ?? "auto"
let reader = UsageReader()
do {
    switch mode {
    case "oauth":    show(try await reader.fetchOAuth())
    case "raw":      print(String(decoding: try await reader.fetchOAuthRaw(), as: UTF8.self))
    case "snapshot": show(try reader.readSnapshot())
    default:
        switch await reader.fetch() {
        case .success(let s): show(s)
        case .failure(let e): throw e
        }
    }
} catch {
    fputs("error: \(error)\n", stderr)
    exit(1)
}
