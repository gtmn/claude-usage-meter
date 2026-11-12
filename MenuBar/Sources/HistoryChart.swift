import Charts
import SwiftUI

// Usage history as a line over time, like a temperature curve.
// - Budget-only accounts (Enterprise/Team): money spent across the budget period,
//   with a dashed projection to the reset, or per UTC day as bars. Stretches the app didn't
//   record are estimated from Claude Code's logs and drawn lighter.
// - Pro/Max: the 5 h and 7 d percentages over the last 7 days.
//
// Chart rules (dataviz skill): 2 px lines with round caps, hairline solid gridlines,
// value at the line's end, text in text colours (never the line colour), one series
// colour per entity (see ChartInk for why the second one is magenta).

struct HistoryChart: View {
    @ObservedObject var model: UsageModel
    let now: Date

    var body: some View {
        if let s = model.snapshot {
            if s.isBudgetOnly, let w = s.window("extra_usage"), w.spend != nil {
                BudgetHistoryChart(window: w, history: model.history, logWeights: model.logWeights, now: now)
            } else if s.window("seven_day") != nil || s.window("five_hour") != nil {
                LimitsHistoryChart(history: model.history, now: now)
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
                if p.0.timeIntervalSince(prev.0) > gap { run += 1 }
                else if p.2 != prev.2 { run += 1; out.append(ChartPoint(t: prev.0, value: prev.1, run: run, estimated: p.2)) }
            }
            out.append(ChartPoint(t: p.0, value: p.1, run: run, estimated: p.2))
        }
        return out
    }
}

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
extension EnvironmentValues {
    var previewHover: Double? {
        get { self[PreviewHoverKey.self] }
        set { self[PreviewHoverKey.self] = newValue }
    }
    var previewBudgetMode: String? {
        get { self[PreviewBudgetModeKey.self] }
        set { self[PreviewBudgetModeKey.self] = newValue }
    }
}

private func activeHover(_ hovered: Date?, preview: Double?, times: [Date]) -> Date? {
    if let hovered { return hovered }
    guard let f = preview, !times.isEmpty else { return nil }
    return times[Int(Double(times.count - 1) * f)]
}

/// The tooltip box drawn above a hovered point.
private struct Tooltip: View {
    let lines: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, s in
                Text(s).font(.system(size: i == 0 ? 10 : 11, weight: i == 0 ? .regular : .semibold))
                    .foregroundStyle(i == 0 ? Color.secondary : Color.primary)
            }
        }
        .monospacedDigit()
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(.background.shadow(.drop(radius: 2))))
    }
}

private let tooltipTime: DateFormatter = {
    let f = DateFormatter(); f.locale = HumanTime.en; f.dateFormat = "EEE d MMM, HH:mm"; return f
}()

/// Hover layer: maps the pointer to the nearest recorded time.
private struct HoverLayer: ViewModifier {
    let times: [Date]
    @Binding var hovered: Date?

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let loc) = phase, let frame = proxy.plotFrame else { hovered = nil; return }
                        let x = loc.x - geo[frame].origin.x
                        guard let t: Date = proxy.value(atX: x), !times.isEmpty else { hovered = nil; return }
                        hovered = times.min { abs($0.timeIntervalSince(t)) < abs($1.timeIntervalSince(t)) }
                    }
            }
        }
    }
}

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
private struct ModeSwitch: View {
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
    @AppStorage("budgetChartMode") private var savedMode = "total"
    @Environment(\.previewBudgetMode) private var previewMode

