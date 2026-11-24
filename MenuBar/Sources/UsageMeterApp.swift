import SwiftUI

@main
struct UsageMeterApp: App {
    @StateObject private var model = UsageModel(
        preview: CommandLine.arguments.contains("--sample")
            ? (CommandLine.arguments.contains("enterprise") ? .sampleEnterprise
               : (CommandLine.arguments.contains("extra") ? UsageSnapshot.sampleWithExtra : UsageSnapshot.sample)
                    .withFableIf(CommandLine.arguments.contains("fable"))) : nil
    )

    init() {
        // `UsageMeter --render-preview out.png [live] [offline] [enterprise] [hover] [light] [daily] [seen] [saved] [compact|dots] [mono] [amount] [extra] [fable] [only5h|only7d] [beside|projected] [update] [panel|settings|scene] [nolabels] [nopercent] [nopace] [noahead] [left|early] [overview] [back=N] [full|burst]` (`hover=0.85`: pointer at 85% of the times): render the panel rows (`panel`: the whole popup; `settings`: its menu bar settings; `scene`: the whole popup opened under the item on a plain menu bar) to a PNG and exit.
        let args = CommandLine.arguments
        if args.contains("--check-update") { Updater.checkFromCommandLine() }
        if let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count {
            PreviewRenderer.run(output: args[i + 1], live: args.contains("live"), offline: args.contains("offline"),
                                enterprise: args.contains("enterprise"))
        }
    }

