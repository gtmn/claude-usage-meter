import Charts
import SwiftUI

// Usage history as a line over time, like a temperature curve.
// - Budget-only accounts (Enterprise/Team): money spent across the budget period,
//   with a dashed projection to the reset, or per UTC day as bars. Stretches the app didn't
//   record are estimated from Claude Code's logs and drawn lighter (an unrecorded stretch
//   with the same amount on both sides stays solid: nothing was spent in it).
// - Pro/Max: the 5 h and 7 d percentages over this week (last reset to next), with a dashed
//   projection of the weekly limit to the reset or to 100%, whichever comes first.
//
// Chart rules (dataviz skill): 2 px lines with round caps, hairline solid gridlines,
// value at the line's end, text in text colours (never the line colour), one series
// colour per entity (see ChartInk for why the second one is magenta).

struct HistoryChart: View {
    @ObservedObject var model: UsageModel
    let now: Date

    var body: some View {
        if let s = model.snapshot {
            // Saved numbers end the curve (and start the projection) when they were fetched, not now.
            let asOf = model.showingSaved ? min(s.capturedAt, now) : now
            if s.isBudgetOnly, let w = s.window("extra_usage"), w.spend != nil {
                BudgetHistoryChart(window: w, history: model.history, logWeights: model.logWeights, now: asOf)
            } else if s.window("seven_day") != nil || s.window("five_hour") != nil {
                VStack(alignment: .leading, spacing: 12) {
                    LimitsHistoryChart(history: model.history, week: s.window("seven_day"), now: asOf,
                                       models: s.windows.map(\.key).filter { $0.hasPrefix("seven_day_") }.sorted())
                    // Pro/Max extra usage: its own $ chart. No log estimates: most Claude Code activity
                    // is covered by the plan, and the logs can't tell which part was paid extra.
                    if let w = s.extraUsage {
                        BudgetHistoryChart(window: w, history: model.history, logWeights: [], now: asOf, extra: true)
                    }
                }
            }
        }
    }
}

/// Series colours from the validated reference palette (slot 1 blue, stepped per mode).
enum ChartInk {
    static func series1(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0x39 / 255, green: 0x87 / 255, blue: 0xe5 / 255)
                        : Color(red: 0x2a / 255, green: 0x78 / 255, blue: 0xd6 / 255)
    }
    /// Second series: palette slot 5 (magenta). Slot 2 orange is the app's warning colour and
    /// slot 3 aqua sits next to the green "ok" bar, so both are skipped. Validated with the
    /// dataviz validator: passes in dark; in light it is under 3:1, so the lines keep their
    /// legend and end labels (the required relief).
    static func series2(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0xd5 / 255, green: 0x51 / 255, blue: 0x81 / 255)
                        : Color(red: 0xe8 / 255, green: 0x7b / 255, blue: 0xa4 / 255)
    }
    /// Third series, a model's own weekly limit (Fable): ochre. Violet would merge with the blue
    /// week line for colour-blind readers (OKLab ΔE under 2 with deuteranopia simulated); ochre keeps
    /// ΔE 15+ from blue and magenta in dark mode and 10+ in light. Darker than the bars' bright
    /// "ahead" yellow, and the line keeps its legend entry and end label.
    static func series3(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0xc9 / 255, green: 0xa2 / 255, blue: 0x27 / 255)
                        : Color(red: 0xb0 / 255, green: 0x8a / 255, blue: 0x10 / 255)
    }
    /// Reference marks (budget line, hover rule): neutral, not a series.
    static let muted = Color.primary.opacity(0.42)
    static let grid = Color.primary.opacity(0.12)
    /// Axis text: the system secondary label colour (a plain `.secondary` picks up the series tint in Charts).
    static let label = Color(nsColor: .secondaryLabelColor)
    static let line = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
    static let dashed = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [3, 4])
}

/// A point on screen, with the index of its unbroken run (gaps over an hour start a new run,
/// so the line isn't drawn across times the Mac was asleep and nothing was recorded).
/// Where recorded and estimated parts meet, the new run repeats the last point so the line stays joined.
struct ChartPoint: Identifiable {
    let t: Date
    let value: Double
    let run: Int
    var estimated = false
    var id: String { "\(run)-\(t.timeIntervalSince1970)" }

    static func runs(_ raw: [(Date, Double)], gap: TimeInterval = 3600) -> [ChartPoint] {
        runs(raw.map { ($0.0, $0.1, false) }, gap: gap)
    }

    static func runs(_ raw: [(Date, Double, Bool)], gap: TimeInterval = 3600) -> [ChartPoint] {
        var run = 0
        var out: [ChartPoint] = []
        for (i, p) in raw.enumerated() {
            if i > 0 {
                let prev = raw[i - 1]
                // Unrecorded, but unchanged: nothing happened in between (the amounts only rise
                // within a period), so the line carries on as recorded.
                if p.0.timeIntervalSince(prev.0) > gap && p.1 != prev.1 { run += 1 }
                else if p.2 != prev.2 { run += 1; out.append(ChartPoint(t: prev.0, value: prev.1, run: run, estimated: p.2)) }
            }
            out.append(ChartPoint(t: p.0, value: p.1, run: run, estimated: p.2))
        }
        return out
    }
}

/// A stretch with nothing recorded between two points (the Mac was off or asleep, or the app
/// couldn't fetch) across which the value changed: drawn as a faint line so the curve doesn't just
/// stop. Both ends are real values; when in between it changed isn't known. (Unchanged across a
/// gap is known: nothing happened, and `ChartPoint.runs` keeps that part of the line solid.)
struct ChartGap: Identifiable {
    let id: Int
    let from: (t: Date, value: Double), to: (t: Date, value: Double)

    /// Gaps longer than `gap`, the same threshold that splits `ChartPoint.runs`.
    static func gaps(_ raw: [(Date, Double)], gap: TimeInterval = 3600) -> [ChartGap] {
        zip(raw, raw.dropFirst()).enumerated().compactMap { i, pair in
            let (a, b) = pair
            return b.0.timeIntervalSince(a.0) > gap && a.1 != b.1 ? ChartGap(id: i, from: (a.0, a.1), to: (b.0, b.1)) : nil
        }
    }
}

/// Faint enough to read as "not recorded", next to the solid line.
private let gapOpacity = 0.25

private func currency(_ amount: Double, _ code: String, decimals: Int = 0) -> String {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "en_US"); f.numberStyle = .currency; f.currencyCode = code
    f.minimumFractionDigits = decimals; f.maximumFractionDigits = decimals
    return f.string(from: NSNumber(value: amount)) ?? "\(Int(amount)) \(code)"
}

