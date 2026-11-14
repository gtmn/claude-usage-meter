import AppKit

/// Draws the menu bar item in one of two styles, with the same colour coding:
/// - Bars: stacked "5h ▬▬ 8%" / "7d ▬▬ 60%" rows (one "$" row on an Enterprise/Team seat).
/// - Compact: rings with their numbers beside them. Pro/Max: the week outside (the weekly limit
///   furthest ahead of pace, see UsageModel.compactRings) and the session inside;
///   Enterprise/Team: one ring for the budget.
///
/// Colour coding, as ClaudeUsageBar's pace icon (see PaceLead): green on or under pace, yellow
/// ahead of it, orange well ahead (15+ points) or nearly full, and plain (text colour) early in a
/// window, where a few percent would look far ahead. Text always stays in the text colour:
/// coloured 9 pt text is hard to read in the menu bar.
///
/// Options (checkboxes in the popup): the "5h"/"7d" labels, the %, the pace tick (where usage
/// would be if spread evenly over the window), and, once well ahead, the points ahead ("+24 pts"),
/// the time left until it runs out at that pace ("1.5d left"), or how long before the reset
/// that is ("3d early"). Text sits in aligned columns (see Columns).
///
/// It can't be a template image, because those are single-colour. Instead it uses a
/// drawing handler with dynamic colours, which AppKit re-runs for the menu bar's
/// current appearance (light or dark, depending on the wallpaper).
enum MenuBarImage {
    struct Row {
        let label: String
        let percent: Double
        /// Where usage would be by now if spread evenly (the pace marker), when known.
        var expected: Double? = nil
        /// Nearly full, the limit reached, or Claude's own warning.
        var critical = false
        /// Too early in the window to judge the pace (as the outlook says "Too early to project").
        var tooEarly = false
        /// The window's length, to allow minutes only for the 5 h session.
        var duration: TimeInterval? = nil
        /// How long until it runs out at the projected pace, when it runs out before the reset.
        var runsOutIn: TimeInterval? = nil
        /// How long before the reset it runs out at that pace (same condition).
        var runsOutEarly: TimeInterval? = nil

        /// One limit's row: everything the pace colouring needs. Shared by the menu bar and the
        /// popup's bars, so both always show the same colour.
        init(_ w: UsageWindow, label: String, severity: String?, now: Date) {
            self.label = label
            percent = w.percent
            expected = w.expectedPercent(now: now)
            critical = w.percent >= 90 || (w.spend?.limitReached ?? false) || (severity.map { $0 != "normal" } ?? false)
            tooEarly = w.isTooEarlyToProject(now: now)
            duration = w.duration
            if let hit = w.projectedLimitAt(now: now) {
                runsOutIn = max(hit.timeIntervalSince(now), 0)
                runsOutEarly = w.resetsAt.map { max($0.timeIntervalSince(hit), 0) }
            }
        }

        init(label: String, percent: Double, expected: Double? = nil, critical: Bool = false, tooEarly: Bool = false) {
            self.label = label; self.percent = percent; self.expected = expected
            self.critical = critical; self.tooEarly = tooEarly
        }

        /// Points ahead of the pace marker, when the pace can be judged.
        var lead: Int? {
            guard !tooEarly, let expected else { return nil }
            return PaceLead.points(used: percent, expected: expected)
        }
    }

    enum Style: String, CaseIterable {
        case bars, compact
        static let key = "menuBarStyle"
        var name: String { rawValue.capitalized }
        /// A saved style that no longer exists (the short-lived "pace") reads as Bars.
        init(saved: String) { self = Style(rawValue: saved) ?? .bars }
    }

    /// What to show besides the bars or rings. Each is a checkbox in the popup.
    struct Options {
        var labels = true, percent = true, pace = true, ahead = true
        var aheadAs = AheadAs.points
        enum Key {
            static let labels = "menuBarShowLabels", percent = "menuBarShowPercent"
            static let pace = "menuBarShowPace", ahead = "menuBarShowAhead", aheadAs = "menuBarAheadAs"
        }
    }

    /// How "well ahead" is shown: points ahead of pace ("+24 pts"), the time until it runs out at
    /// this pace ("1.5d left"), or how long before the reset that is ("3d early").
    enum AheadAs: String, CaseIterable {
        case points, left, early
        var name: String {
            switch self {
            case .points: return "+N pts"
            case .left: return "time left"
            case .early: return "early"
            }
        }
        /// A saved choice that no longer exists (the short-lived "+time") reads as points.
        init(saved: String) { self = AheadAs(rawValue: saved) ?? .points }
    }

    enum PaceState: Int, Comparable {
        case unknown, under, ahead, far
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    static func paceState(_ row: Row) -> PaceState {
        if row.critical { return .far }
        guard let lead = row.lead else { return .unknown }
        return PaceLead.wellAhead <= lead ? .far : 0 < lead ? .ahead : .under
    }

