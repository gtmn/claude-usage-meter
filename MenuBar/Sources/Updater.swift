import AppKit
import Foundation

/// "Check for updates" (off by default): at most once a day, asks GitHub for the latest release.
/// The time of the last answer and the version it named are saved, so restarts don't ask again
/// and still show an offer found earlier; an hourly timer and waking from sleep ask once a day is up. When it's newer, the popup offers it; Update installs it the way this copy came:
/// - Homebrew: `brew update` + `brew upgrade` (builds from source, about a minute), then
///   `brew services restart` (or opens the new copy).
/// - Downloaded: fetches the release zip, checks it against the release's SHA256SUMS.txt, swaps the
///   app in place and reopens it. A file the app downloads itself isn't quarantined.
/// Dev builds (versions like "0.1.11-3-gabc1234") are told about a release but don't install it.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let enabledKey = "checkForUpdates"
    static let lastCheckKey = "updateLastCheck"
    static let latestVersionKey = "updateLatestVersion"

    @Published private(set) var available: UpdateCheck.Release?
    /// What Update is doing, or why it failed.
    @Published private(set) var status: String?
    @Published private(set) var busy = false
    @Published private(set) var failed = false

    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// Only a released version (plain "0.1.11") installs updates; a dev build just hears about them.
    var canInstall: Bool { UpdateCheck.numbers(current) != nil }

    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// For previews: pretend this version is out.
    func preview(available version: String) {
        available = UpdateCheck.Release(version: version); checkResult = "\(version) is out"
    }

    func start() {
        guard timer == nil else { return }
        if enabled, let saved = UserDefaults.standard.string(forKey: Self.latestVersionKey),
           UpdateCheck.isNewer(saved, than: current) {
            available = UpdateCheck.Release(version: saved)
        }
        // A timer doesn't count the time the Mac sleeps, so it only looks every hour whether a day
        // is up; waking looks too.
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.checkIfDue() }
        }
        timer?.tolerance = 300
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await Updater.shared.checkIfDue() }
        }
        Task { await checkIfDue() }
    }

    /// The automatic check: asks GitHub only when the last answer is a day old (or there's none).
    func checkIfDue() async {
        guard enabled else { available = nil; checkResult = nil; return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        guard UpdateCheck.isDue(last: last, now: Date()) else { return }
        await check()
    }

    /// Asks GitHub once (when the setting is on); clears the offer when it's off.
    func check() async {
        guard enabled else { available = nil; checkResult = nil; return }
        guard let release = await Self.fetchLatest() else { return }   // offline etc.: the next hour tries again
        remember(release)
        available = UpdateCheck.isNewer(release.version, than: current) ? release : nil
    }

    /// Saves when GitHub last answered and which version it named.
    private func remember(_ release: UpdateCheck.Release) {
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        UserDefaults.standard.set(release.version, forKey: Self.latestVersionKey)
    }

    /// The answer to Check now: "Up to date (0.1.12)", "0.1.13 is out" (its row shows above), or why not.
    @Published private(set) var checkResult: String?
    @Published private(set) var checking = false

    /// Check now: one request, whether the setting is on or not (the user asked for it). Counts as
    /// the day's check.
    func checkNow() async {
        guard !checking else { return }
        checking = true; checkResult = nil
        defer { checking = false }
        guard let release = await Self.fetchLatest() else { checkResult = "Couldn't reach GitHub"; return }
        remember(release)
        let newer = UpdateCheck.isNewer(release.version, than: current)
        available = newer ? release : nil
        checkResult = !canInstall ? "Latest: \(release.version) (dev build)"
            : newer ? "\(release.version) is out" : "Up to date (\(current))"
    }

    /// The newest version this copy can install: for a Homebrew copy the one in the tap's formula
    /// (what `brew upgrade` would get), otherwise GitHub's latest release.
    nonisolated static func fetchLatest() async -> UpdateCheck.Release? {
        let brew = Install.byHomebrew
        var request = URLRequest(url: brew ? UpdateCheck.formulaURL : UpdateCheck.latestURL, timeoutInterval: 20)
        request.setValue(brew ? "application/vnd.github.raw" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("UsageMeter", forHTTPHeaderField: "User-Agent")   // GitHub asks for one
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return brew ? UpdateCheck.release(fromFormula: String(decoding: data, as: UTF8.self))
            : UpdateCheck.release(fromLatest: data)
    }

    func install() {
        guard let release = available, canInstall, !busy else { return }
        busy = true; failed = false
        Task {
            do {
                if Install.byHomebrew { try await brewUpgrade(to: release) } else { try await replaceApp(with: release) }
            } catch {
                AppLog.write("update to \(release.version) failed: \(error.localizedDescription)")
                status = error.localizedDescription; failed = true; busy = false
            }
        }
    }

    // MARK: Homebrew

    private static let brewOpt = "/opt/claude-usage-meter/UsageMeter.app"

    private func brewUpgrade(to release: UpdateCheck.Release) async throws {
        guard let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile)
        else { throw UpdateFailure("Homebrew not found. Run brew upgrade claude-usage-meter in Terminal.") }
        status = "Building with Homebrew (about a minute)…"
        let code = try await Self.run("/bin/sh", ["-c", "\"$0\" update --quiet && \"$0\" upgrade gtmn/tap/claude-usage-meter", brew])
        AppLog.write("update: brew upgrade to \(release.version) exited with \(code)")
        guard code == 0 else { throw UpdateFailure("Homebrew couldn't upgrade (exit \(code)). Try brew upgrade claude-usage-meter in Terminal.") }
        let prefix = URL(fileURLWithPath: brew).deletingLastPathComponent().deletingLastPathComponent().path
        let installed = Self.version(ofApp: URL(fileURLWithPath: prefix + Self.brewOpt)) ?? ""
        guard UpdateCheck.isNewer(installed, than: current) else {
            throw UpdateFailure("Homebrew doesn't have \(release.version) yet. Try again later.")
        }
        status = "Restarting…"
        if Install.byBrewServices {
            // `brew services restart` unloads and reloads the job. A plain restart (`launchctl kickstart`)
            // won't do: launchd keeps the code signature it recorded when the job was loaded, and an
            // ad-hoc signed rebuild no longer matches it, so the new copy is refused
            // (OS_REASON_CODESIGNING). Unloading ends everything the job started, so the restart
            // runs in a session of its own; this copy just waits to be stopped.
            let log = AppLog.url.path
            try Self.detach("/bin/sh", ["-c", "\"$0\" services restart claude-usage-meter >/dev/null 2>&1; "
                + "echo \"$(date +%Y-%m-%dT%H:%M:%S%z) update: brew services restart exited with $?\" >> \"$1\"", brew, log])
            try await Task.sleep(for: .seconds(60))
            throw UpdateFailure("\(installed) is installed but didn't start. Run brew services restart claude-usage-meter in Terminal.")
        } else {
            reopen(prefix + Self.brewOpt)
        }
    }

    // MARK: Downloaded copy

    private func replaceApp(with release: UpdateCheck.Release) async throws {
        let app = Bundle.main.bundleURL
        let folder = app.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            throw UpdateFailure("Can't write to \(folder.path). Download it from the release page.")
        }
        status = "Downloading \(release.version)…"
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: app, create: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let zip = work.appendingPathComponent(release.appZipName)
        let (downloaded, zipResponse) = try await URLSession.shared.download(from: release.appZip)
        guard (zipResponse as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure("The download failed.") }
        try FileManager.default.moveItem(at: downloaded, to: zip)
        let (sumsData, sumsResponse) = try await URLSession.shared.data(from: release.sums)
        guard (sumsResponse as? HTTPURLResponse)?.statusCode == 200,
              let expected = UpdateCheck.checksum(for: release.appZipName, in: String(decoding: sumsData, as: UTF8.self)),
              try UpdateCheck.sha256(of: zip) == expected
        else { throw UpdateFailure("The download didn't match its checksum, so it wasn't installed.") }

        status = "Installing…"
        let unpacked = work.appendingPathComponent("unpacked")
        guard try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0 else {
            throw UpdateFailure("Couldn't unpack the download.")
        }
        let new = unpacked.appendingPathComponent("UsageMeter.app")
        guard Self.version(ofApp: new) == release.version else {
            throw UpdateFailure("The download isn't version \(release.version).")
        }
        _ = try FileManager.default.replaceItemAt(app, withItemAt: new)
        AppLog.write("update: replaced \(app.path) with \(release.version)")
        status = "Restarting…"
        reopen(app.path)
    }

    // MARK: Helpers

    /// An app's version straight from its Info.plist (`Bundle` caches by path, so it could
    /// still report the copy that was there before).
    private static func version(ofApp app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    /// `UsageMeter --check-update`: asks GitHub once, prints the answer and exits (setting or not).
    nonisolated static func checkFromCommandLine() -> Never {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var latest: UpdateCheck.Release?
        Task.detached { latest = await fetchLatest(); sem.signal() }
        sem.wait()
        let source = Install.byHomebrew ? "the tap's formula" : "GitHub's latest release"
        guard let latest else { print("this copy: \(current); couldn't reach GitHub"); exit(1) }
        let newer = UpdateCheck.isNewer(latest.version, than: current)
        print("this copy: \(current); latest in \(source): \(latest.version)\(newer ? " (newer)" : "")")
        print(Install.byHomebrew ? "installed by Homebrew" : "installed by hand: \(Bundle.main.bundleURL.path)")
        exit(0)
    }

    /// Quits and opens `path` a moment later, once this copy is gone.
    private func reopen(_ path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// Starts a command in a session of its own and doesn't wait for it, so it outlives this copy
    /// and its launchd job.
    private static func detach(_ tool: String, _ args: [String]) throws {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.path
        env["XPC_SERVICE_NAME"] = nil   // not part of the job any more
        let argv = ([tool] + args).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, tool, nil, &attr, argv, envp)
        guard rc == 0 else { throw UpdateFailure("Couldn't restart (error \(rc)). Run brew services restart claude-usage-meter in Terminal.") }
    }

    private static let path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Runs a command to the end, output discarded; returns its exit code.
    private static func run(_ tool: String, _ args: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = Self.path
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

struct UpdateFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
