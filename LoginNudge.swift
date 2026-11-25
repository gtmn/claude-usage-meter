// LoginNudge.swift
// Claude Code's login lasts about 8 hours and only Claude Code renews it (the desktop app's Code
// tab doesn't seem to renew this saved login). When it has expired, the app runs
// `claude mcp list`: it checks the MCP connections with the login, which makes Claude Code renew
// the login itself. No model request, nothing billed. (`claude auth status` only reports the
// expiry.) The meter itself still never renews, writes or logs the login. The tool's output
// (server names and addresses) is discarded.

import Foundation

public enum LoginNudge {
    /// The command. It briefly starts the configured MCP servers to check them, so it runs in an
    /// empty folder: no project's .mcp.json servers get involved.
    static let arguments = ["mcp", "list"]

    /// Where the Claude Code installers put the command (Homebrew, npm, the native installer).
    public static var candidates: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                "\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude"]
    }

    public static func claudePath() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public enum Outcome: Equatable, CustomStringConvertible {
        case noCLI
        case couldNotRun
        case timedOut
        case exited(Int32)

        public var description: String {
            let command = "claude " + LoginNudge.arguments.joined(separator: " ")
            switch self {
            case .noCLI: return "no claude command found"
            case .couldNotRun: return "claude couldn't be started"
            case .timedOut: return "\(command) timed out"
            case .exited(let code): return "\(command) exited with \(code)"
            }
        }
    }

    /// Runs the command and waits for it (at most `timeout`). Blocks: call off the main thread.
    public static func run(timeout: TimeInterval = 60) -> Outcome {
        guard let path = claudePath() else { return .noCLI }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("UsageMeter-login-check")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        p.currentDirectoryURL = folder
        // Apps get a minimal PATH; give the tool the usual one (MCP servers may need node, npx, …).
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        // Without USER the tool can't find its Keychain item and reports "not logged in".
        if env["USER"] == nil { env["USER"] = NSUserName() }
        if env["LOGNAME"] == nil { env["LOGNAME"] = NSUserName() }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return .couldNotRun }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return .timedOut }
        return .exited(p.terminationStatus)
    }

    /// True for the errors that mean Claude Code's login has run out.
    public static func isExpiredLogin(_ error: Error) -> Bool {
        switch error as? UsageError {
        case .tokenExpired, .http(401): return true
        default: return false
        }
    }

    // MARK: Sign in again (docs/SIGN-IN-AGAIN.md)

    /// Whether the popup offers Sign in…: the login can't come back without signing in again.
    /// - the nudge ran (`nudge`: it finished or timed out) and the login wasn't renewed: the refresh
    ///   token has run out or was revoked. One failed nudge may be a network blip, but the button
    ///   only opens a sign-in when clicked, and nudges go on every 30 minutes;
    /// - the login was renewed and the server still refused it (`renewed`): revoked;
    /// - there is no Keychain item: never signed in, or signed out.
    /// Never without a `claude` command (`hasCLI`): there would be nothing to run.
    public static func signInNeeded(after error: Error, nudge: Outcome?, renewed: Bool, hasCLI: Bool) -> Bool {
        guard hasCLI else { return false }
        if case .noCredentials? = error as? UsageError { return true }
        if renewed { return isExpiredLogin(error) }
        switch nudge {
        case .exited?, .timedOut?: return isExpiredLogin(error)
        default: return false
        }
    }

    /// The script the Sign in… button opens in Terminal: Claude Code's own sign-in and nothing else,
    /// so the app never sees the sign-in or its output.
    public static func signInScript(claudePath: String) -> String {
        "#!/bin/zsh\n"
            + "# Written by Usage Meter for its Sign in… button: Claude Code's own sign-in. Safe to delete.\n"
            + "exec \(shellQuoted(claudePath)) auth login\n"
    }

    /// `s` in single quotes for zsh (a quote inside becomes '\'').
    public static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// A small log of the app's own, in ~/Library/Logs/UsageMeter.log (Console.app shows it too):
/// times and outcomes only, never the login or usage data. The app's NSLog lines didn't show up
/// in `log show`, so there was no telling whether the login check ran.
public enum AppLog {
    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/UsageMeter.log")
    }
    /// Above this the oldest half is dropped.
    static let maxBytes = 200_000

    public static func write(_ message: String, to url: URL = url, now: Date = Date()) {
        let f = ISO8601DateFormatter(); f.timeZone = .current
        let line = Data("\(f.string(from: now)) \(message)\n".utf8)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if var data = try? Data(contentsOf: url) {
            if data.count > maxBytes, let cut = data[(data.count / 2)...].firstIndex(of: 0x0A) {
                data = data[(cut + 1)...]
            }
            data.append(line)
            try? data.write(to: url, options: .atomic)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }
}