/// A round number at or above `x`: 1, 2, 2.5, 5 × 10ⁿ.
func niceCeil(_ x: Double) -> Double {
    guard x > 0 else { return 1 }
    let p = pow(10, floor(log10(x)))
    for m in [1, 2, 2.5, 5, 10] where m * p >= x { return m * p }
    return 10 * p
}

private struct ChartHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 11, weight: .semibold))
    }
}

private struct EmptyHistory: View {
    var body: some View {
        Text("The curve fills in as the app runs. History starts with the first update.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// For `--render-preview … hover`: pretend the pointer is at this fraction of the recorded times.
struct PreviewHoverKey: EnvironmentKey { static let defaultValue: Double? = nil }
/// For `--render-preview … daily`: show the per-day bars without touching the saved choice.
struct PreviewBudgetModeKey: EnvironmentKey { static let defaultValue: String? = nil }
/// For `--render-preview … overview` and `back=N`: the overview bars, or a period N back.
struct PreviewChartScaleKey: EnvironmentKey { static let defaultValue: String? = nil }
struct PreviewBackKey: EnvironmentKey { static let defaultValue: Int? = nil }
extension EnvironmentValues {
    var previewChartScale: String? {
        get { self[PreviewChartScaleKey.self] }
        set { self[PreviewChartScaleKey.self] = newValue }
    }
    var previewBack: Int? {
        get { self[PreviewBackKey.self] }
        set { self[PreviewBackKey.self] = newValue }
    }
    var previewHover: Double? {
        get { self[PreviewHoverKey.self] }
        set { self[PreviewHoverKey.self] = newValue }
    }
    var previewBudgetMode: String? {
        get { self[PreviewBudgetModeKey.self] }
        set { self[PreviewBudgetModeKey.self] = newValue }
    }
}

private func activeHover(_ hovered: Date?, preview: Double?, times: [Date],
                         future: (from: Date, to: Date)? = nil) -> Date? {
    if let hovered { return hovered }
    guard let f = preview, !times.isEmpty else { return nil }
    // Previews: 0…1 across the recorded times, 1…2 along the projection.
    if 1 < f, let future { return future.from.addingTimeInterval(future.to.timeIntervalSince(future.from) * min(f - 1, 1)) }
    return times[Int(Double(times.count - 1) * min(f, 1))]
}

// MARK: Projection (shared by both charts)

/// A dashed line from the latest number to where it's headed: the weekly limit to 100% or its
/// reset, the budget to its reset. Both charts draw it, label its end and follow it on hover
/// the same way.
struct ChartProjection {
    let now: Date, from: Double          // the latest number
    let end: Date, to: Double            // where the dashed line ends
    let endLabel: String                 // "100% Mon 17:39", "≈ $950"
    let hoverText: (Double) -> String    // "7d ≈ 80% projected", "≈ $735 projected"

    /// The stretch the hover follows the pointer along.
    var span: (from: Date, to: Date) { (now, end) }

    /// The value on the dashed line at `t`.
    func value(at t: Date) -> Double {
        let length = end.timeIntervalSince(now)
        guard length > 0 else { return to }
        return from + (to - from) * min(max(t.timeIntervalSince(now) / length, 0), 1)
    }

    /// The dashed line and the label above its end (right-aligned near the chart's right edge,
    /// so it stays inside; at the top of the chart it sits in the extra top padding).
    @ChartContentBuilder
    func marks(color: Color, domain: (start: Date, end: Date)) -> some ChartContent {
        let nearRightEdge = domain.start.addingTimeInterval(domain.end.timeIntervalSince(domain.start) * 0.79) < end
        LineMark(x: .value("Time", now), y: .value("Value", from), series: .value("Run", "projection"))
            .foregroundStyle(color.opacity(0.7)).lineStyle(ChartInk.dashed)
        LineMark(x: .value("Time", end), y: .value("Value", to), series: .value("Run", "projection"))
            .foregroundStyle(color.opacity(0.7)).lineStyle(ChartInk.dashed)
        PointMark(x: .value("Time", end), y: .value("Value", to))
            .foregroundStyle(color.opacity(0.7)).symbolSize(16)
            .annotation(position: .top, alignment: nearRightEdge ? .trailing : .center,
                        spacing: 3, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                Text(endLabel).font(.system(size: 9)).foregroundStyle(ChartInk.label)
            }
    }

    /// Hovering the dashed line: a rule, the point on the line, and the tooltip beside the rule
    /// on the side with more room.
    @ChartContentBuilder
    func hoverMarks(at h: Date, color: Color, domain: (start: Date, end: Date)) -> some ChartContent {
        let v = value(at: h)
        let leftHalf = h < domain.start.addingTimeInterval(domain.end.timeIntervalSince(domain.start) / 2)
        RuleMark(x: .value("Time", h)).foregroundStyle(ChartInk.muted).lineStyle(StrokeStyle(lineWidth: 1))
            .annotation(position: leftHalf ? .trailing : .leading, alignment: .top, spacing: 6,
                        overflowResolution: .init(x: .disabled, y: .fit(to: .chart))) {
                Tooltip(lines: [tooltipTime.string(from: h), hoverText(v)])
            }
        PointMark(x: .value("Time", h), y: .value("Value", v))
            .foregroundStyle(color.opacity(0.7)).symbolSize(36)
    }
}

/// The tooltip box drawn above a hovered point.
/// The menu bar popup is a translucent window: `.background` would be its see-through material,
/// and `.primary`/`.secondary` text is drawn vibrant, blending with what's behind the window,
/// so over an opaque box it all but vanishes. Hence fixed AppKit colours, flattened into one layer.
private struct Tooltip: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, s in
                Text(s).font(.system(size: i == 0 ? 10 : 11, weight: i == 0 ? .regular : .semibold))
                    .foregroundStyle(Color(nsColor: i == 0 ? .secondaryLabelColor : .labelColor))
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .windowBackgroundColor).shadow(.drop(color: .black.opacity(0.25), radius: 3)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        )
        .compositingGroup()
    }
}

private let tooltipTime: DateFormatter = {
    let f = DateFormatter(); f.locale = HumanTime.en; f.dateFormat = "EEE d MMM, HH:mm"; return f
}()

/// Hover layer: maps the pointer to the nearest recorded time, or, past the last one and over
/// a projection (`future`: from now to where the dashed line ends), to the time under the pointer.
private struct HoverLayer: ViewModifier {
    let times: [Date]
    var future: (from: Date, to: Date)? = nil
    @Binding var hovered: Date?

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let loc) = phase, let frame = proxy.plotFrame else { hovered = nil; return }
                        let x = loc.x - geo[frame].origin.x
                        guard let t: Date = proxy.value(atX: x), !times.isEmpty else { hovered = nil; return }
                        if let f = future, f.from < t {
                            hovered = t < f.to ? t : f.to
                            return
                        }
                        hovered = times.min { abs($0.timeIntervalSince(t)) < abs($1.timeIntervalSince(t)) }
                    }
            }
        }
    }
}

