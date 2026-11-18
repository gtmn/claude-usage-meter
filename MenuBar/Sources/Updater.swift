import AppKit
import Foundation

/// "Check for updates" (off by default): once at launch and then daily, asks GitHub for the latest
/// release. When it's newer, the popup offers it; Update installs it the way this copy came:
/// - Homebrew: `brew update` + `brew upgrade` (builds from source, about a minute), then restarts
///   through `brew services` (or opens the new copy).
/// - Downloaded: fetches the release zip, checks it against the release's SHA256SUMS.txt, swaps the
///   app in place and reopens it. A file the app downloads itself isn't quarantined.
/// Dev builds (versions like "0.1.11-3-gabc1234") are told about a release but don't install it.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let enabledKey = "checkForUpdates"

    @Published private(set) var available: UpdateCheck.Release?
    /// What Update is doing, or why it failed.
    @Published private(set) var status: String?
    @Published private(set) var busy = false
    @Published private(set) var failed = false

    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// Only a released version (plain "0.1.11") installs updates; a dev build just hears about them.
    var canInstall: Bool { UpdateCheck.numbers(current) != nil }

    private var timer: Timer?
    private var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    /// For previews: pretend this version is out.
    func preview(available version: String) {
        available = UpdateCheck.Release(version: version); checkResult = "\(version) is out"
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check() }
        }
        timer?.tolerance = 3600
        Task { await check() }
    }

    /// Asks GitHub once (when the setting is on); clears the offer when it's off.
    func check() async {
        guard enabled else { available = nil; checkResult = nil; return }
        guard let release = await Self.fetchLatest() else { return }   // offline etc.: try tomorrow
        available = UpdateCheck.isNewer(release.version, than: current) ? release : nil
    }

    /// The answer to Check now: "Up to date (0.1.12)", "0.1.13 is out" (its row shows above), or why not.
    @Published private(set) var checkResult: String?
    @Published private(set) var checking = false

    /// Check now: one request, whether the setting is on or not (the user asked for it). Leaves
    /// the daily check as it is.
    func checkNow() async {
        guard !checking else { return }
        checking = true; checkResult = nil
        defer { checking = false }
        guard let release = await Self.fetchLatest() else { checkResult = "Couldn't reach GitHub"; return }
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
            // launchd restarts the job itself (with the new copy behind the opt link), even though
            // stopping this process also ends anything it started.
            _ = try? await Self.run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/sh.brew.claude-usage-meter"])
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

    /// Runs a command to the end, output discarded; returns its exit code.
    private static func run(_ tool: String, _ args: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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
