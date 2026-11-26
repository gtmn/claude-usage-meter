import AppKit

/// `--render-preview out.png sheet=pro-max|enterprise`: the README's overview of the menu bar
/// settings in one image. Each row names its settings as the popup does and shows the item at its
/// real size on a dark menu bar (like the popups' screenshots), from the sample numbers; the
/// Pro/Max sheet shows each item with and without its 5h / 7d labels. Drawn at 2x.
@MainActor
enum MenuBarSheet {
    struct Row {
        let caption: String
        let args: [String]
        var note: String? = nil
    }

    static let proMax: [Row] = [
        Row(caption: "Indicator: Bar · Colours: Colour · Number: %", args: []),
        Row(caption: "Indicator: Circle", args: ["compact"]),
        Row(caption: "Indicator: Dot", args: ["dots"]),
        Row(caption: "Indicator: Gauge", args: ["icon"]),
        Row(caption: "Indicator: Off", args: ["text"], note: "The numbers alone."),
        Row(caption: "Colours: Alerts", args: ["alerts"],
            note: "Colour only for a limit projected to run out: 7d here."),
        Row(caption: "Colours: Mono", args: ["mono"]),
        Row(caption: "Projection: On", args: ["beside"], note: "Where each limit is headed at its reset."),
        Row(caption: "Projection: On · Number: Off", args: ["projected"]),
        Row(caption: "Limits: 5h", args: ["only5h"]),
        Row(caption: "Extra usage: Amount", args: ["extra", "amount"]),
        Row(caption: "Indicator: Dot · Colours: Alerts · Projection: On", args: ["dots", "alerts", "beside"],
            note: "A dot only beside a limit projected to run out: 7d, not the session."),
        Row(caption: "The same, the session projected to run out", args: ["dots", "alerts", "beside", "runout"],
            note: "5h at 70% with 2 h left heads past 100%, so only it gets a dot: 7d at 40% lasts."),
        Row(caption: "Old numbers: offline, rate-limited or signed out", args: ["stale"],
            note: "No new numbers for 15 minutes, or signed out: faded and grey."),
        Row(caption: "Old numbers · Indicator: Dot", args: ["dots", "stale"],
            note: "Dot: one red dot instead of the pace colours."),
    ]

    static let enterprise: [Row] = [
        Row(caption: "Indicator: Bar · Number: %", args: ["enterprise"]),
        Row(caption: "Number: Amount", args: ["enterprise", "amount"]),
        Row(caption: "Number: Amount · Projection: On", args: ["enterprise", "amount", "beside"],
            note: "The amount used, and where it's headed at the reset."),
        Row(caption: "Indicator: Dot · Colours: Colour · Amount · Projection: On",
            args: ["enterprise", "dots", "amount", "beside"], note: "Green: the budget lasts until the reset."),
        Row(caption: "Indicator: Dot · Colours: Alerts · Amount · Projection: On",
            args: ["enterprise", "dots", "alerts", "amount", "beside"],
            note: "On track, so no dot: with Alerts it only shows once the budget is projected to run out."),
        Row(caption: "The same, spending faster than the budget lasts",
            args: ["enterprise", "dots", "alerts", "amount", "beside", "over"],
            note: "Projected past the budget: the dot appears."),
        Row(caption: "Old numbers: offline, rate-limited or signed out",
            args: ["enterprise", "amount", "beside", "stale"],
            note: "No new numbers for 15 minutes, or signed out: faded and grey."),
        Row(caption: "Old numbers · Indicator: Dot", args: ["enterprise", "dots", "amount", "beside", "stale"],
            note: "Dot: a red dot instead of the pace colour."),
    ]