// MARK: Looking back (shared)

/// "‹ This week ›": steps back through earlier periods (or pages of the overview). The title
/// returns to now when clicked.
private struct PeriodStepper: View {
    let title: String
    let canGoBack: Bool
    @Binding var back: Int

    var body: some View {
        HStack(spacing: 2) {
            arrow("chevron.left", enabled: canGoBack, help: "Earlier") { back += 1 }
            Text(title).font(.system(size: 11, weight: .semibold))
                .onTapGesture { back = 0 }
                .help(back > 0 ? "Back to now" : "")
            arrow("chevron.right", enabled: back > 0, help: "Later") { back -= 1 }
        }
    }

    private func arrow(_ name: String, enabled: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        Image(systemName: name).font(.system(size: 9, weight: .semibold))
            .frame(width: 14, height: 14).contentShape(Rectangle())
            .foregroundStyle(enabled ? Color.primary : Color.primary.opacity(0.2))
            .onTapGesture { if enabled { action() } }
            .help(enabled ? help : "")
            .accessibilityLabel(help).accessibilityAddTraits(.isButton)
    }
}

/// The long view: one line across several periods (the weekly % or the money spent), with a dashed
/// rule at each reset and, just before it, what the period reached. A period that ran out gets an
/// orange point there. Drawn from at most one point per hour (the highest, so each climb and each
/// drop at a reset stay sharp).
private struct PeriodLine: View {
    /// Oldest first; the last may be the current one (its line ends at the latest point).
    let periods: [PeriodSummary]
    let points: [(t: Date, value: Double)]
    let top: Double
    /// A reference line (the budget), labelled.
    var limit: (value: Double, label: String)? = nil
    /// The value of a period's end label and tooltips: "85%", "$1,240".
    let format: (Double) -> String
    /// What a period reached, in the line's units (the weekly % or the money).
    let reached: (PeriodSummary) -> Double
    let accessibility: String
    /// Times the 5 h session hit its limit: orange ticks along the bottom, counted per period.
    var hits: [LimitHit] = []
    @Environment(\.colorScheme) private var scheme
    @Environment(\.previewHover) private var previewHover
    @ViewState private var hovered: Date?

    var body: some View {
        let tint = ChartInk.series1(scheme)
        let full = Color(nsColor: MenuBarImage.color(.far))
        let hourly = Self.hourly(points)
        let line = ChartPoint.runs(hourly)
        let domainStart = periods.first?.start ?? Date(), domainEnd = periods.last?.end ?? Date()
        let resets = periods.dropFirst().map(\.start)
        // An unrecorded stretch across a reset isn't drawn: the value dropped at the reset, not along it.
        let gaps = ChartGap.gaps(hourly).filter { g in !resets.contains { g.from.t < $0 && $0 < g.to.t } }
        let times = line.map(\.t)
        let active = activeHover(hovered, preview: previewHover, times: times)
        // Reset dates on the axis; every second one when there are many.
        let every = resets.count > 6 ? 2 : 1
        let axisDates = resets.enumerated().filter { (resets.count - 1 - $0.offset) % every == 0 }.map(\.element)

        Chart {
            if let limit {
                RuleMark(y: .value("Limit", limit.value)).foregroundStyle(ChartInk.muted).lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text(limit.label).font(.system(size: 9)).foregroundStyle(ChartInk.label)
                    }
            }
            ForEach(resets, id: \.self) { r in
                RuleMark(x: .value("Reset", r)).foregroundStyle(ChartInk.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            ForEach(gaps) { g in
                LineMark(x: .value("Time", g.from.t), y: .value("Used", g.from.value), series: .value("Run", "gap-\(g.id)"))
                    .foregroundStyle(tint.opacity(gapOpacity)).lineStyle(ChartInk.line)
                LineMark(x: .value("Time", g.to.t), y: .value("Used", g.to.value), series: .value("Run", "gap-\(g.id)"))
                    .foregroundStyle(tint.opacity(gapOpacity)).lineStyle(ChartInk.line)
            }
            ForEach(line) { p in
                LineMark(x: .value("Time", p.t), y: .value("Used", p.value), series: .value("Run", "line-\(p.run)"))
                    .foregroundStyle(tint).lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array(hits.enumerated()), id: \.offset) { _, h in
                RuleMark(x: .value("Time", h.at), yStart: .value("Used", 0), yEnd: .value("Used", top * 0.08))
                    .foregroundStyle(full).lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            // What each period reached, at its last recorded point (the line's top before the reset),
            // and how often the 5 h session hit its limit in it.
            ForEach(periods, id: \.start) { p in
                let count = Self.hits(hits, in: p).count
                PointMark(x: .value("Time", p.lastRecorded), y: .value("Used", reached(p)))
                    .foregroundStyle(p.ranOutAt != nil ? full : tint).symbolSize(p.ranOutAt != nil ? 22 : 14)
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        if active == nil {
                            VStack(spacing: 0) {
                                if count > 0 {
                                    Text("5h ×\(count)").font(.system(size: 8)).foregroundStyle(ChartInk.label)
                                }
                                Text(format(reached(p))).font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.primary)
                            }
                            .monospacedDigit()
                        }
                    }
            }
            if let h = active, let p = line.last(where: { $0.t == h }) {
                let leftHalf = h < domainStart.addingTimeInterval(domainEnd.timeIntervalSince(domainStart) / 2)
                RuleMark(x: .value("Time", h)).foregroundStyle(ChartInk.muted).lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: leftHalf ? .trailing : .leading, alignment: .top, spacing: 6,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Tooltip(lines: [tooltipTime.string(from: h), format(p.value)] + Self.periodNote(periods, hits: hits, at: h))
                    }
                PointMark(x: .value("Time", h), y: .value("Used", p.value)).foregroundStyle(tint).symbolSize(36)
            }
        }
        .chartXScale(domain: domainStart...domainEnd)
        .chartYScale(domain: 0...top)
        .chartXAxis {
            AxisMarks(values: axisDates) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: 9)).foregroundStyle(ChartInk.label)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, top / 2, top]) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ChartInk.grid)
                AxisValueLabel { if let d = v.as(Double.self) { Text(format(d)) } }
                    .font(.system(size: 9)).foregroundStyle(ChartInk.label)
            }
        }
        .modifier(HoverLayer(times: times, hovered: $hovered))
        .padding(.top, hits.isEmpty ? 14 : 24)   // room for the end labels (and hit counts) at the top
        .frame(height: hits.isEmpty ? 124 : 134)
        .accessibilityLabel(accessibility)
    }

    /// At most one point per hour, the highest of it.
    static func hourly(_ pts: [(t: Date, value: Double)]) -> [(Date, Double)] {
        var out: [(Date, Double)] = []
        var hour = Int.min
        for p in pts {
            let h = Int(floor(p.t.timeIntervalSince1970 / 3600))
            if h == hour, let last = out.last { if last.1 < p.value { out[out.count - 1] = (p.t, p.value) } }
            else { out.append((p.t, p.value)); hour = h }
        }
        return out
    }

    static func hits(_ hits: [LimitHit], in p: PeriodSummary) -> [LimitHit] {
        hits.filter { p.start.isAtOrBefore($0.at) && $0.at < p.end }
    }

    /// For the hover: the period's dates, when it ran out, and the 5 h limit hits in it.
    static func periodNote(_ periods: [PeriodSummary], hits all: [LimitHit], at t: Date) -> [String] {
        guard let p = periods.first(where: { $0.start.isAtOrBefore(t) && t < $0.end }) else { return [] }
        var lines = [periodRange(p.start, p.end)]
        if let out = p.ranOutAt {
            let f = DateFormatter(); f.locale = HumanTime.en; f.dateFormat = "EEE d MMM, HH:mm"
            lines.append("ran out \(f.string(from: out))")
        }
        let hits = Self.hits(all, in: p)
        if !hits.isEmpty {
            // The blocked times added up, as one span for the wording ("at least" if any reset is unknown).
            let total = hits.reduce(0) { $0 + $1.blocked }
            let zero = Date(timeIntervalSince1970: 0), end = Date(timeIntervalSince1970: total)
            let sum = LimitHit(at: zero, lastFull: end, resetSeen: hits.contains(where: \.atLeast) ? nil : end)
            lines.append("5h limit hit \(hits.count)× · blocked \(blockedText(sum)) in all")
        }
        return lines
    }
}

