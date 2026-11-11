// ClaudeCodeLogs.swift
// When the app has no recorded history for a stretch of the budget period (before it first ran,
// or while the Mac was off), the shape of the curve is estimated from Claude Code's own session
// logs on this Mac (~/.claude/projects/**/*.jsonl). Only each request's time, model, ids and
// token counts are read; message content is never kept. The result is a list-price cost per
// request, used only as a relative weight: the curve is always scaled to the real total.

import Foundation

public enum ClaudeCodeLogs {
    public static var defaultRoot: URL {
        if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("projects")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// Per-request weights between two times, oldest first. Files last changed before `from` are skipped.
    public static func weights(from: Date, to: Date, root: URL = defaultRoot) -> [UsageWeight] {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                         options: [.skipsHiddenFiles]) else { return [] }
        var seen = Set<String>()
        var out: [UsageWeight] = []
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        let usageTag = Data("\"usage\"".utf8)
        for case let url as URL in files where url.pathExtension == "jsonl" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < from { continue }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            for line in data.split(separator: 0x0A) where line.range(of: usageTag) != nil {
                guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      o["type"] as? String == "assistant",
                      let msg = o["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any],
                      let ts = o["timestamp"] as? String,
                      let t = iso.date(from: ts) ?? isoPlain.date(from: ts),
                      t.isAtOrAfter(from), t.isAtOrBefore(to) else { continue }
                // Streaming writes the same response on several lines: count each once.
                let id = "\(msg["id"] as? String ?? "")|\(o["requestId"] as? String ?? "")"
                if id != "|" { guard seen.insert(id).inserted else { continue } }
                guard let w = cost(model: msg["model"] as? String ?? "", usage: usage), w > 0 else { continue }
                out.append(UsageWeight(t: t, weight: w))
            }
        }
        return out.sorted { $0.t < $1.t }
    }

    /// List prices in $ per million tokens: input, output, cache-read share of input.
    /// Cache writes cost 1.25x input (5-minute) or 2x (1-hour). Longest match wins.
    static let prices: [(String, (Double, Double, Double))] = [
        ("fable-5-2", (8, 40, 0.025)), ("mythos-5-2", (8, 40, 0.025)),
        ("fable-5-1", (10, 50, 0.025)), ("mythos-5-1", (10, 50, 0.025)),
        ("fable-5", (10, 50, 0.1)), ("mythos-5", (10, 50, 0.1)),
        ("opus-5-5", (4, 20, 0.05)), ("opus-5", (5, 25, 0.1)), ("opus-4", (5, 25, 0.1)),
        ("sonnet-5-5", (2, 10, 0.05)), ("sonnet-5", (2, 10, 0.1)), ("sonnet-4", (3, 15, 0.1)),
        ("haiku-5-5", (0.1, 0.5, 0.1)), ("haiku-4", (1, 5, 0.1)),
        // Unknown versions: price by family.
        ("fable", (8, 40, 0.025)), ("mythos", (8, 40, 0.025)), ("opus", (4, 20, 0.05)),
        ("sonnet", (2, 10, 0.05)), ("haiku", (0.1, 0.5, 0.1)),
    ]

    /// Estimated list-price cost of one request in $, or nil for a model that isn't priced (e.g. `<synthetic>`).
    public static func cost(model: String, usage: [String: Any]) -> Double? {
        guard let (input, output, readShare) = prices.filter({ model.contains($0.0) })
            .max(by: { $0.0.count < $1.0.count })?.1 else { return nil }
        func n(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
        let creation = usage["cache_creation"] as? [String: Any]
        let write1h = n(creation?["ephemeral_1h_input_tokens"])
        let write5m = creation?["ephemeral_5m_input_tokens"] != nil
            ? n(creation?["ephemeral_5m_input_tokens"]) : max(n(usage["cache_creation_input_tokens"]) - write1h, 0)
        var cost = n(usage["input_tokens"]) * input + n(usage["output_tokens"]) * output
            + n(usage["cache_read_input_tokens"]) * input * readShare + write5m * input * 1.25 + write1h * input * 2
        if usage["speed"] as? String == "fast" { cost *= 2 }
        return cost / 1_000_000
    }
}