    var body: some View {
        let spend = window.spend!
        let reset = window.resetsAt ?? now
        let start = reset.addingTimeInterval(-(window.duration ?? 30 * 86400))
        let period = spend.period
        let current = HistoryPoint(t: now, key: window.key, percent: window.percent, usedMinor: spend.used.minor)
        let recorded = history.budgetSeries(window.key, periodStart: start, current: current)
        let filled = UsageHistory.filledBudget(recorded, periodStart: start, weights: logWeights, limitMinor: spend.limit.minor)
        let perDayAllowed = period != "daily"
        let mode = perDayAllowed ? (previewMode ?? savedMode) : "total"
        let unit = period == "weekly" ? "week" : period == "daily" ? "day" : "month"

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ChartHeader(title: mode == "daily" ? "Spent per day" : "Spent this \(unit)")
                if mode == "daily" { Text("UTC days").font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer()
                if perDayAllowed {
                    ModeSwitch(mode: Binding(get: { mode }, set: { savedMode = $0 }),
                               options: [("total", "Total"), ("daily", "Per day")])
                }
            }
            if filled.count < 2 {
                EmptyHistory()
            } else if mode == "daily" {
                DailySpendBars(window: window, days: UsageHistory.dailySpend(filled), start: start, end: reset, now: now)
            } else {
                BudgetLine(window: window, points: filled, start: start, reset: reset, now: now)
            }
            if let note = Self.footnote(filled, start: start) {
                Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Says where the curve isn't recorded: estimated from the logs, or not known at all.
    static func footnote(_ pts: [HistoryPoint], start: Date) -> String? {
        if pts.contains(where: { $0.estimated == true }) {
            return "Lighter: estimated from Claude Code's logs on this Mac, scaled to the real totals."
        }
        if let first = pts.first, first.t.timeIntervalSince(start) > UsageHistory.fillableGap {
            return "Recorded since \(localDayTime.string(from: first.t)); no Claude Code logs cover the time before."
        }
        return nil
    }
}

/// Money spent so far as a line, with a dashed projection to the reset.
private struct BudgetLine: View {
    let window: UsageWindow
    let points: [HistoryPoint]
    let start: Date, reset: Date, now: Date
    @Environment(\.colorScheme) private var scheme
    @Environment(\.previewHover) private var previewHover
    @State private var hovered: Date?

    var body: some View {
        let spend = window.spend!
        let code = spend.limit.currency
        let scale = pow(10, Double(spend.limit.exponent))
        let line = ChartPoint.runs(points.map { ($0.t, Double($0.usedMinor ?? 0) / scale, $0.estimated == true) })
        let projectable = !window.isTooEarlyToProject(now: now)
            && (spend.used.minor > 0 || window.projectsFromPriorPace(now: now))
        let projected = projectable ? window.projectedPercentAtReset(now: now).map { spend.limit.amount * $0 / 100 } : nil
        let peak = max(spend.used.amount, projected ?? 0)
        // Show the whole budget only when the curve gets near it; otherwise the line would hug the floor.
        let showLimit = spend.limit.amount <= niceCeil(peak * 1.15) * 1.5
        let top = showLimit ? niceCeil(spend.limit.amount * 1.05) : niceCeil(peak * 1.15)
        let tint = ChartInk.series1(scheme)
        let times = line.map(\.t)
        let active = activeHover(hovered, preview: previewHover, times: times)

        Chart {
            if showLimit {
                RuleMark(y: .value("Budget", spend.limit.amount))
                    .foregroundStyle(ChartInk.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, alignment: .leading, spacing: 2) {
                        Text("Budget \(currency(spend.limit.amount, code))")
                            .font(.system(size: 9)).foregroundStyle(ChartInk.label)
                    }
            }
            ForEach(line) { p in
                LineMark(x: .value("Time", p.t), y: .value("Spent", p.value), series: .value("Run", "spent-\(p.run)"))
                    .foregroundStyle(p.estimated ? tint.opacity(0.45) : tint)
                    .lineStyle(ChartInk.line)
            }
            if let projected {
                LineMark(x: .value("Time", now), y: .value("Spent", spend.used.amount), series: .value("Run", "projection"))
                    .foregroundStyle(tint.opacity(0.7)).lineStyle(ChartInk.dashed)
                LineMark(x: .value("Time", reset), y: .value("Spent", projected), series: .value("Run", "projection"))
                    .foregroundStyle(tint.opacity(0.7)).lineStyle(ChartInk.dashed)
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("≈ \(currency(projected, code))").font(.system(size: 9)).foregroundStyle(ChartInk.label)
                    }
            }
            // Value at the line's end.
            PointMark(x: .value("Time", now), y: .value("Spent", spend.used.amount))
                .foregroundStyle(tint).symbolSize(28)
                .annotation(position: .top, spacing: 3) {
                    if active == nil {
                        Text(currency(spend.used.amount, code)).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.primary).monospacedDigit()
                    }
                }
            if let h = active, let p = line.last(where: { $0.t == h }) {
                RuleMark(x: .value("Time", p.t)).foregroundStyle(ChartInk.muted).lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(x: .value("Time", p.t), y: .value("Spent", p.value))
                    .foregroundStyle(tint).symbolSize(40)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Tooltip(lines: [tooltipTime.string(from: p.t),
                                        currency(p.value, code, decimals: spend.limit.exponent) + (p.estimated ? " (estimated)" : "")])
                    }
            }
        }
        .chartXScale(domain: start...reset)
        .chartYScale(domain: 0...top)
        .chartXAxis { dayAxis(period: spend.period, start: start, end: reset) }
        .chartYAxis { moneyAxis(top: top, code: code) }
        .modifier(HoverLayer(times: times, hovered: $hovered))
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
    @State private var hovered: Date?

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
    let now: Date
    @Environment(\.colorScheme) private var scheme
    @Environment(\.previewHover) private var previewHover
    @State private var hovered: Date?