    static func write(_ name: String, output: String) -> Never {
        guard let rows = ["pro-max": proMax, "enterprise": enterprise][name] else {
            fputs("unknown sheet \(name): pro-max or enterprise\n", stderr); exit(1)
        }
        let withoutLabels = name == "pro-max"
        let title = withoutLabels ? "Menu bar item · Pro / Max" : "Menu bar item · Enterprise / Team budget"
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let items: [(NSImage?, NSImage?)] = rows.map { row in
            let model = UsageModel(preview: snapshot(row.args))
            return (PreviewRenderer.labelImage(model: model, args: row.args),
                    withoutLabels ? PreviewRenderer.labelImage(model: model, args: row.args + ["nolabels"]) : nil)
        }

        let captionFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let noteFont = NSFont.systemFont(ofSize: 11)
        let headFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let ink = NSColor(white: 0.9, alpha: 1), muted = NSColor(white: 0.6, alpha: 1)
        func width(_ s: String, _ f: NSFont) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: f]).width) }

        let (pad, gap, rowHeight, headHeight): (CGFloat, CGFloat, CGFloat, CGFloat) = (16, 24, 26, 20)
        // Notes wrap under their caption, within its column (two lines at most at this width).
        let captionWidth = max(rows.map { width($0.caption, captionFont) }.max() ?? 0, 300)
        func noteHeight(_ s: String?) -> CGFloat {
            guard let s else { return 0 }
            return ceil((s as NSString).boundingRect(with: NSSize(width: captionWidth, height: 1000),
                                                     options: .usesLineFragmentOrigin, attributes: [.font: noteFont]).height)
        }
        let (captionLine, inset): (CGFloat, CGFloat) = (17, 6)
        func blockHeight(_ row: Row) -> CGFloat { row.note == nil ? rowHeight : inset + captionLine + noteHeight(row.note) + inset }
        let col1 = max(items.compactMap { $0.0?.size.width }.max() ?? 0, withoutLabels ? width("Labels", headFont) : 0)
        let col2 = withoutLabels ? max(items.compactMap { $0.1?.size.width }.max() ?? 0, width("Labels off", headFont)) : 0
        let columns = pad + captionWidth + gap + col1 + (withoutLabels ? gap + col2 : 0) + pad
        let size = NSSize(width: max(columns, pad + width(title, titleFont) + pad),
                          height: pad + headHeight + (withoutLabels ? headHeight : 0)
                              + rows.reduce(0) { $0 + blockHeight($1) } + pad)

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            NSColor(white: 0.13, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            // Top-down layout in a bottom-up context: `y` is the top of what's drawn next.
            var y = size.height - pad
            func text(_ s: String, _ f: NSFont, _ color: NSColor, x: CGFloat, top: CGFloat, height: CGFloat) {
                let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: color]
                let h = (s as NSString).size(withAttributes: attrs).height
                (s as NSString).draw(at: NSPoint(x: x, y: top - height + (height - h) / 2), withAttributes: attrs)
            }
            text(title, titleFont, ink, x: pad, top: y, height: headHeight)
            y -= headHeight
            let x1 = pad + captionWidth + gap, x2 = x1 + col1 + gap
            if withoutLabels {
                text("Labels", headFont, muted, x: x1, top: y, height: headHeight)
                text("Labels off", headFont, muted, x: x2, top: y, height: headHeight)
                y -= headHeight
            }
            for (row, (on, off)) in zip(rows, items) {
                // A faint line between rows.
                NSColor(white: 1, alpha: 0.08).setFill()
                NSRect(x: pad, y: y - 0.5, width: size.width - 2 * pad, height: 0.5).fill()
                let block = blockHeight(row)
                if let note = row.note {
                    text(row.caption, captionFont, ink, x: pad, top: y - inset, height: captionLine)
                    let h = noteHeight(note)
                    (note as NSString).draw(with: NSRect(x: pad, y: y - inset - captionLine - h, width: captionWidth, height: h),
                                            options: .usesLineFragmentOrigin,
                                            attributes: [.font: noteFont, .foregroundColor: muted])
                } else {
                    text(row.caption, captionFont, ink, x: pad, top: y, height: rowHeight)
                }
                // The items sit level with the middle of the row, caption and note together.
                for (image, x) in [(on, x1), (off, x2)] {
                    guard let image else { continue }
                    image.draw(in: NSRect(x: x, y: y - block + (block - image.size.height) / 2,
                                          width: image.size.width, height: image.size.height))
                }
                y -= block
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: output))) != nil else { fputs("render failed\n", stderr); exit(1) }
        print("wrote \(output)")
        exit(0)
    }

    /// The sample numbers a row's arguments ask for, as `--render-preview` picks them.
    private static func snapshot(_ args: [String]) -> UsageSnapshot {
        args.contains("enterprise") ? .sampleEnterprise(over: args.contains("over"))
            : args.contains("extra") ? .sampleWithExtra : .sample(args)
    }
}
