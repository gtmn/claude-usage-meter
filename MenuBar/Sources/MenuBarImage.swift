import AppKit

/// Draws the menu bar item in one of three styles, with the same colour coding:
/// - Bars: stacked "5h ▬▬ 8%" / "7d ▬▬ 60%" rows (one "$" row on an Enterprise/Team seat).
/// - Circle (saved as "compact"): rings with their numbers beside them. Pro/Max: the week outside (the weekly limit
///   furthest ahead of pace, see UsageModel.compactRings) and the session inside;
///   Enterprise/Team: one ring for the budget.
/// - Dots: the text alone, with a small pace-coloured dot before each row.
///
/// Colour coding, as ClaudeUsageBar's pace icon (see PaceLead): green on or under pace, yellow
/// ahead of it, orange well ahead (15+ points) or nearly full, and plain (text colour) early in a
/// window, where a few percent would look far ahead. Text always stays in the text colour:
/// coloured 9 pt text is hard to read in the menu bar.
///
/// Options (checkboxes in the popup): the "5h"/"7d" labels, the % (or, for a budget, the amount
/// used), the pace tick (where usage
/// would be if spread evenly over the window), and, once well ahead, the points ahead ("+24"),
/// the time left until it runs out at that pace ("1.5d left"), or how long before the reset
/// that is ("3d early"). The projection at the reset ("→35%", "→140%") follows the number (under
/// it, beside a single bar or ring), or with Number off stands in its place. Text sits in aligned columns (see Columns).
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
        /// How long until it resets, once it's at 100% (then "left" and "early" say this instead).
        var resetsInWhenFull: TimeInterval? = nil
        /// The budget's amount used, in whole units ("$306"), shown instead of the % when chosen.
        var amount: String? = nil
        /// Where it's heading at the reset ("→35%", "→140%"), and on a $ limit as an amount ("→$530"),
        /// when there's a projection (see UsageWindow.menuBarProjection).
        var projectedPercent: String? = nil
        var projectedAmount: String? = nil

        /// One limit's row: everything the pace colouring needs. Shared by the menu bar and the
        /// popup's bars, so both always show the same colour. `asOf`: when saved numbers were
        /// fetched, so the projection runs at the pace up to then, as the popup's outlook does.
        init(_ w: UsageWindow, label: String, severity: String?, now: Date, asOf: Date? = nil) {
            self.label = label
            percent = w.percent
            expected = w.expectedPercent(now: now)
            critical = w.percent >= 90 || (w.spend?.limitReached ?? false) || (severity.map { $0 != "normal" } ?? false)
            tooEarly = w.isTooEarlyToProject(now: now)
            duration = w.duration
            amount = w.spend?.used.wholeUnits
            projectedPercent = w.menuBarProjection(now: now, asOf: asOf)
            projectedAmount = w.spend == nil ? nil : w.menuBarProjection(now: now, asOf: asOf, amount: true)
            if !(w.percent < 99.5) {
                resetsInWhenFull = w.resetsAt.map { max($0.timeIntervalSince(now), 0) }
            } else if let hit = w.projectedLimitAt(now: now) {
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

    /// Bars, Circle (rings; saved as "compact", its earlier name) or Dots (text with a pace dot).
    enum Style: String, CaseIterable {
        case bars, compact, dots
        static let key = "menuBarStyle"
        var name: String { self == .compact ? "Circle" : rawValue.capitalized }
        /// A saved style that no longer exists (the short-lived "pace") reads as Bars.
        init(saved: String) { self = Style(rawValue: saved) ?? .bars }
    }

    /// Colour: the bars and rings show the pace (green, yellow, orange). Mono: they're drawn in
    /// the menu bar's text colour, like the numbers, so the item looks like the system's own.
    /// Alerts: Mono while on or under pace, the pace colour once ahead of it or nearly full.
    enum Palette: String, CaseIterable {
        case colour, alerts, mono
        var name: String {
            switch self {
            case .colour: return "Colour"
            case .alerts: return "Alerts"
            case .mono: return "Mono"
            }
        }
        init(saved: String) { self = Palette(rawValue: saved) ?? .colour }
    }

    /// For a $ budget: its number as the % of the budget used, or the amount used ("$306").
    enum BudgetAs: String, CaseIterable {
        case percent, amount
        var name: String { self == .percent ? "%" : "Amount" }
        init(saved: String) { self = BudgetAs(rawValue: saved) ?? .percent }
    }

    /// Pro/Max: which limits the menu bar shows (the popup and graph always show all of them).
    /// A chosen limit the account doesn't have falls back to what it has.
    enum Limits: String, CaseIterable {
        case both, session, week
        var name: String {
            switch self {
            case .both: return "Both"
            case .session: return "5h"
            case .week: return "7d"
            }
        }
        init(saved: String) { self = Limits(rawValue: saved) ?? .both }

        /// The rows (or rings) to draw: the chosen one alone, or all when it isn't there.
        func pick(_ rows: [Row]) -> [Row] {
            let label: String? = self == .session ? "5h" : self == .week ? "7d" : nil
            guard let label, rows.contains(where: { $0.label == label }) else { return rows }
            return rows.filter { $0.label == label }
        }
    }

    /// What to show besides the bars or rings. Each is a checkbox in the popup.
    struct Options {
        var labels = true, percent = true, pace = true, ahead = true
        var aheadAs = AheadAs.points
        var palette = Palette.colour
        var budgetAs = BudgetAs.percent
        /// Pro/Max: the extra usage as its own $ item beside the 5h/7d one.
        var extra = false
        var limits = Limits.both
        var projection = Projection.off
        enum Key {
            static let labels = "menuBarShowLabels", percent = "menuBarShowPercent"
            static let pace = "menuBarShowPace", ahead = "menuBarShowAhead", aheadAs = "menuBarAheadAs"
            static let palette = "menuBarPalette", budgetAs = "menuBarBudgetAs", extra = "menuBarShowExtra"
            static let limits = "menuBarLimits", projection = "menuBarProjection"
        }
    }

    /// Where each limit is heading at its reset. On: after the number (under it, beside a single
    /// bar or ring); with Number off, in its place, and the plain number until there is a projection.
    enum Projection: String, CaseIterable {
        case off, on
        var name: String { rawValue.capitalized }
        /// 0.1.14 saved "instead" or "beside": both read as On.
        init(saved: String) { self = saved == "off" || saved.isEmpty ? .off : .on }
    }

    /// How "well ahead" is shown: points ahead of pace ("+24"), the time until it runs out at
    /// this pace ("1.5d left"), or how long before the reset that is ("3d early").
    enum AheadAs: String, CaseIterable {
        case points, left, early
        var name: String {
            switch self {
            case .points: return "+N"
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

    /// The bar's or ring's fill: its pace colour, the text colour in Mono, and in Alerts the pace
    /// colour only once it's ahead of pace or nearly full (yellow or orange).
    static func fillColor(_ row: Row, _ o: Options) -> NSColor {
        switch o.palette {
        case .colour: return color(paceState(row))
        case .mono: return .labelColor
        case .alerts: return paceState(row) >= .ahead ? color(paceState(row)) : .labelColor
        }
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

    /// The text beside a bar or ring, as cells: the label, the %, the projection ("→35%"), and how
    /// far ahead once well ahead ("+24", "1.5d left", or "3d early"). Empty when not shown.
    /// A budget's amount instead of its %, when chosen.
    private static func showsAmount(_ row: Row, _ o: Options) -> Bool { o.budgetAs == .amount && row.amount != nil }

    /// The amount carries its currency, so the "$" label beside it would only repeat it.
    private static func showsLabel(_ row: Row, _ o: Options) -> Bool {
        o.labels && !((o.percent || o.projection == .on) && showsAmount(row, o))
    }

    /// The projection as shown, in the number's unit; empty when off or there's none.
    private static func projection(_ row: Row, _ o: Options) -> String {
        guard o.projection != .off else { return "" }
        return (showsAmount(row, o) ? row.projectedAmount : row.projectedPercent) ?? ""
    }

    private static func cells(_ row: Row, _ o: Options, label: Bool) -> [String] {
        var ahead = ""
        let minutes = (row.duration ?? 0) <= 5 * 3600     // minutes only for the 5 h session
        if o.ahead, o.aheadAs != .points, let wait = row.resetsInWhenFull {
            // At 100% there's no time left to count down: how long until it resets instead. The
            // reset time is known, so the session gets hours and minutes ("1h 10m"), not a rounded hour.
            ahead = (minutes ? hoursMinutes(wait) : span(wait)) + " to reset"
        } else if o.ahead, let lead = row.lead, PaceLead.wellAhead <= lead {
            switch o.aheadAs {
            case .points: ahead = "+\(lead)"    // percentage points ahead; no unit, to keep it short
            case .left: ahead = row.runsOutIn.map { span($0, minutes: minutes) + " left" } ?? ""
            case .early: ahead = row.runsOutEarly.map { span($0, minutes: minutes) + " early" } ?? ""
            }
        }
        let number = showsAmount(row, o) ? row.amount! : "\(Int(row.percent.rounded()))%"
        let labelCell = label && showsLabel(row, o) ? row.label : ""
        let projected = projection(row, o)
        // Number off: the projection in the number's own column, and the plain number until there
        // is one, so rows line up and the item never goes without text early in a window.
        if o.projection == .on, !o.percent { return [labelCell, projected.isEmpty ? number : projected, "", ahead] }
        return [labelCell, o.percent ? number : "", projected, ahead]
    }

    /// One bar or ring with its number and the projection beside it: the projection on a second line
    /// under the number, stacked like two rows, since one row has no room for both (a ring's single
    /// line is larger). Anything else keeps one line per bar or ring.
    private static func lines(_ cells: [[String]], _ o: Options) -> [[String]] {
        guard cells.count == 1, o.projection == .on, let c = cells.first, !c[1].isEmpty, !c[2].isEmpty else { return cells }
        return [[c[0], c[1], "", c[3]], ["", c[2], "", ""]]
    }

    /// Rounded, since it's an estimate: half days from a day on ("1d", "1.5d", "3d"), whole hours
    /// under a day ("5h"), and, only for the 5 h session (`minutes`), 5 minutes under an hour ("45m").
    /// "40m", "1h 10m", "3h": to 5 minutes, for a known time.
    static func hoursMinutes(_ s: TimeInterval) -> String {
        let m = max(5, Int((s / 300).rounded()) * 5)
        return m < 60 ? "\(m)m" : m % 60 == 0 ? "\(m / 60)h" : "\(m / 60)h \(m % 60)m"
    }

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
    /// right-aligned, so "22%" sits under "50%" even when only one row also has "+24".
    /// Columns empty in every row take no space.
    ///
    /// The % column uses fixed-width digits, so it doesn't wiggle as numbers change; the last
    /// column ("+24", "1.5d left") uses ordinary ones, where a fixed-width "1" would sit far from
    /// the "." and, with its foot, look bigger than the digits around it.
    private struct Columns {
        let rows: [[NSString]]
        let widths: [CGFloat]
        let leftAligned: [Bool]
        let fonts: [NSFont]
        static let gap: CGFloat = 3

        init(_ cells: [[String]], leftAligned: [Bool], fonts: [NSFont]) {
            let used = (0..<(cells.first?.count ?? 0)).filter { c in cells.contains { !$0[c].isEmpty } }
            rows = cells.map { r in used.map { r[$0] as NSString } }
            widths = used.map { c in
                ceil(cells.map { ($0[c] as NSString).size(withAttributes: [.font: fonts[c]]).width }.max() ?? 0)
            }
            self.leftAligned = used.map { leftAligned[$0] }
            self.fonts = used.map { fonts[$0] }
        }

        /// Fonts for the label, %, projection and ahead columns at `size`.
        static func fonts(size: CGFloat, weight: NSFont.Weight = .semibold) -> [NSFont] {
            let fixed = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            return [fixed, fixed, fixed, NSFont.systemFont(ofSize: size, weight: weight)]
        }

        var width: CGFloat { widths.isEmpty ? 0 : widths.reduce(0, +) + Self.gap * CGFloat(widths.count - 1) }

        func draw(row i: Int, x: CGFloat, y: CGFloat, color: NSColor) {
            var left = x
            for (c, text) in rows[i].enumerated() {
                let attrs: [NSAttributedString.Key: Any] = [.font: fonts[c], .foregroundColor: color]
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
        let labelled = rows.filter { showsLabel($0, o) }
        let labelWidth = ceil(labelled.map { ($0.label as NSString).size(withAttributes: measure).width }.max() ?? 0)
        let barX = labelled.isEmpty ? 0 : labelWidth + 3
        let textRows = lines(rows.map { cells($0, o, label: false) }, o)
        let columns = Columns(textRows, leftAligned: [true, false, false, false], fonts: Columns.fonts(size: font.pointSize))
        let textX = barX + barWidth + 3
        let size = NSSize(width: columns.width > 0 ? textX + columns.width : barX + barWidth, height: height)
        let firstRowBottom = (height + rowHeight * CGFloat(rows.count)) / 2 - rowHeight
        let firstTextBottom = (height + rowHeight * CGFloat(textRows.count)) / 2 - rowHeight

        return NSImage(size: size, flipped: false) { _ in
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let textHeight = ("0" as NSString).size(withAttributes: attrs).height
            for (i, row) in rows.enumerated() {
                let y = firstRowBottom - CGFloat(i) * rowHeight
                let textY = y + (rowHeight - textHeight) / 2
                if showsLabel(row, o) { (row.label as NSString).draw(at: NSPoint(x: 0, y: textY), withAttributes: attrs) }

                let track = NSRect(x: barX, y: y + (rowHeight - barHeight) / 2, width: barWidth, height: barHeight)
                trackColor.setFill()
                NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

                if row.percent > 0 {
                    var fill = track
                    fill.size.width = max(barHeight, barWidth * min(row.percent, 100) / 100)
                    fillColor(row, o).setFill()
                    NSBezierPath(roundedRect: fill, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
                }
                if o.pace, let expected = row.expected {
                    let x = barX + barWidth * min(max(expected, 0), 100) / 100
                    let tickX = min(max(x - 0.5, barX), barX + barWidth - 1)
                    knockOut { NSRect(x: tickX - 1, y: track.minY, width: 3, height: track.height).fill() }
                    NSColor.labelColor.setFill()
                    NSRect(x: tickX, y: y + 1, width: 1, height: rowHeight - 2).fill()
                }
            }
            // Usually one line per bar; a single bar with the projection beside it has two.
            for i in textRows.indices {
                let y = firstTextBottom - CGFloat(i) * rowHeight + (rowHeight - textHeight) / 2
                columns.draw(row: i, x: textX, y: y, color: .labelColor)
            }
            return true
        }
    }

    /// The item for the chosen style, with Pro/Max extra usage (`extra`) as a second item beside
    /// it: there's no room for a third row in the menu bar's height.
    static func item(style: Style, rows: [Row], rings: [Row], extra: Row?, options o: Options) -> NSImage? {
        let (rows, rings) = (o.limits.pick(rows), o.limits.pick(rings))
        let main = style == .compact && !rings.isEmpty ? makeCompact(rings: rings, options: o)
            : style == .dots && !rows.isEmpty ? makeDots(rows: rows, options: o)
            : !rows.isEmpty ? make(rows: rows, options: o) : nil
        guard let main else { return nil }
        guard o.extra, let extra else { return main }
        let extraItem = style == .compact ? makeCompact(rings: [extra], options: o)
            : style == .dots ? makeDots(rows: [extra], options: o) : make(rows: [extra], options: o)
        return beside(main, extraItem)
    }

    /// Two items side by side. Both keep their drawing handlers, so their colours still follow
    /// the menu bar's appearance.
    static func beside(_ a: NSImage, _ b: NSImage, gap: CGFloat = 6) -> NSImage {
        let size = NSSize(width: a.size.width + gap + b.size.width, height: max(a.size.height, b.size.height))
        return NSImage(size: size, flipped: false) { _ in
            a.draw(in: NSRect(x: 0, y: (size.height - a.size.height) / 2, width: a.size.width, height: a.size.height))
            b.draw(in: NSRect(x: a.size.width + gap, y: (size.height - b.size.height) / 2,
                              width: b.size.width, height: b.size.height))
            return true
        }
    }

    /// Dots: the text alone, with a small dot before each row in its pace colour, since the text
    /// stays in the text colour. Mono has no dots; Alerts shows one only once ahead or nearly full,
    /// but keeps its room, so the text doesn't shift. One row is a single 11 pt line, like the
    /// system's own labels; more rows (or one with the projection under it) stack at 9 pt.
    static func makeDots(rows: [Row], options o: Options = Options()) -> NSImage {
        let textRows = lines(rows.map { cells($0, o, label: o.labels) }, o)
        let small = textRows.count > 1
        let fonts = Columns.fonts(size: small ? 9 : 11, weight: compactWeight(stacked: small))
        let columns = Columns(textRows, leftAligned: [true, false, false, false], fonts: fonts)
        let dot: CGFloat = small ? 5 : 6
        let dotSpace = o.palette == .mono ? 0 : dot + 3
        let size = NSSize(width: max(dotSpace + columns.width, dot), height: height)
        let rowHeight = small ? Self.rowHeight : height
        return NSImage(size: size, flipped: false) { _ in
            let attrs: [NSAttributedString.Key: Any] = [.font: fonts[1], .foregroundColor: NSColor.labelColor]
            let textHeight = ("0" as NSString).size(withAttributes: attrs).height
            // A dot per limit, centred on its line; one limit over two lines gets it centred on both.
            let barRowsBottom = (height + rowHeight * CGFloat(rows.count)) / 2 - rowHeight
            for (i, row) in rows.enumerated() {
                guard let color = dotColor(row, o) else { continue }
                let y = rows.count == 1 ? height / 2 : barRowsBottom - CGFloat(i) * rowHeight + rowHeight / 2
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 0, y: y - dot / 2, width: dot, height: dot)).fill()
            }
            let firstBottom = (height + rowHeight * CGFloat(textRows.count)) / 2 - rowHeight
            for i in textRows.indices {
                let y = firstBottom - CGFloat(i) * rowHeight + (rowHeight - textHeight) / 2
                columns.draw(row: i, x: dotSpace, y: y, color: .labelColor)
            }
            return true
        }
    }

    /// The Dots style's dot: the pace colour, none in Mono, and in Alerts only once it's ahead of
    /// pace or nearly full.
    private static func dotColor(_ row: Row, _ o: Options) -> NSColor? {
        switch o.palette {
        case .mono: return nil
        case .alerts: return paceState(row) >= .ahead ? color(paceState(row)) : nil
        case .colour: return color(paceState(row))
        }
    }

    /// Compact: concentric pace rings (outer first) and their numbers beside them. One ring shows
    /// its number at full size; two (Pro/Max: week outside, session inside) stack theirs like the
    /// Bars rows, session on top.
    /// One ring: regular, like the system's own menu bar labels (the battery's percentage is the same
    /// size and regular). Two rings stack 9 pt numbers, which are too thin to read in regular.
    private static func compactWeight(stacked: Bool) -> NSFont.Weight { stacked ? .semibold : .regular }

    static func makeCompact(rings: [Row], options o: Options = Options()) -> NSImage {
        let rings = Array(rings.prefix(2))
        let stacked = rings.count > 1
        let textRows = lines((stacked ? Array(rings.reversed()) : rings).map { cells($0, o, label: o.labels) }, o)
        let small = textRows.count > 1
        let fonts = Columns.fonts(size: small ? 9 : 11, weight: compactWeight(stacked: small))
        let numberFont = fonts[1]
        let columns = Columns(textRows, leftAligned: [true, false, false, false], fonts: fonts)
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
                    fillColor(row, o).setStroke()
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

            let attrs: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: NSColor.labelColor]
            let rowHeight = small ? Self.rowHeight : height
            let firstBottom = (height + rowHeight * CGFloat(textRows.count)) / 2 - rowHeight
            let textHeight = ("0" as NSString).size(withAttributes: attrs).height
            for i in textRows.indices {
                let y = firstBottom - CGFloat(i) * rowHeight + (rowHeight - textHeight) / 2
                columns.draw(row: i, x: diameter + textGap, y: y, color: .labelColor)
            }
            return true
        }
    }
}
