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
    @AppStorage(MenuBarImage.Options.Key.palette) private var palette = MenuBarImage.Palette.colour.rawValue
    @AppStorage(MenuBarImage.Options.Key.budgetAs) private var budgetAs = MenuBarImage.BudgetAs.percent.rawValue
    @AppStorage(MenuBarImage.Options.Key.extra) private var showExtra = false
    @AppStorage(MenuBarImage.Options.Key.limits) private var limits = MenuBarImage.Limits.both.rawValue
    @AppStorage(MenuBarImage.Options.Key.projection) private var projection = MenuBarImage.Projection.off.rawValue

    var body: some View {
        // On a budget there's no Labels setting and no "$" label: a single bar needs none, and the amount ("$412") has its own "$".
        let options = MenuBarImage.Options(labels: showLabels && model.snapshot?.isBudgetOnly != true, percent: showPercent, pace: showPace,
                                           ahead: showAhead, aheadAs: MenuBarImage.AheadAs(saved: aheadAs),
                                           palette: MenuBarImage.Palette(saved: palette),
                                           budgetAs: MenuBarImage.BudgetAs(saved: budgetAs), extra: showExtra,
                                           limits: MenuBarImage.Limits(saved: limits),
                                           projection: MenuBarImage.Projection(saved: projection))
        Group {
            if let image = MenuBarImage.item(style: MenuBarImage.Style(saved: style), rows: model.menuBarRows(),
                                             rings: model.compactRings(), extra: model.extraRow(), options: options) {
                Image(nsImage: image)
            } else {
                Image(systemName: model.error == nil ? "gauge.with.dots.needle.0percent" : "exclamationmark.circle")
            }
        }
        .onAppear { Updater.shared.start() }
    }
}

/// The popup's menu bar settings: style, palette and what the item shows. Its own view, so the
/// preview renderer can draw it alone (`settings`).
struct MenuBarSettings: View {
    @ObservedObject var model: UsageModel
    @AppStorage(MenuBarImage.Style.key) private var menuBarStyle = MenuBarImage.Style.bars.rawValue
    @AppStorage(MenuBarImage.Options.Key.labels) private var showLabels = true
    @AppStorage(MenuBarImage.Options.Key.percent) private var showPercent = true
    @AppStorage(MenuBarImage.Options.Key.pace) private var showPace = true
    @AppStorage(MenuBarImage.Options.Key.ahead) private var showAhead = true
    @AppStorage(MenuBarImage.Options.Key.aheadAs) private var aheadAs = MenuBarImage.AheadAs.points.rawValue
    @AppStorage(MenuBarImage.Options.Key.palette) private var palette = MenuBarImage.Palette.colour.rawValue
    @AppStorage(MenuBarImage.Options.Key.budgetAs) private var budgetAs = MenuBarImage.BudgetAs.percent.rawValue
    @AppStorage(MenuBarImage.Options.Key.extra) private var showExtra = false
    @AppStorage(MenuBarImage.Options.Key.limits) private var limits = MenuBarImage.Limits.both.rawValue
    @AppStorage(MenuBarImage.Options.Key.projection) private var projection = MenuBarImage.Projection.off.rawValue

