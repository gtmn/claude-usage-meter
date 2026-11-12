import ServiceManagement
import SwiftUI

// MARK: Menu bar label — two stacked mini bars (see MenuBarImage).

struct MenuBarLabel: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        let rows = model.menuBarRows()
        if !rows.isEmpty {
            Image(nsImage: MenuBarImage.make(rows: rows))
        } else {
            Image(systemName: model.error == nil ? "gauge.with.dots.needle.0percent" : "exclamationmark.circle")
        }
    }
}

// MARK: Popover panel

struct UsagePanel: View {
    static let width: CGFloat = 356
    static let padding: CGFloat = 12

    @ObservedObject var model: UsageModel
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Claude usage").font(.system(size: 12, weight: .semibold))
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh now")
                }
            }

            UsageRows(model: model)

            Divider()

            HStack {
                Toggle("Open at login", isOn: $openAtLogin)
                    .toggleStyle(.checkbox)
                    .onChange(of: openAtLogin) { _, on in setOpenAtLogin(on) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .font(.system(size: 11))
            .controlSize(.small)
        }
        .padding(Self.padding)
        .frame(width: Self.width)
        .onAppear { model.refreshIfStale() }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("UsageMeter: login item error: \(error.localizedDescription)")
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// The data part of the panel (no AppKit-backed controls, so it can also be rendered to an image).
struct UsageRows: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if model.snapshot != nil {
                // Re-render every minute so outlooks ("in 40 min") stay current between fetches.
                TimelineView(.periodic(from: .now, by: 60)) { ctx in
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(model.orderedWindows) { w in
                            WindowRow(window: w, severity: model.snapshot?.severity[w.key],
                                      budgetOnly: model.snapshot?.isBudgetOnly ?? false, now: ctx.date)
                        }
                        HistoryChart(model: model, now: ctx.date)
                            .padding(.top, 2)
                    }
                }
                if let pace = model.snapshot?.serverPace {
                    Label("Claude's own estimate: \(describe(pace))", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Loading…").foregroundStyle(.secondary)
            }

            if let s = model.snapshot {
                Text(footer(s))
                    .font(.system(size: 10))
                    .foregroundStyle(model.oauthProblem == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func footer(_ s: UsageSnapshot) -> String {
        let time = HumanTime.clock(s.capturedAt)
        if let problem = model.oauthProblem { return "\(problem) · numbers from \(time)" }
        return "Updated \(time) via Claude Code login"
    }

    private func describe(_ obj: Any) -> String {
        if let s = obj as? String { return s }
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]) else { return "\(obj)" }
        return String(decoding: d, as: UTF8.self)
    }
}

struct WindowRow: View {
    let window: UsageWindow
    let severity: String?
    var budgetOnly = false
    let now: Date

    private var runsOut: Bool { window.projectedLimitAt(now: now) != nil }

    private var tint: Color {
        if window.percent >= 90 || (window.spend?.limitReached ?? false)
            || (severity.map { $0 != "normal" } ?? false) { return .red }
        if runsOut || window.percent >= 70 { return .orange }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title(budgetOnly: budgetOnly)).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(Int(window.percent.rounded()))%")
                    .font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            PaceBar(percent: window.percent, pace: window.expectedPercent(now: now), tint: tint)
                .padding(.vertical, 2)
            if let spend = window.spend {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(spend.used.formatted).font(.system(size: 13, weight: .semibold))
                    Text("used of \(spend.limit.formatted)").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(spend.remaining.formatted) left").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
            Text(window.outlook(now: now))
                .font(.system(size: 11))
                .foregroundStyle(runsOut ? Color.orange : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let reset = window.resetsAt {
                Text(caption(reset)).font(.system(size: 10)).foregroundStyle(.secondary)
                    .help(window.resetIsAssumed
                          ? "Claude's usage data doesn't say when this budget resets, so 00:00 UTC on the 1st is assumed. "
                            + "Set up statusline-snapshot.sh (see README) and use Claude Code once to get the real date."
                          : "")
            }
        }
    }

    private func caption(_ reset: Date) -> String {
        let f = DateFormatter(); f.locale = HumanTime.en; f.dateFormat = "EEE d MMM, HH:mm"
        var s = "Resets \(f.string(from: reset))"
        if window.resetIsAssumed { s += " (assumed)" }
        if let pace = window.expectedPercent(now: now) { s += " · \(Int(pace.rounded()))% of time used" }
        return s
    }
}

/// Usage bar with a tick where usage "should" be if spread evenly over the window.
struct PaceBar: View {
    let percent: Double
    let pace: Double?
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(tint).frame(width: max(5, w * min(percent, 100) / 100))
                if let pace {
                    Rectangle()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 1.5, height: 9)
                        .offset(x: min(max(w * pace / 100 - 0.75, 0), w - 1.5))
                }
            }
        }
        .frame(height: 5)
        .help(pace.map { HumanTime.paceSummary(used: percent, expected: $0) } ?? "")
    }
}
