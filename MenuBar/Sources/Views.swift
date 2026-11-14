import ServiceManagement
import SwiftUI

// MARK: Menu bar label — two stacked mini bars (see MenuBarImage).

struct MenuBarLabel: View {
    @ObservedObject var model: UsageModel
    @AppStorage(MenuBarImage.Style.key) private var style = MenuBarImage.Style.bars.rawValue
    @AppStorage(MenuBarImage.Options.Key.labels) private var showLabels = true
    @AppStorage(MenuBarImage.Options.Key.percent) private var showPercent = true
    @AppStorage(MenuBarImage.Options.Key.pace) private var showPace = true
    @AppStorage(MenuBarImage.Options.Key.ahead) private var showAhead = true
    @AppStorage(MenuBarImage.Options.Key.aheadAs) private var aheadAs = MenuBarImage.AheadAs.points.rawValue

    var body: some View {
        let rows = model.menuBarRows()
        let chosen = MenuBarImage.Style(saved: style)
        let options = MenuBarImage.Options(labels: showLabels, percent: showPercent, pace: showPace,
                                           ahead: showAhead, aheadAs: MenuBarImage.AheadAs(saved: aheadAs))
        let rings = model.compactRings()
        if chosen == .compact, !rings.isEmpty {
            Image(nsImage: MenuBarImage.makeCompact(rings: rings, options: options))
        } else if !rows.isEmpty {
            Image(nsImage: MenuBarImage.make(rows: rows, options: options))
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
    @AppStorage(MenuBarImage.Style.key) private var menuBarStyle = MenuBarImage.Style.bars.rawValue
    @AppStorage(MenuBarImage.Options.Key.labels) private var showLabels = true
    @AppStorage(MenuBarImage.Options.Key.percent) private var showPercent = true
    @AppStorage(MenuBarImage.Options.Key.pace) private var showPace = true
    @AppStorage(MenuBarImage.Options.Key.ahead) private var showAhead = true
    @AppStorage(MenuBarImage.Options.Key.aheadAs) private var aheadAs = MenuBarImage.AheadAs.points.rawValue
    @ViewState private var openAtLogin = SMAppService.mainApp.status == .enabled

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

            HStack(spacing: 6) {
                Text("Menu bar").font(.system(size: 11))
                ModeSwitch(mode: Binding(get: { MenuBarImage.Style(saved: menuBarStyle).rawValue },
                                         set: { menuBarStyle = $0 }),
                           options: MenuBarImage.Style.allCases.map { ($0.rawValue, $0.name) })
                    .help("Bars: the session and weekly bars. Compact: rings, the week outside and the session inside "
                          + "(one budget ring on Enterprise). Both: green on or under pace, yellow ahead, "
                          + "orange 15+ points ahead.")
                Spacer()
            }
            HStack(spacing: 10) {
                Toggle("Labels", isOn: $showLabels).help("“5h” and “7d” (or “$”) beside the bars or numbers")
                Toggle("Percent", isOn: $showPercent).help("How much of each limit is used")
                Toggle("Pace tick", isOn: $showPace).help("A tick where usage would be by now if spread evenly over the window")
                Spacer(minLength: 0)
            }
            .toggleStyle(.checkbox).controlSize(.small).font(.system(size: 11))
            HStack(spacing: 6) {
                Toggle("When well ahead, show", isOn: $showAhead)
                    .toggleStyle(.checkbox).controlSize(.small).font(.system(size: 11))
                    .help("Once a limit is 15+ points ahead of pace (orange): how far ahead")
                ModeSwitch(mode: Binding(get: { MenuBarImage.AheadAs(saved: aheadAs).rawValue }, set: { aheadAs = $0 }),
                           options: MenuBarImage.AheadAs.allCases.map { ($0.rawValue, $0.name) })
                    .help("+N: percentage points ahead of pace (% used minus % expected by now, e.g. 52% − 27% = +25). time left: until it runs out at this pace (1.5d left). "
                          + "early: how long before the reset it runs out (3d early). Half days, whole hours, and minutes only for the 5 h session.")
                    .disabled(!showAhead).opacity(showAhead ? 1 : 0.5)
                Spacer(minLength: 0)
            }

            HStack {
                if let note = Install.loginNote {
                    Text(note).foregroundStyle(.secondary)
                } else if !Install.byHomebrew {
                    Toggle("Open at login", isOn: $openAtLogin)
                        .toggleStyle(.checkbox)
                        .onChange(of: openAtLogin) { _, on in setOpenAtLogin(on) }
                }
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
            if model.showingSaved, let s = model.snapshot {
                // Saved numbers (rate-limited, offline, login expired, or still fetching at launch):
                // say so up front, with how old they are and why.
                Label("Saved numbers from \(stamp(s.capturedAt)) · \(model.oauthProblem ?? model.error ?? "updating…")",
                      systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("The latest numbers couldn't be fetched, so these are the last ones the app got. "
                          + "Limits that have reset since are left out. It keeps retrying every 5 minutes.")
            }
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

            if let s = model.snapshot, !model.showingSaved {
                Text(footer(s))
                    .font(.system(size: 10))
                    .foregroundStyle(model.oauthProblem == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "01:36" today, "Fri 01:36" before (numbers kept from an earlier run).
    private func stamp(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return HumanTime.clock(d) }
        let f = DateFormatter(); f.locale = HumanTime.en; f.dateFormat = "EEE HH:mm"; return f.string(from: d)
    }

    private func footer(_ s: UsageSnapshot) -> String {
        let time = stamp(s.capturedAt)
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

    /// The same pace colour as the menu bar: green on or under pace, yellow ahead, orange well
    /// ahead or nearly full, grey early in the window.
    private var tint: Color {
        let state = MenuBarImage.paceState(MenuBarImage.Row(window, label: "", severity: severity, now: now))
        return state == .unknown ? Color.secondary : Color(nsColor: MenuBarImage.color(state))
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
                    .help(resetHelp)
            }
        }
    }

    private var resetHelp: String {
        if window.resetIsAssumed {
            return "Claude's usage data doesn't say when this budget resets, so 00:00 UTC on the 1st is assumed "
                + "until the app sees a reset happen then. Or set up statusline-snapshot.sh (see README) "
                + "and use Claude Code in Terminal once to get the real date."
        }
        if let seen = window.resetSeen {
            let f = DateFormatter(); f.locale = HumanTime.en; f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "d MMM"
            return "Claude's usage data doesn't say when this budget resets. The app saw it reset at "
                + "00:00 UTC on \(f.string(from: seen)), so the next reset is expected at the same time."
        }
        return ""
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

/// SwiftUI's `@State` property wrapper, spelled so the compiler doesn't pick the `@State` macro.
/// The macOS 27 SDK declares `@State` as a macro whose plugin ships only with Xcode, so with just
/// the Command Line Tools (as Homebrew builds) `@State` fails with "plugin for module
/// 'SwiftUIMacros' not found". The typealias always means the property wrapper.
typealias ViewState<Value> = SwiftUI.State<Value>

/// How this copy was installed. A Homebrew copy hides "Open at login": that switch would remember
/// this version's Cellar folder, which goes away on the next upgrade; `brew services` does it instead.
enum Install {
    static let byHomebrew = Bundle.main.bundleURL.resolvingSymlinksInPath().path.contains("/Cellar/")
    /// launchd names the job in XPC_SERVICE_NAME; `brew services` jobs are "sh.brew.<formula>".
    static let byBrewServices = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]?.hasPrefix("sh.brew.") ?? false
    static var loginNote: String? { byBrewServices ? "Opens at login (brew services)" : nil }
}
