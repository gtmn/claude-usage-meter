import AppKit
import Foundation
import Network

extension UsageSnapshot {
    /// Fixed numbers for layout checks (`--sample`, `--render-preview`); needs no Keychain access.
    static var sample: UsageSnapshot {
        let now = Date()
        return UsageSnapshot(source: .oauth, capturedAt: now, windows: [
            UsageWindow(key: "five_hour", percent: 20, resetsAt: now.addingTimeInterval(2 * 3600)),
            UsageWindow(key: "seven_day", percent: 60, resetsAt: now.addingTimeInterval(3 * 86400)),
        ])
    }
}

/// Polls usage every 5 minutes (and on wake / when the panel opens).
/// Keeps the last good snapshot when a fetch fails, so the bar never goes blank.
@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot?
    /// Why the OAuth source didn't work (set when we fell back to the status-line file or failed).
    @Published private(set) var oauthProblem: String?
    /// Set when no source produced data on the last attempt.
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    @Published private(set) var lastAttempt: Date?

    static let interval: TimeInterval = 5 * 60
    private let reader = UsageReader()
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let pathMonitor = NWPathMonitor()
    private var networkWasDown = false

    init(preview: UsageSnapshot? = nil, problem: String? = nil) {
        if let preview { snapshot = preview; oauthProblem = problem; return }
        refresh()
        // Fetch as soon as the network returns (a fetch right after wake often finds none yet).
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let up = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(up: up) }
        }
        pathMonitor.start(queue: .global(qos: .utility))
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func networkChanged(up: Bool) {
        if up && networkWasDown { refresh() }
        networkWasDown = !up
    }

    func refreshIfStale(olderThan age: TimeInterval = 60) {
        if let last = lastAttempt, Date().timeIntervalSince(last) < age { return }
        refresh()
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let reader = self.reader
        Task {
            // Keychain access can block on a permission prompt, so keep it off the main actor.
            let (snap, oauthWhy) = await Task.detached { () -> (UsageSnapshot?, String?) in
                do {
                    return (try await reader.fetchOAuth(), nil)
                } catch {
                    let why = UsageError.shortMessage(for: error)
                    return ((try? reader.readSnapshot(maxAge: reader.maxSnapshotAge)), why)
                }
            }.value

            lastAttempt = Date()
            oauthProblem = oauthWhy
            if let snap {
                snapshot = snap
                error = nil
            } else {
                error = oauthWhy ?? "No usage data"
            }
            isLoading = false
        }
    }

    // MARK: Derived

    /// Windows in display order: session, week, then model-specific weeks.
    var orderedWindows: [UsageWindow] {
        guard let s = snapshot else { return [] }
        let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
        return s.windows.sorted {
            (order.firstIndex(of: $0.key) ?? 99, $0.key) < (order.firstIndex(of: $1.key) ?? 99, $1.key)
        }
    }

    /// The rows shown in the menu bar item; warns when nearly full or projected to run out.
    func menuBarRows(now: Date = Date()) -> [MenuBarImage.Row] {
        guard let s = snapshot else { return [] }
        return [("five_hour", "5h"), ("seven_day", "7d")].compactMap { key, label in
            s.window(key).map {
                MenuBarImage.Row(label: label, percent: $0.percent,
                                 warn: $0.percent >= 90 || $0.projectedLimitAt(now: now) != nil)
            }
        }
    }
}

extension UsageWindow: Identifiable {
    public var id: String { key }

    var title: String {
        switch key {
        case "five_hour":        return "Session · 5 h"
        case "seven_day":        return "Week · all models"
        case "seven_day_opus":   return "Week · Opus"
        case "seven_day_sonnet": return "Week · Sonnet"
        default: return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
