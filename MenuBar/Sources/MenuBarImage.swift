import AppKit

/// Draws the menu bar item: stacked "5h ▬▬ 8%" / "7d ▬▬ 60%" rows. The number turns
/// orange when that limit is nearly full or projected to run out.
///
/// It can't be a template image, because those are single-colour. Instead it uses a
/// drawing handler with dynamic colours, which AppKit re-runs for the menu bar's
/// current appearance (light or dark, depending on the wallpaper).
enum MenuBarImage {
    struct Row {
        let label: String
        let percent: Double
        let warn: Bool
    }

    private static let height: CGFloat = 18
    private static let rowHeight: CGFloat = 9
    private static let barWidth: CGFloat = 26
    private static let barHeight: CGFloat = 4

    static func make(rows: [Row]) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let measure: [NSAttributedString.Key: Any] = [.font: font]
        let labelWidth = rows.map { ($0.label as NSString).size(withAttributes: measure).width }.max() ?? 0
        let barX = ceil(labelWidth) + 3
        let percents = rows.map { "\(Int($0.percent.rounded()))%" as NSString }
        let percentWidth = ceil(percents.map { $0.size(withAttributes: measure).width }.max() ?? 0)
        let percentRight = barX + barWidth + 3 + percentWidth
        let size = NSSize(width: percentRight, height: height)
        let firstRowBottom = (height + rowHeight * CGFloat(rows.count)) / 2 - rowHeight

        return NSImage(size: size, flipped: false) { _ in
            let text: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            for (i, row) in rows.enumerated() {
                let y = firstRowBottom - CGFloat(i) * rowHeight
                let textHeight = (row.label as NSString).size(withAttributes: text).height
                let textY = y + (rowHeight - textHeight) / 2
                (row.label as NSString).draw(at: NSPoint(x: 0, y: textY), withAttributes: text)

                let track = NSRect(x: barX, y: y + (rowHeight - barHeight) / 2, width: barWidth, height: barHeight)
                NSColor.labelColor.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

                if row.percent > 0 {
                    var fill = track
                    fill.size.width = max(barHeight, barWidth * min(row.percent, 100) / 100)
                    NSColor.labelColor.setFill()
                    NSBezierPath(roundedRect: fill, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
                }

                var number = text
                if row.warn { number[.foregroundColor] = NSColor.systemOrange }
                let percentX = percentRight - percents[i].size(withAttributes: text).width
                percents[i].draw(at: NSPoint(x: percentX, y: textY), withAttributes: number)
            }
            return true
        }
    }
}