    private struct Line { let key, name, short: String; let color: Color }

    var body: some View {
        let start = now.addingTimeInterval(-7 * 86400)
        let lines = [
            Line(key: "seven_day", name: "Week (7 d)", short: "7d", color: ChartInk.series1(scheme)),
            Line(key: "five_hour", name: "Session (5 h)", short: "5h", color: ChartInk.series2(scheme)),
        ]
        let series = lines.map { l in
            (l, ChartPoint.runs(history.series(l.key, from: start, to: now).map { ($0.t, $0.percent) }))
        }.filter { $0.1.count >= 1 }
        let times = Array(Set(series.flatMap { $0.1.map(\.t) })).sorted()
        let active = activeHover(hovered, preview: previewHover, times: times)

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ChartHeader(title: "Last 7 days")
                Spacer()
                // Legend: a short line key beside each name (identity is never colour alone;
                // the line ends are labelled too).
                ForEach(series.map(\.0), id: \.key) { l in
                    HStack(spacing: 4) {
                        Capsule().fill(l.color).frame(width: 10, height: 2)
                        Text(l.name).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            if series.allSatisfy({ $0.1.count < 2 }) {
                EmptyHistory()
            } else {
                Chart {
                    ForEach(series, id: \.0.key) { l, pts in
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
                    if let h = active {
                        RuleMark(x: .value("Time", h)).foregroundStyle(ChartInk.muted).lineStyle(StrokeStyle(lineWidth: 1))
                            .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                                Tooltip(lines: [tooltipTime.string(from: h)] + series.compactMap { l, pts in
                                    nearest(pts, to: h).map { "\(l.short) \(Int($0.value.rounded()))%" }
                                })
                            }
                        ForEach(series, id: \.0.key) { l, pts in
                            if let p = nearest(pts, to: h) {
                                PointMark(x: .value("Time", p.t), y: .value("Used", p.value)).foregroundStyle(l.color).symbolSize(36)
                            }
                        }
                    }
                }
                .chartXScale(domain: start...now)
                .chartYScale(domain: 0...100)
                .chartXAxis { dayAxis(period: "weekly", start: start, end: now) }
                .chartYAxis {
                    AxisMarks(position: .leading, values: [0, 50, 100]) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(ChartInk.grid)
                        AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%") } }
                            .font(.system(size: 9)).foregroundStyle(ChartInk.label)
                    }
                }
                .chartPlotStyle { $0.padding(.trailing, 34) }   // room for the end labels
                .modifier(HoverLayer(times: times, hovered: $hovered))
                .padding(.top, 6)
                .frame(height: 110)
                .accessibilityLabel("Session and weekly usage over the last 7 days")
            }
        }
    }

    private func nearest(_ pts: [ChartPoint], to t: Date) -> ChartPoint? {
        let p = pts.min { abs($0.t.timeIntervalSince(t)) < abs($1.t.timeIntervalSince(t)) }
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