/// "5–12 Nov", "29 Oct – 5 Nov": a period's days, its end being the reset (so the day before).
func periodRange(_ start: Date, _ end: Date, timeZone: TimeZone = .current) -> String {
    let last = end.addingTimeInterval(-1)
    var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
    let f = DateFormatter(); f.locale = HumanTime.en; f.timeZone = timeZone
    if cal.component(.month, from: start) == cal.component(.month, from: last) {
        f.dateFormat = "d"; let a = f.string(from: start)
        f.dateFormat = "d MMM"; return "\(a)–\(f.string(from: last))"
    }
    f.dateFormat = "d MMM"
    return "\(f.string(from: start)) – \(f.string(from: last))"
}

/// "1h 40m", "45m": how long a session was blocked, to 5 minutes.
func blockedText(_ hit: LimitHit) -> String {
    let minutes = max(5, Int((hit.blocked / 300).rounded()) * 5)
    let text = minutes < 60 ? "\(minutes)m" : minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    return (hit.atLeast ? "at least " : "") + text
}

/// "5h limit hit Tue 14:20", "blocked 1h 40m": a hit for the hover.
func hitLines(_ hit: LimitHit) -> [String] {
    let f = DateFormatter(); f.locale = HumanTime.en; f.dateFormat = "EEE HH:mm"
    return ["5h limit hit \(f.string(from: hit.at))",
            hit.resetSeen == nil ? "blocked until the session resets" : "blocked \(blockedText(hit))"]
}

/// Periods per page of the long view: few enough that each one's end label has room.
private let weeksPage = 8, monthsPage = 6

// MARK: Budget

private let utc: TimeZone = TimeZone(identifier: "UTC")!
private func utcFormatter(_ format: String) -> DateFormatter {
    let f = DateFormatter(); f.locale = HumanTime.en; f.timeZone = utc; f.dateFormat = format; return f
}
private let utcDay = utcFormatter("EEE d MMM")
private let utcAxisDay = utcFormatter("d MMM")
private let utcWeekday = utcFormatter("EEE")
private let localDayTime: DateFormatter = {
    let f = DateFormatter(); f.locale = HumanTime.en; f.dateFormat = "d MMM, HH:mm"; return f
}()