    var body: some View {
        let snapshot = model.snapshot
        let budget = snapshot?.isBudgetOnly == true
        VStack(alignment: .leading, spacing: 5) {
            Text("Menu bar item").font(.system(size: 11, weight: .semibold))
            // Combinations that would leave the menu bar item empty (nothing to click) are greyed out.
            let style = MenuBarImage.Style(saved: menuBarStyle)
            let projectionOn = MenuBarImage.Projection(saved: projection) == .on
            let empty = "Nothing would show in the menu bar: turn on Number or Projection first"
            row("Indicator") {
                ModeSwitch(mode: Binding(get: { style.rawValue }, set: { menuBarStyle = $0 }),
                           options: MenuBarImage.Style.allCases.map { ($0.rawValue, $0.name(single: budget)) },
                           disabled: !showPercent && !projectionOn ? ["dots": empty, "text": empty] : [:])
                    .help("Bars: the session and weekly bars. Circle: rings, the week outside and the session inside "
                          + "(one budget ring on Enterprise). Dots: the numbers, each after a dot in its pace colour. "
                          + "Gauge: a gauge in the pace colour, its needle at the highest use. Network: a hub with linked nodes in the pace colour. "
                          + "Off: the numbers alone.")
            }
            // Text has nothing to colour.
            if style != .text {
                row("Colours") {
                    ModeSwitch(mode: Binding(get: { MenuBarImage.Palette(saved: palette).rawValue }, set: { palette = $0 }),
                               options: MenuBarImage.Palette.allCases.map { ($0.rawValue, $0.name) })
                        .help("Colour: green on or under pace, yellow ahead, orange 15+ points ahead. "
                              + "Alerts: in the text colour while on or under pace, yellow or orange once ahead or nearly full. "
                              + "Mono: always in the menu bar's text colour, like the numbers.")
                }
            }
            if snapshot?.window("five_hour") != nil && snapshot?.window("seven_day") != nil {
                row("Limits", help: "Which limits the menu bar shows: the 5 h session and the week, or one of them. "
                    + "The popup and the graph always show both.") {
                    ModeSwitch(mode: Binding(get: { MenuBarImage.Limits(saved: limits).rawValue }, set: { limits = $0 }),
                               options: MenuBarImage.Limits.allCases.map { ($0.rawValue, $0.name) })
                }
            }
            row("Number", help: budget
                ? "%: the share of the budget used (21%). Amount: the money spent so far, in whole units ($306). Off: the bar alone."
                : "How much of each limit is used (60%). Off: the bars alone.") {
                ModeSwitch(mode: Binding(get: { !showPercent ? "off" : budget ? MenuBarImage.BudgetAs(saved: budgetAs).rawValue : "percent" },
                                         set: { showPercent = $0 != "off"; if budget && $0 != "off" { budgetAs = $0 } }),
                           options: (budget ? MenuBarImage.BudgetAs.allCases.map { ($0.rawValue, $0.name) } : [("percent", "%")])
                               + [("off", "Off")],
                           disabled: style.needsText && !projectionOn ? ["off": "Nothing would show in the menu bar: turn on Projection first"] : [:])
            }
            row("Projection", help: "Where each limit is heading at its reset, at the pace so far: →35%, or →140% when it "
                + "runs out first. On: after the number, on a second line for a single limit. With Number off, in the number's place, "
                + "and the number alone until there's a projection (early in a window, or at 100%).") {
                ModeSwitch(mode: Binding(get: { MenuBarImage.Projection(saved: projection).rawValue }, set: { projection = $0 }),
                           options: MenuBarImage.Projection.allCases.map { ($0.rawValue, $0.name) },
                           disabled: style.needsText && !showPercent ? ["off": "Nothing would show in the menu bar: turn on Number first"] : [:])
            }
            if snapshot?.extraUsage != nil {
                row("Extra usage", help: "Your extra usage as its own $ item next to the 5h and 7d one: as the share of its "
                    + "limit used (25%) or the money spent so far ($12).") {
                    ModeSwitch(mode: Binding(get: { showExtra ? MenuBarImage.BudgetAs(saved: budgetAs).rawValue : "off" },
                                             set: { showExtra = $0 != "off"; if $0 != "off" { budgetAs = $0 } }),
                               options: [("off", "Off")] + MenuBarImage.BudgetAs.allCases.map { ($0.rawValue, $0.name) })
                }
            }
            row("When ahead", help: "Once a limit is 15+ points ahead of pace (orange). +N: percentage points ahead of pace "
                + "(% used minus % expected by now, e.g. 52% − 27% = +25). time left: until it runs out at this pace (1.5d left). "
                + "early: how long before the reset it runs out (3d early). Half days, whole hours, and minutes only for the 5 h session.") {
                ModeSwitch(mode: Binding(get: { showAhead ? MenuBarImage.AheadAs(saved: aheadAs).rawValue : "off" },
                                         set: { showAhead = $0 != "off"; if $0 != "off" { aheadAs = $0 } }),
                           options: [("off", "Off")] + MenuBarImage.AheadAs.allCases.map { ($0.rawValue, $0.name) })
            }
            HStack(spacing: 12) {
                if !budget {
                    Toggle("Labels", isOn: $showLabels).help("“5h” and “7d” (and “$” for extra usage) beside the bars or numbers")
                }
                if style == .bars || style == .compact {
                    Toggle("Pace tick", isOn: $showPace).help("A tick where usage would be by now if spread evenly over the window")
                }
            }
            .toggleStyle(.checkbox).controlSize(.small).font(.system(size: 11))
            .padding(.top, 1)
        }
    }

    private static let nameWidth: CGFloat = 74

    /// One setting: its name in a fixed column, so the names line up, and its controls beside it.
    private func row<Control: View>(_ name: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.system(size: 11)).frame(width: Self.nameWidth, alignment: .leading)
            control()
            Spacer(minLength: 0)
        }
    }

    private func row<Control: View>(_ name: String, help: String, @ViewBuilder control: () -> Control) -> some View {
        row(name, control: control).help(help)
    }
}

// MARK: Popover panel

struct UsagePanel: View {
    static let width: CGFloat = 356
    static let padding: CGFloat = 12

