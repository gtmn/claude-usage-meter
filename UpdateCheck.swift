import CryptoKit
import Foundation

/// The update check's plain parts, kept apart from the app so the tests can reach them: which
/// release is newest, whether it's newer than this copy, where its files are, and whether a
/// download matches its checksum. Only used when the user turns on "Check for updates".
public enum UpdateCheck {
    public static let repo = "gtmn/claude-usage-meter"
    /// GitHub's public "latest release" (drafts and pre-releases excluded). No login, no data sent.
    public static let latestURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    /// The Homebrew formula in the tap, as plain text (ask with `Accept: application/vnd.github.raw`).
    /// A Homebrew copy checks this instead of the releases, so it only hears about a version
    /// `brew upgrade` can already install: the release goes out minutes before the tap is bumped.
    public static let formulaURL =
        URL(string: "https://api.github.com/repos/gtmn/homebrew-tap/contents/Formula/claude-usage-meter.rb")!

    /// A release's version and its files, named as `.github/package.sh` makes them.
    public struct Release: Equatable, Sendable {
        public let version: String
        public var page: URL { URL(string: "https://github.com/\(repo)/releases/tag/v\(version)")! }
        public var appZip: URL { download("UsageMeter-\(version).zip") }
        public var sums: URL { download("SHA256SUMS.txt") }
        public var appZipName: String { "UsageMeter-\(version).zip" }
        public init(version: String) { self.version = version }
        private func download(_ name: String) -> URL {
            URL(string: "https://github.com/\(repo)/releases/download/v\(version)/\(name)")!
        }
    }

    /// [0, 1, 12] for "0.1.12" or "v0.1.12"; nil for anything else, such as a dev build's
    /// "0.1.11-3-gabc1234-dirty", which is never offered an update.
    public static func numbers(_ version: String) -> [Int]? {
        let plain = version.hasPrefix("v") ? String(version.dropFirst()) : version
        let parts = plain.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.map { $0! }
    }

    /// True when `latest` is a higher plain version than `current` ("0.1.10" after "0.1.9").
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        guard let l = numbers(latest), let c = numbers(current) else { return false }
        for i in 0..<max(l.count, c.count) {
            let (a, b) = (i < l.count ? l[i] : 0, i < c.count ? c[i] : 0)
            if a != b { return a > b }
        }
        return false
    }

    /// The release in GitHub's "latest release" answer, from its tag ("v0.1.12").
    public static func release(fromLatest data: Data) -> Release? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = o["tag_name"] as? String, numbers(tag) != nil else { return nil }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag)
    }

    /// The release a formula builds, from its `url ".../archive/refs/tags/v0.1.12.tar.gz"` line.
    public static func release(fromFormula text: String) -> Release? {
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("url \""), let r = t.range(of: "/archive/refs/tags/v"),
                  let end = t.range(of: ".tar.gz", range: r.upperBound..<t.endIndex) else { continue }
            let version = String(t[r.upperBound..<end.lowerBound])
            return numbers(version) != nil ? Release(version: version) : nil
        }
        return nil
    }

    /// The SHA-256 for `file` in a `shasum -a 256` listing ("<hex>  <name>" per line).
    public static func checksum(for file: String, in sums: String) -> String? {
        for line in sums.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, parts[1] == file || parts[1] == "*" + file { return parts[0].lowercased() }
        }
        return nil
    }

    public static func sha256(of file: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