    var body: some Scene {
        MenuBarExtra {
            UsagePanel(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Renders the data rows to an image for checking the layout without clicking the menu bar.
@MainActor
enum PreviewRenderer {
    static func run(output: String, live: Bool, offline: Bool, enterprise: Bool = false) -> Never {
        let snap: UsageSnapshot
        if live {
            let sem = DispatchSemaphore(value: 0)
            var result: UsageSnapshot?
            Task.detached {
                result = try? await UsageReader().fetchOAuth()
                sem.signal()
            }
            sem.wait()
            // Rate-limited or offline: the numbers the app saved last (see LastUsage).
            if result == nil, let saved = LastUsage.load() {
                fputs("live fetch failed, using the saved numbers\n", stderr); result = saved
            }
            guard let r = result else { fputs("live fetch failed\n", stderr); exit(1) }
            // `seen`: as if the app had watched the budget reset at the start of this month.
            let monthStart = Spend.utc.date(from: Spend.utc.dateComponents([.year, .month], from: Date()))!
            snap = (CommandLine.arguments.contains("seen") ? r.confirmingAssumedReset(seen: monthStart) : r)
                .withPriorPace(from: UsageHistory.load())   // as the app does, for early projections
        } else {
            snap = enterprise ? .sampleEnterprise
                : (CommandLine.arguments.contains("extra") ? UsageSnapshot.sampleWithExtra : UsageSnapshot.sample).withFableIf(CommandLine.arguments.contains("fable"))
        }
        // `update`: as if a newer release were out.
        if CommandLine.arguments.contains("update") { Updater.shared.preview(available: "0.2.0") }
        // Live numbers get the real recorded history; samples get a made-up one.
        let light = CommandLine.arguments.contains("light")
        var logs: [UsageWeight]?
        if live, let period = UsageModel.budgetPeriod(snap) { logs = ClaudeCodeLogs.weights(from: period.start, to: Date()) }
        // `saved`: as if rate-limited, showing numbers saved earlier.
        let saved = CommandLine.arguments.contains("saved")
        let model = UsageModel(preview: snap, problem: saved ? "Too many requests, will retry" : offline ? "Offline" : nil,
                               saved: saved,
                               history: live ? UsageHistory.load() : nil, logWeights: logs)
        writeLabelPreview(model: model, output: output)
        if ["panel", "settings", "scene"].contains(where: CommandLine.arguments.contains) {
            writePanel(model: model, light: light, output: output)
        }
        let view = UsageRows(model: model)
            .padding(UsagePanel.padding)
            .frame(width: UsagePanel.width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, light ? .light : .dark)
            .environment(\.previewHover, previewHoverArg)
            .environment(\.previewBudgetMode, CommandLine.arguments.contains("daily") ? "daily" : nil)
            .environment(\.previewChartScale, CommandLine.arguments.contains("overview") ? "overview" : nil)
            .environment(\.previewBack, previewBackArg)
            .defaultAppStorage(previewStore)
        // AppKit colours (window background, label colours) follow the drawing appearance.
        NSApplication.shared.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            fputs("render failed\n", stderr); exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: output))
        previewStore.removePersistentDomain(forName: previewSuite)
        print("wrote \(output)")
        exit(0)
    }

    /// The settings previews use: from the arguments, in a throwaway store, so an image never shows
    /// (or changes) the ones saved on this Mac, such as the graph's Total / Per day choice.
    private static let previewSuite = "local.usagemeter.preview"
    private static let previewStore: UserDefaults = {
        let a = CommandLine.arguments
        let store = UserDefaults(suiteName: previewSuite)!
        store.removePersistentDomain(forName: previewSuite)
        typealias Key = MenuBarImage.Options.Key
        let settings: [String: Any] = [
            MenuBarImage.Style.key: a.contains("compact") ? "compact" : a.contains("dots") ? "dots" : "bars",
            Key.labels: !a.contains("nolabels"), Key.percent: !a.contains("nopercent") && !a.contains("projected"),
            Key.pace: !a.contains("nopace"), Key.ahead: !a.contains("noahead"),
            Key.aheadAs: a.contains("left") ? "left" : a.contains("early") ? "early" : "points",
            Key.palette: a.contains("mono") ? "mono" : a.contains("alerts") ? "alerts" : "colour",
            Key.budgetAs: a.contains("amount") ? "amount" : "percent",
            "budgetChartMode": a.contains("daily") ? "daily" : "total",
            Key.extra: a.contains("extra"),
            UsagePanel.settingsShownKey: a.contains("panel") || a.contains("scene"),   // the whole popup shows its settings open
            Updater.enabledKey: a.contains("update"),
            Key.limits: a.contains("only5h") ? "session" : a.contains("only7d") ? "week" : "both",
            // `beside`: Projection on; `projected`: on, with Number off (the projection in its place).
            Key.projection: a.contains("projected") || a.contains("beside") ? "on" : "off",
        ]
        for (k, v) in settings { store.set(v, forKey: k) }
        return store
    }()

    /// `panel`: the whole popup, settings included (`settings`: those alone). AppKit draws it in an offscreen window, since
    /// ImageRenderer can't draw AppKit controls (checkboxes). Settings: see `previewStore`.
    private static func writePanel(model: UsageModel, light: Bool, output: String) -> Never {
        let a = CommandLine.arguments
        let appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        NSApplication.shared.appearance = appearance
        // `settings`: only the menu bar settings, as in the popup.
        let content = a.contains("settings")
            ? AnyView(MenuBarSettings(model: model).padding(UsagePanel.padding)
                .frame(width: UsagePanel.width, alignment: .leading))
            : AnyView(UsagePanel(model: model))
        let host = NSHostingView(rootView: content
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, light ? .light : .dark)
            .environment(\.previewHover, previewHoverArg)
            .environment(\.previewBudgetMode, a.contains("daily") ? "daily" : nil)
            .environment(\.previewChartScale, a.contains("overview") ? "overview" : nil)
            .environment(\.previewBack, previewBackArg)
            .defaultAppStorage(previewStore))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))   // let SwiftUI and Charts settle
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fputs("render failed\n", stderr); exit(1)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = a.contains("scene") ? scene(panel: rep, model: model, light: light) : rep
        guard let png = image?.representation(using: .png, properties: [:]) else { fputs("render failed\n", stderr); exit(1) }
        try? png.write(to: URL(fileURLWithPath: output))
        previewStore.removePersistentDomain(forName: previewSuite)
        print("wrote \(output)")
        exit(0)
    }

    /// `scene`: the popup as it opens under the menu bar item, on a plain menu bar with only the
    /// item and a clock (the sample's fetch time), over a plain backdrop. For the README's first
    /// image: no other apps' icons, nothing from this Mac.
    private static func scene(panel: NSBitmapImageRep, model: UsageModel, light: Bool) -> NSBitmapImageRep? {
        guard let item = labelImage(model: model) else { return nil }
        let (margin, barHeight, gap, radius): (CGFloat, CGFloat, CGFloat, CGFloat) = (28, 24, 6, 10)
        let ink = light ? NSColor.black : NSColor.white
        let clockFormat = DateFormatter()
        clockFormat.locale = HumanTime.en; clockFormat.dateFormat = "EEE d MMM  HH:mm"
        let clock = clockFormat.string(from: model.snapshot?.capturedAt ?? Date()) as NSString
        let clockAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: ink]
        let clockSize = clock.size(withAttributes: clockAttrs)
        // macOS centres the popup under the item.
        let itemX = margin + panel.size.width / 2 - item.size.width / 2
        let clockX = itemX + item.size.width + 16
        let size = NSSize(width: max(margin * 2 + panel.size.width, clockX + clockSize.width + 14),
                          height: barHeight + gap + panel.size.height + margin)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        NSAppearance(named: light ? .aqua : .darkAqua)!.performAsCurrentDrawingAppearance {
            let backdrop = light ? NSGradient(starting: NSColor(calibratedRed: 0.80, green: 0.84, blue: 0.90, alpha: 1),
                                              ending: NSColor(calibratedRed: 0.66, green: 0.71, blue: 0.80, alpha: 1))
                                 : NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.23, blue: 0.30, alpha: 1),
                                              ending: NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.11, alpha: 1))
            backdrop?.draw(in: NSRect(origin: .zero, size: size), angle: -90)
            let bar = NSRect(x: 0, y: size.height - barHeight, width: size.width, height: barHeight)
            (light ? NSColor(white: 0.96, alpha: 0.8) : NSColor(white: 0.08, alpha: 0.8)).setFill()
            bar.fill()
            // The item as it looks while its popup is open: on a rounded highlight.
            let itemRect = NSRect(x: itemX, y: bar.midY - item.size.height / 2, width: item.size.width, height: item.size.height)
            ink.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: itemRect.insetBy(dx: -5, dy: -1), xRadius: 5, yRadius: 5).fill()
            item.draw(in: itemRect)
            clock.draw(at: NSPoint(x: clockX, y: bar.midY - clockSize.height / 2), withAttributes: clockAttrs)
            // The popup: rounded, with a shadow and a hairline edge.
            let frame = NSRect(x: margin, y: margin, width: panel.size.width, height: panel.size.height)
            let outline = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.45); shadow.shadowBlurRadius = 18
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            shadow.set()
            NSColor.windowBackgroundColor.setFill(); outline.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            panel.draw(in: frame)
            NSGraphicsContext.restoreGraphicsState()
            ink.withAlphaComponent(0.15).setStroke(); outline.lineWidth = 0.5; outline.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    /// The menu bar item as the arguments set it up.
    private static func labelImage(model: UsageModel) -> NSImage? {
        let args = CommandLine.arguments
        let options = MenuBarImage.Options(labels: !args.contains("nolabels") && model.snapshot?.isBudgetOnly != true,
                                           percent: !args.contains("nopercent") && !args.contains("projected"),
                                           pace: !args.contains("nopace"), ahead: !args.contains("noahead"),
                                           aheadAs: args.contains("left") ? .left : args.contains("early") ? .early : .points,
                                           palette: args.contains("mono") ? .mono : args.contains("alerts") ? .alerts : .colour,
                                           budgetAs: args.contains("amount") ? .amount : .percent,
                                           extra: args.contains("extra"),
                                           limits: args.contains("only5h") ? .session : args.contains("only7d") ? .week : .both,
                                           projection: args.contains("projected") || args.contains("beside") ? .on : .off)
        return MenuBarImage.item(style: args.contains("compact") ? .compact : args.contains("dots") ? .dots : .bars, rows: model.menuBarRows(),
                                 rings: model.compactRings(), extra: model.extraRow(), options: options)
    }

    /// The menu bar item, enlarged 6x, on a light and a dark menu bar (two stacked strips).
    private static func writeLabelPreview(model: UsageModel, output: String) {
        guard let label = labelImage(model: model) else { return }
        let strip = NSSize(width: label.size.width * 6 + 24, height: label.size.height * 6 + 24)
        let canvas = NSImage(size: NSSize(width: strip.width, height: strip.height * 2))
        canvas.lockFocus()
        for (i, (name, white)) in [(NSAppearance.Name.aqua, 0.9), (.darkAqua, 0.15)].enumerated() {
            let y = CGFloat(i) * strip.height
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                NSColor(white: white, alpha: 1).setFill()
                NSRect(x: 0, y: y, width: strip.width, height: strip.height).fill()
                label.draw(in: NSRect(x: 12, y: y + 12, width: strip.width - 24, height: strip.height - 24))
            }
        }
        canvas.unlockFocus()
        if let tiff = canvas.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: output + ".label.png"))
        }
    }
}

/// `back=2`: the chart two periods (or overview pages) back.
private var previewBackArg: Int? {
    CommandLine.arguments.first { $0.hasPrefix("back=") }.flatMap { Int($0.dropFirst(5)) }
}

/// `hover` puts the preview's pointer at 40% of the recorded times; `hover=0.85` at 85%;
/// `hover=1.5` halfway along the dashed projection.
private var previewHoverArg: Double? {
    for a in CommandLine.arguments {
        if a == "hover" { return 0.4 }
        if a.hasPrefix("hover="), let f = Double(a.dropFirst(6)) { return min(max(f, 0), 2) }
    }
    return nil
}