    static func color(_ state: PaceState) -> NSColor {
        switch state {
        case .unknown: return .labelColor
        case .under: return .systemGreen
        case .ahead: return .systemYellow
        // Orange, not red: red on a thin bar or ring is harsh on the eye in the menu bar.
        case .far: return lightOrange
        }
    }

    /// The popup's orange (system orange as dark mode draws it, the one "Runs out …" uses), on any
    /// menu bar: the menu bar may draw the icon with the light variant, a deeper orange.
    private static let lightOrange: NSColor = {
        var c = NSColor.systemOrange
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            c = NSColor.systemOrange.usingColorSpace(.sRGB) ?? c
        }
        return c
    }()

    /// Clears what's under `draw` (the bar or ring and its fill), so the pace tick drawn after
    /// it has a transparent gap on each side and shows on any fill, even one in the tick's colour.
    private static func knockOut(_ draw: () -> Void) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        ctx.compositingOperation = .clear
        draw()
        ctx.restoreGraphicsState()
    }

    /// The text beside a bar or ring, as cells: the label, the %, and how far ahead once well
    /// ahead ("+24 pts", "1.5d left", or "3d early"). Empty when not shown.
    private static func cells(_ row: Row, _ o: Options, label: Bool) -> [String] {
        var ahead = ""
        if o.ahead, let lead = row.lead, PaceLead.wellAhead <= lead {
            let minutes = (row.duration ?? 0) <= 5 * 3600     // minutes only for the 5 h session
            switch o.aheadAs {
            case .points: ahead = "+\(lead) pts"    // percentage points, not a relative %
            case .left: ahead = row.runsOutIn.map { span($0, minutes: minutes) + " left" } ?? ""
            case .early: ahead = row.runsOutEarly.map { span($0, minutes: minutes) + " early" } ?? ""
            }
        }
        return [label ? row.label : "", o.percent ? "\(Int(row.percent.rounded()))%" : "", ahead]
    }

    /// Rounded, since it's an estimate: half days from a day on ("1d", "1.5d", "3d"), whole hours
    /// under a day ("5h"), and, only for the 5 h session (`minutes`), 5 minutes under an hour ("45m").
    static func span(_ s: TimeInterval, minutes allowMinutes: Bool = false) -> String {
        let minutes = s / 60
        if minutes < 57.5 {
            return allowMinutes ? "\(max(5, Int((minutes / 5).rounded()) * 5))m" : "1h"
        }
        let hours = minutes / 60
        if hours < 23.5 { return "\(Int(hours.rounded()))h" }
        let halves = max(2, Int((hours / 12).rounded()))
        return halves % 2 == 0 ? "\(halves / 2)d" : "\(halves / 2).5d"
    }

    /// Text beside the bars or rings in aligned columns: labels left-aligned, numbers
    /// right-aligned, so "22%" sits under "50%" even when only one row also has "+24 pts".
    /// Columns empty in every row take no space.
    private struct Columns {
        let rows: [[NSString]]
        let widths: [CGFloat]
        let leftAligned: [Bool]
        static let gap: CGFloat = 3

        init(_ cells: [[String]], leftAligned: [Bool], attrs: [NSAttributedString.Key: Any]) {
            let used = (0..<(cells.first?.count ?? 0)).filter { c in cells.contains { !$0[c].isEmpty } }
            rows = cells.map { r in used.map { r[$0] as NSString } }
            widths = used.map { c in ceil(cells.map { ($0[c] as NSString).size(withAttributes: attrs).width }.max() ?? 0) }
            self.leftAligned = used.map { leftAligned[$0] }
        }

        var width: CGFloat { widths.isEmpty ? 0 : widths.reduce(0, +) + Self.gap * CGFloat(widths.count - 1) }

        func draw(row i: Int, x: CGFloat, y: CGFloat, attrs: [NSAttributedString.Key: Any]) {
            var left = x
            for (c, text) in rows[i].enumerated() {
                let w = text.size(withAttributes: attrs).width
                text.draw(at: NSPoint(x: leftAligned[c] ? left : left + widths[c] - w, y: y), withAttributes: attrs)
                left += widths[c] + Self.gap
            }
        }
    }

    /// The unfilled part of a bar or ring: faint, so the coloured fill stands out against the
    /// menu bar instead of a light grey track (orange on light grey has little contrast).
    /// Looked up at draw time: the alpha copy follows the appearance being drawn (light or dark
    /// menu bar) only when made inside the drawing handler.
    private static var trackColor: NSColor { NSColor.labelColor.withAlphaComponent(0.15) }

    private static let height: CGFloat = 18
    private static let rowHeight: CGFloat = 9
    private static let barWidth: CGFloat = 26
    private static let barHeight: CGFloat = 4

    static func make(rows: [Row], options o: Options = Options()) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let measure: [NSAttributedString.Key: Any] = [.font: font]
        let labelWidth = o.labels ? ceil(rows.map { ($0.label as NSString).size(withAttributes: measure).width }.max() ?? 0) : 0
        let barX = o.labels ? labelWidth + 3 : 0
        let columns = Columns(rows.map { cells($0, o, label: false) }, leftAligned: [true, false, false], attrs: measure)
        let textX = barX + barWidth + 3
        let size = NSSize(width: columns.width > 0 ? textX + columns.width : barX + barWidth, height: height)
        let firstRowBottom = (height + rowHeight * CGFloat(rows.count)) / 2 - rowHeight

        return NSImage(size: size, flipped: false) { _ in
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            for (i, row) in rows.enumerated() {
                let y = firstRowBottom - CGFloat(i) * rowHeight
                let textHeight = ("0" as NSString).size(withAttributes: attrs).height
                let textY = y + (rowHeight - textHeight) / 2
                if o.labels { (row.label as NSString).draw(at: NSPoint(x: 0, y: textY), withAttributes: attrs) }

                let track = NSRect(x: barX, y: y + (rowHeight - barHeight) / 2, width: barWidth, height: barHeight)
                trackColor.setFill()
                NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

                if row.percent > 0 {
                    var fill = track
                    fill.size.width = max(barHeight, barWidth * min(row.percent, 100) / 100)
                    color(paceState(row)).setFill()
                    NSBezierPath(roundedRect: fill, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
                }
                if o.pace, let expected = row.expected {
                    let x = barX + barWidth * min(max(expected, 0), 100) / 100
                    let tickX = min(max(x - 0.5, barX), barX + barWidth - 1)
                    knockOut { NSRect(x: tickX - 1, y: track.minY, width: 3, height: track.height).fill() }
                    NSColor.labelColor.setFill()
                    NSRect(x: tickX, y: y + 1, width: 1, height: rowHeight - 2).fill()
                }

                columns.draw(row: i, x: textX, y: textY, attrs: attrs)
            }
            return true
        }
    }

    /// Compact: concentric pace rings (outer first) and their numbers beside them. One ring shows
    /// its number at full size; two (Pro/Max: week outside, session inside) stack theirs like the
    /// Bars rows, session on top.
    static func makeCompact(rings: [Row], options o: Options = Options()) -> NSImage {
        let rings = Array(rings.prefix(2))
        let stacked = rings.count > 1
        let font = NSFont.monospacedDigitSystemFont(ofSize: stacked ? 9 : 11, weight: .semibold)
        let textRows = stacked ? Array(rings.reversed()) : rings
        let columns = Columns(textRows.map { cells($0, o, label: o.labels) }, leftAligned: [true, false, false],
                              attrs: [.font: font])
        let diameter: CGFloat = stacked ? 16 : 13, line: CGFloat = stacked ? 2.2 : 2.5
        let ringGap: CGFloat = 1
        let textGap: CGFloat = columns.width > 0 ? 3 : 0
        let size = NSSize(width: diameter + textGap + columns.width, height: height)
        return NSImage(size: size, flipped: false) { _ in
            let center = NSPoint(x: diameter / 2, y: height / 2)
            for (i, row) in rings.enumerated() {
                let radius = (diameter - line) / 2 - CGFloat(i) * (line + ringGap)
                let track = NSBezierPath(); track.lineWidth = line
                track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                trackColor.setStroke()
                track.stroke()

                if row.percent > 0 {
                    // Clockwise from 12 o'clock; at least a dot's worth so a small % is still visible.
                    let sweep = max(min(row.percent, 100) / 100 * 360, 12)
                    let arc = NSBezierPath(); arc.lineWidth = line; arc.lineCapStyle = .round
                    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
                    color(paceState(row)).setStroke()
                    arc.stroke()
                }
                if o.pace, let expected = row.expected {
                    // The pace marker: a short radial tick across this ring's band only (beyond it,
                    // the ring reads as a "Q", or the tick runs into the other ring).
                    let a = (90 - min(max(expected, 0), 100) / 100 * 360) * .pi / 180
                    let (inner, outer) = (radius - line / 2 - 0.5, radius + line / 2)
                    let tick = NSBezierPath(); tick.lineWidth = 1.2; tick.lineCapStyle = .butt
                    tick.move(to: NSPoint(x: center.x + cos(a) * inner, y: center.y + sin(a) * inner))
                    tick.line(to: NSPoint(x: center.x + cos(a) * outer, y: center.y + sin(a) * outer))
                    knockOut {
                        let gap = tick.copy() as! NSBezierPath
                        gap.lineWidth = tick.lineWidth + 2
                        gap.stroke()
                    }
                    NSColor.labelColor.setStroke()
                    tick.stroke()
                }
            }

            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let rowHeight = stacked ? Self.rowHeight : height
            let firstBottom = (height + rowHeight * CGFloat(textRows.count)) / 2 - rowHeight
            let textHeight = ("0" as NSString).size(withAttributes: attrs).height
            for i in textRows.indices {
                let y = firstBottom - CGFloat(i) * rowHeight + (rowHeight - textHeight) / 2
                columns.draw(row: i, x: diameter + textGap, y: y, attrs: attrs)
            }
            return true
        }
    }
}