/// A two-option switch drawn in SwiftUI (renders in previews, unlike the AppKit segmented control).
/// Small two-or-more-way switch (the chart mode, the menu bar style).
struct ModeSwitch: View {
    @Binding var mode: String
    let options: [(String, String)]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { tag, label in
                Text(label)
                    .font(.system(size: 10, weight: mode == tag ? .semibold : .regular))
                    .foregroundStyle(mode == tag ? Color.primary : Color.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(mode == tag ? Color.primary.opacity(0.12) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { mode = tag }
                    .accessibilityAddTraits(mode == tag ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(1)
        .background(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }
}

struct BudgetHistoryChart: View {
    let window: UsageWindow
    let history: UsageHistory
    let logWeights: [UsageWeight]
    let now: Date
    /// Pro/Max extra usage rather than an Enterprise/Team budget: titled so, and never estimated.
    var extra = false
    @AppStorage("budgetChartMode") private var savedMode = "total"
    @Environment(\.previewBudgetMode) private var previewMode
    @Environment(\.previewChartScale) private var previewScale
    @Environment(\.previewBack) private var previewBack
    /// How many periods back (Total, Per day), or pages of periods back (the overview).
    @ViewState private var stepBack = 0

    var body: some View {
        let spend = window.spend!
        let reset = window.resetsAt ?? now
        let back = previewBack ?? stepBack
        let currentStart = reset.addingTimeInterval(-(window.duration ?? 30 * 86400))
        let start = back == 0 ? currentStart : UsageHistory.periodStart(of: window, back: back) ?? currentStart
        let end = back == 0 ? reset : UsageHistory.periodStart(of: window, back: back - 1) ?? reset
        let period = spend.period
        let filled = points(back: back, start: start, end: end, spend: spend)
        let perDayAllowed = period != "daily"
        let overviewAllowed = window.resetsAt != nil
        let mode = chosenMode(perDayAllowed: perDayAllowed, overviewAllowed: overviewAllowed)
        let unit = period == "weekly" ? "week" : period == "daily" ? "day" : "month"
        let units = period == "weekly" ? "weeks" : period == "daily" ? "days" : "months"
        let oldest = history.series(window.key, from: .distantPast).first { $0.estimated != true }?.t
        let periods = mode == "overview" ? history.periods(of: window) : []
        let what = extra ? "Extra usage" : "Spent"
        let title = mode == "overview" ? (back == 0 ? "Recent \(units)" : "Earlier \(units)")
            : back > 0 ? Self.periodName(start, end, period: period)   // the switch says Total or Per day
            : mode == "daily" ? "\(what) per day" : "\(what) this \(unit)"

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                PeriodStepper(title: title,
                              canGoBack: mode == "overview" ? periods.count > (back + 1) * Self.page(period)
                                                            : oldest.map { $0 < start } ?? false,
                              back: $stepBack)
                if mode == "daily" { Text("UTC days").font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer()
                let options = [("total", "Total")] + (perDayAllowed ? [("daily", "Per day")] : [])
                    + (overviewAllowed ? [("overview", units.capitalized)] : [])
                if options.count > 1 {
                    ModeSwitch(mode: Binding(get: { mode }, set: { savedMode = $0; stepBack = 0 }), options: options)
                }
            }
            if mode == "overview" {
                if periods.isEmpty {
                    EmptyHistory()
                } else {
                    let page = Array(periods.dropFirst(back * Self.page(period)).prefix(Self.page(period)).reversed())
                    let code = spend.limit.currency, scale = pow(10, Double(spend.limit.exponent))
                    let reached: (PeriodSummary) -> Double = { Double($0.peakUsedMinor ?? 0) / scale }
                    let top = niceCeil(max(page.map(reached).max() ?? 0, spend.limit.amount) * 1.05)
                    let from = page.first?.start ?? start, to = min(page.last?.end ?? now, now)
                    PeriodLine(periods: page,
                               points: history.series(window.key, from: from, to: to)
                                   .filter { $0.estimated != true && $0.usedMinor != nil }
                                   .map { (t: $0.t, value: Double($0.usedMinor ?? 0) / scale) },
                               top: top, limit: (spend.limit.amount, "\(extra ? "Limit" : "Budget") \(currency(spend.limit.amount, code))"),
                               format: { currency($0, code) }, reached: reached,
                               accessibility: "Money spent over the last \(page.count) \(units), with each reset marked")
                }
            } else if filled.count < 2 {
                EmptyHistory()
            } else if mode == "daily" {
                DailySpendBars(window: window, days: UsageHistory.dailySpend(filled), start: start, end: end,
                               now: back == 0 ? now : end)
            } else {
                BudgetLine(window: window, points: filled, start: start, reset: end, now: back == 0 ? now : end,
                           limitName: extra ? "Limit" : "Budget", past: back > 0)
            }
            if mode != "overview", let note = Self.footnote(filled, start: start, usesLogs: !extra && back == 0) {
                Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The current period: recorded, with the unrecorded start estimated from Claude Code's logs.
    /// A past one: what was recorded, as it was (the logs are only read for the current period).
    private func points(back: Int, start: Date, end: Date, spend: Spend) -> [HistoryPoint] {
        guard back == 0 else { return history.budgetSeries(window.key, periodStart: start, to: end) }
        let current = HistoryPoint(t: now, key: window.key, percent: window.percent, usedMinor: spend.used.minor)
        let recorded = history.budgetSeries(window.key, periodStart: start, current: current)
        return UsageHistory.filledBudget(recorded, periodStart: start, weights: logWeights, limitMinor: spend.limit.minor)
    }

    private func chosenMode(perDayAllowed: Bool, overviewAllowed: Bool) -> String {
        let mode = previewScale == "overview" ? "overview" : previewMode ?? savedMode
        if mode == "daily" && !perDayAllowed || mode == "overview" && !overviewAllowed { return "total" }
        return mode
    }

    /// Periods per page of the long view.
    static func page(_ period: String?) -> Int { period == "weekly" ? weeksPage : period == "daily" ? 14 : monthsPage }

    /// "Oct 2026" for a calendar month, else its days ("5–12 Nov").
    static func periodName(_ start: Date, _ end: Date, period: String?) -> String {
        period == "monthly" || period == nil ? utcFormatter("MMM yyyy").string(from: start)
                                             : periodRange(start, end, timeZone: utc)
    }


    /// Says where the curve isn't recorded: estimated from the logs, or not known at all.
    /// `usesLogs`: false for Pro/Max extra usage, which is never estimated from the logs.
    static func footnote(_ pts: [HistoryPoint], start: Date, usesLogs: Bool = true) -> String? {
        var notes: [String] = []
        if pts.contains(where: { $0.estimated == true }) {
            notes.append("Lighter: not recorded; estimated from Claude Code's logs on this Mac, scaled to the real totals.")
        } else if let first = pts.first, first.t.timeIntervalSince(start) > UsageHistory.fillableGap {
            notes.append("Recorded since \(localDayTime.string(from: first.t))"
                         + (usesLogs ? "; no Claude Code logs cover the time before." : "."))
        }
        if hasFaintGap(pts, start: start) {
            notes.append(usesLogs ? "Faint: not recorded, and no Claude Code activity to place the spending."
                                  : "Faint: not recorded.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    /// The same gaps `BudgetLine` draws faint: unrecorded for over an hour while the amount rose.
    static func hasFaintGap(_ pts: [HistoryPoint], start: Date) -> Bool {
        let values = pts.map { ($0.t, Double($0.usedMinor ?? 0)) }
        let startsLate = pts.first.map { $0.t.timeIntervalSince(start) > UsageHistory.fillableGap } ?? false
        return !ChartGap.gaps((startsLate ? [(start, 0)] : []) + values).isEmpty
    }
}

/// Money spent so far as a line, with a dashed projection to the reset.
private struct BudgetLine: View {
    let window: UsageWindow
    let points: [HistoryPoint]
    let start: Date, reset: Date, now: Date
    /// What the limit line says: "Budget" (Enterprise/Team) or "Limit" (Pro/Max extra usage).
    var limitName = "Budget"
    /// A past period: no projection, and the line ends at its last recorded amount.
    var past = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.previewHover) private var previewHover
    @ViewState private var hovered: Date?

    var body: some View {
        let spend = window.spend!
        let code = spend.limit.currency
        let scale = pow(10, Double(spend.limit.exponent))
        let line = ChartPoint.runs(points.map { ($0.t, Double($0.usedMinor ?? 0) / scale, $0.estimated == true) })
        // Before the first recorded point the period started at zero, so that stretch is a gap too.
        let startsLate = points.first.map { $0.t.timeIntervalSince(start) > UsageHistory.fillableGap } ?? false
        let gaps = ChartGap.gaps((startsLate ? [(start, 0)] : []) + points.map { ($0.t, Double($0.usedMinor ?? 0) / scale) })
        let projectable = !past && !window.isTooEarlyToProject(now: now)
            && (spend.used.minor > 0 || window.projectsFromPriorPace(now: now))
        let endPoint = past ? (t: line.last?.t ?? start, amount: line.last?.value ?? 0) : (t: now, amount: spend.used.amount)
        let projected = projectable ? window.projectedPercentAtReset(now: now).map { spend.limit.amount * $0 / 100 } : nil
        let projection = projected.map { to in
            // End label rounded like the outlook line ("on track for about $950").
            ChartProjection(now: now, from: spend.used.amount, end: reset, to: to,
                            endLabel: "≈ " + spend.approx(percent: to / spend.limit.amount * 100), hoverText: { "≈ \(currency($0, code)) projected" })
        }
        let peak = max(endPoint.amount, projected ?? 0)
        // Show the whole budget only when the curve gets near it; otherwise the line would hug the floor.
        let showLimit = spend.limit.amount <= niceCeil(peak * 1.15) * 1.5
        let top = showLimit ? niceCeil(spend.limit.amount * 1.05) : niceCeil(peak * 1.15)
        let tint = ChartInk.series1(scheme)
        let times = line.map(\.t)
        let active = activeHover(hovered, preview: previewHover, times: times, future: projection?.span)

        Chart {
            if showLimit {
                RuleMark(y: .value("Budget", spend.limit.amount))
                    .foregroundStyle(ChartInk.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("\(limitName) \(currency(spend.limit.amount, code))")
                            .font(.system(size: 9)).foregroundStyle(ChartInk.label)
                    }
            }
            ForEach(gaps) { g in
                LineMark(x: .value("Time", g.from.t), y: .value("Spent", g.from.value), series: .value("Run", "gap-\(g.id)"))
                    .foregroundStyle(tint.opacity(gapOpacity)).lineStyle(ChartInk.line)
                LineMark(x: .value("Time", g.to.t), y: .value("Spent", g.to.value), series: .value("Run", "gap-\(g.id)"))
                    .foregroundStyle(tint.opacity(gapOpacity)).lineStyle(ChartInk.line)
            }
            ForEach(line) { p in
                LineMark(x: .value("Time", p.t), y: .value("Spent", p.value), series: .value("Run", "spent-\(p.run)"))
                    .foregroundStyle(p.estimated ? tint.opacity(0.45) : tint)
                    .lineStyle(ChartInk.line)
            }
            if let projection {
                projection.marks(color: tint, domain: (start, reset))
            }
            // Value at the line's end.
            PointMark(x: .value("Time", endPoint.t), y: .value("Spent", endPoint.amount))
                .foregroundStyle(tint).symbolSize(28)
                .annotation(position: .top, spacing: 3, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                    if active == nil {
                        Text(currency(endPoint.amount, code)).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.primary).monospacedDigit()
                    }
                }
            if let h = active, now < h, let projection {
                projection.hoverMarks(at: h, color: tint, domain: (start, reset))
            } else if let h = active, let p = line.last(where: { $0.t == h }) {
                RuleMark(x: .value("Time", p.t)).foregroundStyle(ChartInk.muted).lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Time", p.t), y: .value("Spent", p.value))
                    .foregroundStyle(tint).symbolSize(40)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        let amount = currency(p.value, code, decimals: spend.limit.exponent)
                        // From the data, not the drawn point: a run's first point repeats the
                        // previous run's last one, which may be recorded.
                        let src = points.last { $0.t == p.t }
                        Tooltip(lines: [tooltipTime.string(from: p.t),
                                        src?.estimated != true ? amount
                                            : src?.idle == true ? "about \(amount) · no activity" : amount + " (estimated)"])
                    }
            }
        }
        .chartXScale(domain: start...reset)
        .chartYScale(domain: 0...top)
        .chartXAxis { dayAxis(period: spend.period, start: start, end: reset) }
        .chartYAxis { moneyAxis(top: top, code: code) }
        .modifier(HoverLayer(times: times, future: projection?.span, hovered: $hovered))
        .padding(.top, 6)
        .frame(height: 110)
        .accessibilityLabel("Money spent over time this budget period")
    }
}

/// Money spent per UTC day as bars; the estimated part of a day is the lighter segment at the bottom.
private struct DailySpendBars: View {
    let window: UsageWindow
    let days: [DaySpend]
    let start: Date, end: Date, now: Date
    @Environment(\.colorScheme) private var scheme
    @Environment(\.previewHover) private var previewHover
    @ViewState private var hovered: Date?

    var body: some View {
        let spend = window.spend!
        let code = spend.limit.currency
        let scale = pow(10, Double(spend.limit.exponent))
        let shown = days.filter { $0.day.isAtOrAfter(start) && $0.day < end }
        let top = niceCeil((shown.map { Double($0.usedMinor) / scale }.max() ?? 0) * 1.15)
        let tint = ChartInk.series1(scheme)
        let mids = shown.map { $0.day.addingTimeInterval(43200) }
        let active = activeHover(hovered, preview: previewHover, times: mids)
        let today = shown.last { $0.day.isAtOrBefore(now) }

        Chart {
            ForEach(shown, id: \.day) { d in
                bars(d, scale: scale, tint: tint, dim: active != nil && active != d.day.addingTimeInterval(43200))
            }
            // Selective label: today's amount at the top of its bar.
            if active == nil, let d = today, d.usedMinor > 0 {
                PointMark(x: .value("Day", d.day.addingTimeInterval(43200)), y: .value("Spent", Double(d.usedMinor) / scale))
                    .symbolSize(0)
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text(currency(Double(d.usedMinor) / scale, code)).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.primary).monospacedDigit()
                    }
            }
            if let h = active, let d = shown.first(where: { $0.day.addingTimeInterval(43200) == h }) {
                PointMark(x: .value("Day", h), y: .value("Spent", Double(d.usedMinor) / scale))
                    .symbolSize(0)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Tooltip(lines: Self.tooltip(d, scale: scale, code: code, decimals: spend.limit.exponent, now: now))
                    }
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...top)
        .chartXAxis {
            // Labels under the day they name (UTC), every day for a week, every 7 days for a month.
            let every = spend.period == "weekly" ? 1 : 7
            // For a month, leave out the last few days so the final label isn't clipped at the edge.
            let dayCount = Int((end.timeIntervalSince(start) / 86400).rounded())
            AxisMarks(values: stride(from: 0, to: every == 1 ? dayCount : dayCount - 3, by: every)
                .map { start.addingTimeInterval(Double($0) * 86400 + 43200) }) { v in
                AxisValueLabel {
                    if let d = v.as(Date.self) {
                        Text((every == 1 ? utcWeekday : utcAxisDay).string(from: d))
                    }
                }
                .font(.system(size: 9)).foregroundStyle(ChartInk.label)
            }
        }
        .chartYAxis { moneyAxis(top: top, code: code) }
        .modifier(HoverLayer(times: mids, hovered: $hovered))
        .padding(.top, 6)
        .frame(height: 110)
        .accessibilityLabel("Money spent per day this budget period")
    }

    @ChartContentBuilder
    private func bars(_ d: DaySpend, scale: Double, tint: Color, dim: Bool) -> some ChartContent {
        let x0 = d.day.addingTimeInterval(86400 * 0.14), x1 = d.day.addingTimeInterval(86400 * 0.86)
        let est = Double(d.estimatedMinor) / scale, total = Double(d.usedMinor) / scale
        if est > 0 {
            RectangleMark(xStart: .value("Day", x0), xEnd: .value("Day", x1),
                    yStart: .value("Spent", 0), yEnd: .value("Spent", est))
                .foregroundStyle(tint.opacity(dim ? 0.2 : 0.45))
        }
        if total > est {
            RectangleMark(xStart: .value("Day", x0), xEnd: .value("Day", x1),
                    yStart: .value("Spent", est), yEnd: .value("Spent", total))
                .foregroundStyle(tint.opacity(dim ? 0.4 : 1))
        }
    }

    static func tooltip(_ d: DaySpend, scale: Double, code: String, decimals: Int, now: Date) -> [String] {
        var lines = ["\(utcDay.string(from: d.day)) (UTC)", currency(Double(d.usedMinor) / scale, code, decimals: decimals)]
        if d.estimatedMinor > 0 {
            lines.append(d.estimatedMinor == d.usedMinor ? "estimated"
                         : "\(currency(Double(d.estimatedMinor) / scale, code, decimals: decimals)) of it estimated")
        }
        if let from = d.countsFrom { lines.append("from \(utcFormatter("HH:mm").string(from: from)) UTC on") }
        if let since = d.includesSince { lines.append("includes spending since \(utcDay.string(from: since))") }
        if now.timeIntervalSince(d.day) < 86400 { lines.append("so far today") }
        return lines
    }
}

@AxisContentBuilder
private func moneyAxis(top: Double, code: String) -> some AxisContent {
    AxisMarks(position: .leading, values: [0, top / 2, top]) { v in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ChartInk.grid)
        AxisValueLabel { if let d = v.as(Double.self) { Text(currency(d, code)) } }
            .font(.system(size: 9)).foregroundStyle(ChartInk.label)
    }
}

// MARK: Pro / Max

struct LimitsHistoryChart: View {
    let history: UsageHistory
    /// The weekly limit (with last week's pace when known): sets the chart's span and the projection.
    var week: UsageWindow? = nil
    let now: Date
    /// A model's own weekly limits ("seven_day_fable"): a line each, as far as there are colours (one today).
    var models: [String] = []
    @Environment(\.colorScheme) private var scheme
    @Environment(\.previewHover) private var previewHover
    @Environment(\.previewChartScale) private var previewScale
    @Environment(\.previewBack) private var previewBack
    @AppStorage("limitsChartScale") private var savedScale = "week"
    @ViewState private var hovered: Date?
    /// How many weeks back (Week), or pages of weeks back (Weeks).
    @ViewState private var stepBack = 0

    private struct Line { let key, name, short: String; let color: Color }

    var body: some View {
        // This week, from the last reset to the next one; without a reset time, the last 7 days.
        let weekReset = week?.resetsAt.flatMap { $0.isAtOrAfter(now) ? $0 : nil }
        let back = previewBack ?? stepBack
        let overview = weekReset != nil && (previewScale ?? savedScale) == "overview"
        let currentEnd = weekReset ?? now
        let start = currentEnd.addingTimeInterval(-7 * 86400 * Double(back + 1))
        let end = back == 0 ? currentEnd : start.addingTimeInterval(7 * 86400)
        let seriesEnd = back == 0 ? now : end
        let oldest = history.series("seven_day", from: .distantPast).first?.t
        let projection = back > 0 ? nil : weekReset.flatMap { r in week.flatMap { Self.projection($0, reset: r, now: now) } }
        let weekColor = ChartInk.series1(scheme)
        let lines = [
            Line(key: "seven_day", name: "Week (7 d)", short: "7d", color: weekColor),
            Line(key: "five_hour", name: "Session (5 h)", short: "5h", color: ChartInk.series2(scheme)),
        ] + zip(models, [ChartInk.series3(scheme)]).map { key, color in
            let model = key.dropFirst("seven_day_".count).replacingOccurrences(of: "_", with: " ").capitalized
            return Line(key: key, name: "\(model) (7 d)", short: model, color: color)
        }
        let series = lines.map { l in
            (l, ChartPoint.runs(history.series(l.key, from: start, to: seriesEnd).map { ($0.t, $0.percent) }))
        }.filter { $0.1.count >= 1 }
        let weeks = overview ? week.map { history.periods(of: $0) } ?? [] : []
        // Times the 5 h session hit its limit this week (only when the plan has a 5 h limit).
        let hits = series.contains { $0.0.key == "five_hour" } ? history.limitHits(from: start, to: seriesEnd) : []
        let times = Array(Set(series.flatMap { $0.1.map(\.t) })).sorted()
        let active = activeHover(hovered, preview: previewHover, times: times, future: projection?.span)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if overview {
                    PeriodStepper(title: back == 0 ? "Recent weeks" : "Earlier weeks",
                                  canGoBack: weeks.count > (back + 1) * weeksPage, back: $stepBack)
                } else {
                    PeriodStepper(title: back > 0 ? periodRange(start, end) : weekReset == nil ? "Last 7 days" : "This week",
                                  canGoBack: oldest.map { $0 < start } ?? false, back: $stepBack)
                }
                Spacer()
                if weekReset != nil {
                    ModeSwitch(mode: Binding(get: { overview ? "overview" : "week" },
                                             set: { savedScale = $0; stepBack = 0 }),
                               options: [("week", "Week"), ("overview", "Weeks")])
                }
            }
            if !overview {
                // Legend: a short line key beside each name (identity is never colour alone;
                // the line ends are labelled too).
                HStack(spacing: 10) {
                    ForEach(series.map(\.0), id: \.key) { l in
                        HStack(spacing: 4) {
                            Capsule().fill(l.color).frame(width: 10, height: 2)
                            Text(l.name).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if overview {
                if weeks.isEmpty {
                    EmptyHistory()
                } else {
                    let page = Array(weeks.dropFirst(back * weeksPage).prefix(weeksPage).reversed())
                    let from = page.first?.start ?? start, to = min(page.last?.end ?? now, now)
                    PeriodLine(periods: page,
                               points: history.series("seven_day", from: from, to: to).map { (t: $0.t, value: $0.percent) },
                               top: 100, format: { "\(Int($0.rounded()))%" }, reached: { $0.peak },
                               accessibility: "The weekly limit over the last \(page.count) weeks, with each reset marked",
                               hits: history.limitHits(from: from, to: to))
                }
            } else if series.allSatisfy({ $0.1.count < 2 }) {
                EmptyHistory()
            } else {
                Chart {
                    ForEach(series, id: \.0.key) { l, pts in
                        ForEach(ChartGap.gaps(pts.map { ($0.t, $0.value) })) { g in
                            LineMark(x: .value("Time", g.from.t), y: .value("Used", g.from.value),
                                     series: .value("Run", "\(l.key)-gap-\(g.id)"))
                                .foregroundStyle(l.color.opacity(gapOpacity)).lineStyle(ChartInk.line)
                            LineMark(x: .value("Time", g.to.t), y: .value("Used", g.to.value),
                                     series: .value("Run", "\(l.key)-gap-\(g.id)"))
                                .foregroundStyle(l.color.opacity(gapOpacity)).lineStyle(ChartInk.line)
                        }
                        ForEach(pts) { p in
                            LineMark(x: .value("Time", p.t), y: .value("Used", p.value),
                                     series: .value("Run", "\(l.key)-\(p.run)"))
                                .foregroundStyle(l.color).lineStyle(ChartInk.line)
                        }
                        if let last = pts.last, active == nil {
                            PointMark(x: .value("Time", last.t), y: .value("Used", last.value))
                                .foregroundStyle(l.color).symbolSize(24)
                                .annotation(position: .trailing, spacing: 3) {
                                    Text("\(l.short) \(Int(last.value.rounded()))%")
                                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.primary)
                                }
                        }
                    }
                    ForEach(Array(hits.enumerated()), id: \.offset) { _, h in
                        PointMark(x: .value("Time", h.at), y: .value("Used", 100))
                            .foregroundStyle(Color(nsColor: MenuBarImage.color(.far))).symbolSize(30)
                    }
                    if let projection {
                        projection.marks(color: weekColor, domain: (start, end))
                    }
                    if let h = active, now < h, let projection {
                        // Along the dashed line: the projected weekly number (no session projection).
                        projection.hoverMarks(at: h, color: weekColor, domain: (start, end))
                    } else if let h = active {
                        // Beside the rule, on the side with more room, so it never covers the hovered points
                        // (above them there's no room: the lines reach the top of the chart).
                        let leftHalf = h < start.addingTimeInterval(end.timeIntervalSince(start) / 2)
                        RuleMark(x: .value("Time", h)).foregroundStyle(ChartInk.muted).lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: leftHalf ? .trailing : .leading, alignment: .top, spacing: 6,
                                        overflowResolution: .init(x: .disabled, y: .fit(to: .chart))) {
                                Tooltip(lines: [tooltipTime.string(from: h)] + series.compactMap { l, pts in
                                    nearest(pts, to: h).map { "\(l.short) \(Int($0.value.rounded()))%" }
                                } + (Self.hit(hits, at: h).map(hitLines) ?? []))
                            }
                        ForEach(series, id: \.0.key) { l, pts in
                            if let p = nearest(pts, to: h) {
                                PointMark(x: .value("Time", p.t), y: .value("Used", p.value)).foregroundStyle(l.color).symbolSize(36)
                            }
                        }
                    }
                }
                .chartXScale(domain: start...end)
                .chartYScale(domain: 0...100)
                .chartXAxis { dayAxis(period: "weekly", start: start, end: end) }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 50, 100]) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ChartInk.grid)
                        AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%") } }
                            .font(.system(size: 9)).foregroundStyle(ChartInk.label)
                    }
                }
                .chartPlotStyle { $0.padding(.trailing, models.isEmpty ? 34 : 50) }   // room for the end labels
                .modifier(HoverLayer(times: times, future: projection?.span, hovered: $hovered))
                .padding(.top, projection == nil ? 6 : 14)   // room for the projection label above 100%
                .frame(height: projection == nil ? 110 : 118)
                .accessibilityLabel(back > 0 ? "Session and weekly usage, \(periodRange(start, end))"
                                    : weekReset == nil ? "Session and weekly usage over the last 7 days"
                                    : "Session and weekly usage this week" + (projection.map { ", projected \($0.endLabel)" } ?? ""))
            }
        }
    }



    /// Where the weekly line is headed: 100% at the moment it runs out, or the share at the reset.
    /// Same numbers as the outlook sentence, so chart and text agree; nothing while it's too early.
    static func projection(_ w: UsageWindow, reset: Date, now: Date) -> ChartProjection? {
        guard !w.isTooEarlyToProject(now: now), w.percent > 0 || w.projectsFromPriorPace(now: now),
              w.percent < 100 else { return nil }
        let hover: (Double) -> String = { "7d ≈ \(Int($0.rounded()))% projected" }
        if let hit = w.projectedLimitAt(now: now) {
            let f = DateFormatter(); f.locale = HumanTime.en; f.dateFormat = "EEE HH:mm"
            return ChartProjection(now: now, from: w.percent, end: hit, to: 100,
                                   endLabel: "100% \(f.string(from: hit))", hoverText: hover)
        }
        guard let p = w.projectedPercentAtReset(now: now) else { return nil }
        return ChartProjection(now: now, from: w.percent, end: reset, to: min(p, 100),
                               endLabel: String(format: "≈ %.0f%%", (p / 5).rounded() * 5), hoverText: hover)   // as the outlook rounds
    }

    /// The hit a hover time falls in: from reaching 100% until the reset (or the last 100% seen).
    static func hit(_ hits: [LimitHit], at t: Date) -> LimitHit? {
        hits.last { $0.at.addingTimeInterval(-600) < t && t.isAtOrBefore(($0.resetAt ?? $0.lastFull).addingTimeInterval(600)) }
    }

    private func nearest(_ pts: [ChartPoint], to t: Date) -> ChartPoint? {
        // The newest of equally near points: a value recorded twice at one time (a reset) shows its later one.
        let p = pts.reversed().min { abs($0.t.timeIntervalSince(t)) < abs($1.t.timeIntervalSince(t)) }
        guard let p, abs(p.t.timeIntervalSince(t)) < 3600 else { return nil }
        return p
    }
}

// MARK: Axes

/// Day ticks: every day for a week, every 7 days for a month, every 6 hours for a day.
@AxisContentBuilder
private func dayAxis(period: String?, start: Date, end: Date) -> some AxisContent {
    switch period {
    case "daily":
        AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ChartInk.grid)
            AxisValueLabel(format: .dateTime.hour()).font(.system(size: 9)).foregroundStyle(ChartInk.label)
        }
    case "weekly":
        AxisMarks(values: .stride(by: .day, count: 1)) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ChartInk.grid)
            AxisValueLabel(format: .dateTime.weekday(.abbreviated)).font(.system(size: 9)).foregroundStyle(ChartInk.label)
        }
    default:
        // Every 7 days from the period start, leaving out both ends so no label is clipped.
        AxisMarks(values: stride(from: start.addingTimeInterval(7 * 86400), to: end.addingTimeInterval(-3 * 86400),
                                 by: 7 * 86400).map { $0 }) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ChartInk.grid)
            AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: 9)).foregroundStyle(ChartInk.label)
        }
    }
}
