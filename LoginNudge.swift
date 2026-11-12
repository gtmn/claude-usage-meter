// LoginNudge.swift
// Claude Code's login lasts about 8 hours and only Claude Code renews it. When it has expired
// because no Claude Code ran for a while, the app asks the Claude Code command-line tool to check
// its own login (`claude auth status`: no model request, nothing billed), which may make it renew
// the login. The meter itself still never renews, writes or logs the login. The tool's output
// (account details) is discarded.

import Foundation

public enum LoginNudge {
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
            switch self {
            case .noCLI: return "no claude command found"
            case .couldNotRun: return "claude couldn't be started"
            case .timedOut: return "claude auth status timed out"
            case .exited(let code): return "claude auth status exited with \(code)"
            }
        }
    }

    /// Runs `claude auth status` and waits for it (at most `timeout`). Blocks: call off the main thread.
    public static func run(timeout: TimeInterval = 30) -> Outcome {
        guard let path = claudePath() else { return .noCLI }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["auth", "status"]
        // Apps get a minimal PATH; give the tool the usual one (it may look for git, node, …).
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
}
