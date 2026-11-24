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
        // `UsageMeter --render-preview out.png [live] [offline] [enterprise] [hover] [light] [daily] [seen] [saved] [compact] [mono] [amount] [extra] [fable] [only5h|only7d] [projected|beside] [update] [panel|settings] [nolabels] [nopercent] [nopace] [noahead] [left|early] [overview] [back=N] [full|burst]` (`hover=0.85`: pointer at 85% of the times): render the panel rows (`panel`: the whole popup; `settings`: its menu bar settings) to a PNG and exit.
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
        if CommandLine.arguments.contains("panel") || CommandLine.arguments.contains("settings") {
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
            MenuBarImage.Style.key: a.contains("compact") ? "compact" : "bars",
            Key.labels: !a.contains("nolabels"), Key.percent: !a.contains("nopercent"),
            Key.pace: !a.contains("nopace"), Key.ahead: !a.contains("noahead"),
            Key.aheadAs: a.contains("left") ? "left" : a.contains("early") ? "early" : "points",
            Key.palette: a.contains("mono") ? "mono" : a.contains("alerts") ? "alerts" : "colour",
            Key.budgetAs: a.contains("amount") ? "amount" : "percent",
            "budgetChartMode": a.contains("daily") ? "daily" : "total",
            Key.extra: a.contains("extra"),
            UsagePanel.settingsShownKey: a.contains("panel"),   // the whole popup shows its settings open
            Updater.enabledKey: a.contains("update"),
            Key.limits: a.contains("only5h") ? "session" : a.contains("only7d") ? "week" : "both",
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
        guard let png = rep.representation(using: .png, properties: [:]) else { fputs("render failed\n", stderr); exit(1) }
        try? png.write(to: URL(fileURLWithPath: output))
        previewStore.removePersistentDomain(forName: previewSuite)
        print("wrote \(output)")
        exit(0)
    }

    /// The menu bar item, enlarged 6x, on a light and a dark menu bar (two stacked strips).
    private static func writeLabelPreview(model: UsageModel, output: String) {
        let args = CommandLine.arguments
        let options = MenuBarImage.Options(labels: !args.contains("nolabels") && model.snapshot?.isBudgetOnly != true, percent: !args.contains("nopercent"),
                                           pace: !args.contains("nopace"), ahead: !args.contains("noahead"),
                                           aheadAs: args.contains("left") ? .left : args.contains("early") ? .early : .points,
                                           palette: args.contains("mono") ? .mono : args.contains("alerts") ? .alerts : .colour,
                                           budgetAs: args.contains("amount") ? .amount : .percent,
                                           extra: args.contains("extra"),
                                           limits: args.contains("only5h") ? .session : args.contains("only7d") ? .week : .both,
                                           projection: args.contains("projected") ? .instead : args.contains("beside") ? .beside : .off)
        guard let label = MenuBarImage.item(style: args.contains("compact") ? .compact : .bars, rows: model.menuBarRows(),
                                            rings: model.compactRings(), extra: model.extraRow(), options: options)
        else { return }
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
