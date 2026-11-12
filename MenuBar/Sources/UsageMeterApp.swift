import SwiftUI

@main
struct UsageMeterApp: App {
    @StateObject private var model = UsageModel(
        preview: CommandLine.arguments.contains("--sample")
            ? (CommandLine.arguments.contains("enterprise") ? .sampleEnterprise : .sample) : nil
    )

    init() {
        // `UsageMeter --render-preview out.png [live] [offline] [enterprise] [hover] [light] [daily] [seen]`: render the panel rows to a PNG and exit.
        let args = CommandLine.arguments
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
            guard let r = result else { fputs("live fetch failed\n", stderr); exit(1) }
            // `seen`: as if the app had watched the budget reset at the start of this month.
            let monthStart = Spend.utc.date(from: Spend.utc.dateComponents([.year, .month], from: Date()))!
            snap = CommandLine.arguments.contains("seen") ? r.confirmingAssumedReset(seen: monthStart) : r
        } else {
            snap = enterprise ? .sampleEnterprise : .sample
        }
        // Live numbers get the real recorded history; samples get a made-up one.
        let light = CommandLine.arguments.contains("light")
        var logs: [UsageWeight]?
        if live, let period = UsageModel.budgetPeriod(snap) { logs = ClaudeCodeLogs.weights(from: period.start, to: Date()) }
        let model = UsageModel(preview: snap, problem: offline ? "Offline" : nil,
                               history: live ? UsageHistory.load() : nil, logWeights: logs)
        writeLabelPreview(model: model, output: output)
        let view = UsageRows(model: model)
            .padding(UsagePanel.padding)
            .frame(width: UsagePanel.width)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, light ? .light : .dark)
            .environment(\.previewHover, CommandLine.arguments.contains("hover") ? 0.4 : nil)
            .environment(\.previewBudgetMode, CommandLine.arguments.contains("daily") ? "daily" : nil)
        // AppKit colours (window background, label colours) follow the drawing appearance.
        NSApplication.shared.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            fputs("render failed\n", stderr); exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: output))
        print("wrote \(output)")
        exit(0)
    }

    /// The menu bar item, enlarged 6x, on a light and a dark menu bar (two stacked strips).
    private static func writeLabelPreview(model: UsageModel, output: String) {
        let label = MenuBarImage.make(rows: model.menuBarRows())
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