    @ObservedObject var model: UsageModel
    @ViewState private var openAtLogin = SMAppService.mainApp.status == .enabled
    /// The menu bar settings, shown or hidden with the gear button (closed until opened; remembered).
    @AppStorage(UsagePanel.settingsShownKey) private var settingsShown = false
    static let settingsShownKey = "settingsShown"
    @AppStorage(Updater.enabledKey) private var checkForUpdates = false
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Claude usage").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { settingsShown.toggle() } label: { Image(systemName: settingsShown ? "gearshape.fill" : "gearshape") }
                    .buttonStyle(.borderless)
                    .help(settingsShown ? "Hide the menu bar settings" : "Menu bar settings")
                if model.isLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh now")
                }
            }

            if let release = updater.available {
                UpdateRow(updater: updater, release: release)
            }

            UsageRows(model: model)

            if settingsShown {
                Divider()
                MenuBarSettings(model: model)
                Divider()
                appRow
            }
        }
        // ⌘Q quits while the popup is open, also with the settings (and their Quit button) closed.
        .background { Button("") { NSApp.terminate(nil) }.keyboardShortcut("q").hidden() }
        .padding(Self.padding)
        .frame(width: Self.width)
        .onAppear { model.refreshIfStale() }
    }

    /// The settings' last row: open at login (or how it's opened) and Quit.
    private var appRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("Check for updates", isOn: $checkForUpdates)
                    .toggleStyle(.checkbox)
                    .onChange(of: checkForUpdates) { _, _ in Task { await updater.check() } }
                    .help("Once a day, ask GitHub for the latest version (nothing about you or your usage is sent). "
                          + "Off: the app talks only to api.anthropic.com.")
                Button("Check now") { Task { await updater.checkNow() } }
                    .disabled(updater.checking)
                    .help("Ask GitHub once for the latest version, now (also with the daily check off)")
                if updater.checking {
                    ProgressView().controlSize(.mini)
                } else if let result = updater.checkResult {
                    Text(result).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
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
                Button("Quit") { NSApp.terminate(nil) }.help("Quit Usage Meter (⌘Q)")
            }
        }
        .font(.system(size: 11))
        .controlSize(.small)
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
                                      budgetOnly: model.snapshot?.isBudgetOnly ?? false, now: ctx.date,
                                      asOf: model.showingSaved ? model.snapshot?.capturedAt : nil)
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
    /// When saved numbers were fetched: the outlook projects from then (see `UsageWindow.outlook`).
    var asOf: Date? = nil

    private var runsOut: Bool { window.projectedLimitAt(now: min(asOf ?? now, now)) != nil }

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
            Text(window.outlook(now: now, asOf: asOf))
                .font(.system(size: 11))
                .foregroundStyle(runsOut ? Color.orange : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let reset = window.resetsAt {
                Text(caption(reset)).font(.system(size: 10)).foregroundStyle(.secondary)
                    .helpIfAny(resetHelp)
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
        .helpIfAny(pace.map { HumanTime.paceSummary(used: percent, expected: $0) } ?? "")
    }
}

extension View {
    /// A hover tooltip only when there's something to say: `.help("")` shows an empty box on macOS
    /// (it did on the session and week rows, whose reset needs no explanation).
    @ViewBuilder func helpIfAny(_ text: String) -> some View {
        if text.isEmpty { self } else { help(text) }
    }
}

/// SwiftUI's `@State` property wrapper, spelled so the compiler doesn't pick the `@State` macro.
/// The macOS 27 SDK declares `@State` as a macro whose plugin ships only with Xcode, so with just
/// the Command Line Tools (as Homebrew builds) `@State` fails with "plugin for module
/// 'SwiftUIMacros' not found". The typealias always means the property wrapper.
typealias ViewState<Value> = SwiftUI.State<Value>

/// How this copy was installed. A Homebrew copy hides "Open at login": that switch would remember
/// this version's Cellar folder, which goes away on the next upgrade; `brew services` does it instead.
/// A newer release, under the popup's title: what's new, and Update when this copy can install it.
struct UpdateRow: View {
    @ObservedObject var updater: Updater
    let release: UpdateCheck.Release

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                Text("Version \(release.version) available")
                Link("What's new", destination: release.page)
                Spacer(minLength: 0)
                if updater.busy {
                    ProgressView().controlSize(.mini)
                } else if updater.canInstall {
                    Button("Update") { updater.install() }
                        .help(Install.byHomebrew ? "brew upgrade claude-usage-meter, then restart"
                              : "Download, check and install it, then restart")
                }
            }
            if let status = updater.status {
                Text(status).foregroundStyle(updater.failed ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !updater.canInstall {
                Text("A dev build (\(updater.current)) doesn't update itself.").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .controlSize(.small)
    }
}

enum Install {
    static let byHomebrew = Bundle.main.bundleURL.resolvingSymlinksInPath().path.contains("/Cellar/")
    /// launchd names the job in XPC_SERVICE_NAME; `brew services` jobs are "sh.brew.<formula>".
    static let byBrewServices = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]?.hasPrefix("sh.brew.") ?? false
    static var loginNote: String? { byBrewServices ? "Opens at login (brew)" : nil }
}
