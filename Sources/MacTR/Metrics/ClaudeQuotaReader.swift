// ClaudeQuotaReader.swift — Claude rate-limit windows from a local cache file
//
// Codex records `rate_limits.primary` on every rollout line, so its quota falls
// out of transcripts MacTR already reads. Claude Code persists nothing
// comparable — not in ~/.claude/projects, not in stats-cache.json, nowhere on
// disk. The only source is an authenticated call to Anthropic's OAuth usage
// endpoint.
//
// MacTR deliberately does not make that call. It would require reading the
// "Claude Code-credentials" Keychain item, and refreshing an expired token
// there rotates the *shared* refresh token, which signs Claude Code itself out.
// Keeping MacTR to local files also preserves the property that it performs no
// network I/O at all.
//
// So this reads a cache written by whatever tool the user already runs for
// this. Default path is ~/.cache/mactr/claude-usage.json; point it at an
// existing cache instead with:
//
//     defaults write com.beret21.MacTR claudeUsageCachePath /path/to/cache.json

import Foundation

final class ClaudeQuotaReader {

    static let defaultsKey = "claudeUsageCachePath"

    /// Past this age the utilisation figures are too old to show at a glance.
    /// Individual windows are dropped sooner when their own reset has passed,
    /// which is the sharper test — `resets_at` is absolute, so an elapsed one
    /// proves the percentage beside it has already rolled over.
    private let maxCacheAge: TimeInterval = 12 * 60 * 60

    /// Window keys in display order, with the short labels shown on the card.
    private static let windowKeys: [(key: String, label: String)] = [
        ("five_hour", "5h"),
        ("seven_day", "7d"),
    ]

    private let fileManager = FileManager.default
    /// Bypasses defaults/fallback resolution. Tests supply a fixture path.
    private let pathOverride: String?
    private var cachedWindows: [QuotaWindow] = []
    private var cachedPath: String?
    private var cachedMtime: Date?
    private var warnedAboutParse = false

    init(path: String? = nil) {
        self.pathOverride = path
    }

    /// Re-parses only when the file's mtime changes, so the steady-state cost
    /// is one stat per collection tick.
    func windows() -> [QuotaWindow] {
        guard let path = resolvePath(),
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              let mtime = attributes[.modificationDate] as? Date
        else {
            cachedWindows = []
            cachedPath = nil
            cachedMtime = nil
            return []
        }

        if path != cachedPath || mtime != cachedMtime {
            cachedPath = path
            cachedMtime = mtime
            cachedWindows = parse(path: path)
        }
        return cachedWindows.filter { !$0.isExpired }
    }

    private func resolvePath() -> String? {
        if let pathOverride { return pathOverride }
        if let override = UserDefaults.standard.string(forKey: Self.defaultsKey),
           !override.isEmpty
        {
            return (override as NSString).expandingTildeInPath
        }
        let fallback = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/mactr/claude-usage.json").path
        return fileManager.fileExists(atPath: fallback) ? fallback : nil
    }

    private func parse(path: String) -> [QuotaWindow] {
        guard let data = fileManager.contents(atPath: path),
              let root = (try? JSONSerialization.jsonObject(with: data))
                  as? [String: Any]
        else {
            if !warnedAboutParse {
                warnedAboutParse = true
                log("[Agents] Claude usage cache at \(path) is not readable JSON")
            }
            return []
        }
        warnedAboutParse = false

        // token-usage-dash nests the payload under providers.claude.data; a
        // hand-written cache may put the same fields at the top level.
        let provider = (root["providers"] as? [String: Any])?["claude"]
            as? [String: Any] ?? root
        let payload = provider["data"] as? [String: Any] ?? provider

        if let fetchedAt = Self.date(from: provider["fetched_at"] ?? root["fetched_at"]),
           Date().timeIntervalSince(fetchedAt) > maxCacheAge
        {
            return []
        }

        return Self.windowKeys.compactMap { key, label in
            guard let window = payload[key] as? [String: Any],
                  let used = (window["utilization"] as? NSNumber)?.doubleValue
            else { return nil }
            return QuotaWindow(
                label: label,
                usedPercent: used,
                resetsAt: Self.date(from: window["resets_at"]))
        }
    }

    /// ISO 8601, with or without fractional seconds — producers differ.
    private static func date(from value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
