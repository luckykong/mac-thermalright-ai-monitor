// ClaudeUsageFetcher.swift — Claude rate-limit windows from Anthropic's
// OAuth usage endpoint
//
// Codex records `rate_limits.primary` on every rollout line, so its quota falls
// out of transcripts MacTR already reads. Claude Code persists nothing
// comparable — not in ~/.claude/projects, not in stats-cache.json, nowhere on
// disk. Asking the API is the only way to get it.
//
// This is the one and only place MacTR touches the network.
//
// It NEVER refreshes the token. The refresh token in the
// "Claude Code-credentials" keychain item is shared with Claude Code itself,
// and rotating it signs Claude Code out. When the access token expires the
// quota simply disappears from the dashboard until Claude Code renews it in
// the course of normal use — which it does on its own.

import Foundation

final class ClaudeUsageFetcher: @unchecked Sendable {

    private static let endpoint = URL(
        string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"
    private static let betaHeader = "oauth-2025-04-20"

    /// Quota moves slowly, and the endpoint rate-limits, so this is deliberately
    /// far longer than the metrics tick that calls `windows()`.
    private static let refreshInterval: TimeInterval = 5 * 60
    /// After a failure, wait longer before trying again rather than hammering.
    private static let retryInterval: TimeInterval = 15 * 60
    private static let requestTimeout: TimeInterval = 10

    /// Windows to display, in order. The endpoint also reports per-model
    /// seven-day windows; the two headline ones are what fit on the card.
    private static let windowKeys: [(key: String, label: String)] = [
        ("five_hour", "5h"),
        ("seven_day", "7d"),
    ]

    private let queue = DispatchQueue(
        label: "com.beret21.MacTR.claude-usage", qos: .utility)
    private let lock = NSLock()
    private var cachedWindows: [QuotaWindow] = []
    private var nextAttempt = Date.distantPast
    private var refreshing = false
    /// nil once a fetch has succeeded, the failure reason otherwise. Starts as
    /// a sentinel so the first outcome — success or failure — always logs.
    private var loggedState: String? = "(not attempted)"

    /// Returns immediately with whatever was last fetched, kicking off a
    /// background refresh when due. Never blocks the metrics loop on I/O.
    func windows() -> [QuotaWindow] {
        lock.lock()
        let due = !refreshing && Date() >= nextAttempt
        if due { refreshing = true }
        let current = cachedWindows
        lock.unlock()

        if due {
            queue.async { [weak self] in self?.refresh() }
        }
        return current.filter { !$0.isExpired }
    }

    // MARK: - Refresh

    private func refresh() {
        var windows: [QuotaWindow] = []
        var succeeded = false

        defer {
            lock.lock()
            refreshing = false
            nextAttempt = Date().addingTimeInterval(
                succeeded ? Self.refreshInterval : Self.retryInterval)
            if succeeded { cachedWindows = windows }
            lock.unlock()
        }

        guard let credentials = Self.loadCredentials() else {
            note("no Claude Code credentials in the keychain")
            return
        }
        // Expired is normal, not an error: Claude Code renews it whenever it is
        // next used, and refreshing it here would sign Claude Code out.
        guard !credentials.isExpired else {
            note("Claude Code access token is expired; waiting for it to renew")
            return
        }

        switch Self.fetch(token: credentials.accessToken) {
        case .success(let payload):
            windows = Self.parse(payload)
            succeeded = true
            let summary = windows
                .map { "\($0.label) \(Int($0.usedPercent.rounded()))%" }
                .joined(separator: ", ")
            note(nil, detail: summary.isEmpty ? "no windows reported" : summary)
        case .failure(let failure):
            note(failure.reason)
        }
    }

    /// Logs only on a change of state, so a persistent problem does not repeat
    /// every refresh while a recovery still shows up.
    private func note(_ reason: String?, detail: String = "") {
        lock.lock()
        let changed = loggedState != reason
        loggedState = reason
        lock.unlock()
        guard changed else { return }
        if let reason {
            log("[Agents] Claude usage unavailable — \(reason)")
        } else {
            log("[Agents] Claude usage: \(detail)")
        }
    }

    // MARK: - Keychain

    private struct Credentials {
        let accessToken: String
        let expiresAt: Date?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt <= Date()
        }
    }

    /// Reads the token through `/usr/bin/security` rather than
    /// `SecItemCopyMatching`. The keychain ACL is keyed to the requesting
    /// binary's signature, and MacTR is ad-hoc signed — every rebuild produces
    /// a new identity and would re-prompt. `security` is a stable system binary
    /// the user grants once.
    private static func loadCredentials() -> Credentials? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password", "-s", keychainService, "-w",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        guard let root = (try? JSONSerialization.jsonObject(with: data))
                  as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return nil }

        // expiresAt is milliseconds since the epoch.
        let expiresAt = (oauth["expiresAt"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return Credentials(accessToken: token, expiresAt: expiresAt)
    }

    // MARK: - Network

    /// Carries a short human-readable reason for the log; nothing here is
    /// actionable in code, every failure just means "no quota to show".
    private struct FetchFailure: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// The completion handler writes on URLSession's queue while `fetch` blocks
    /// on the semaphore. The signal/wait pair already orders the write before the
    /// read, but that ordering is invisible to the compiler, so the value travels
    /// through a lock it can see rather than a captured `var`.
    private final class FetchResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<[String: Any], FetchFailure> =
            .failure(FetchFailure("request never completed"))

        func set(_ newValue: Result<[String: Any], FetchFailure>) {
            lock.lock()
            defer { lock.unlock() }
            value = newValue
        }

        func get() -> Result<[String: Any], FetchFailure> {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private static func fetch(token: String) -> Result<[String: Any], FetchFailure> {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")

        let semaphore = DispatchSemaphore(value: 0)
        let result = FetchResultBox()

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result.set(.failure(FetchFailure(error.localizedDescription)))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                result.set(.failure(FetchFailure("no HTTP response")))
                return
            }
            guard http.statusCode == 200 else {
                // 401/403 usually means the token lacks the usage scope; 429 is
                // the endpoint asking us to back off. Both just mean "no data".
                result.set(.failure(FetchFailure("HTTP \(http.statusCode)")))
                return
            }
            guard let data,
                  let json = (try? JSONSerialization.jsonObject(with: data))
                      as? [String: Any]
            else {
                result.set(.failure(FetchFailure("unreadable response body")))
                return
            }
            result.set(.success(json))
        }
        task.resume()

        if semaphore.wait(timeout: .now() + requestTimeout + 5) == .timedOut {
            task.cancel()
            return .failure(FetchFailure("timed out"))
        }
        return result.get()
    }

    private static func parse(_ payload: [String: Any]) -> [QuotaWindow] {
        windowKeys.compactMap { key, label in
            guard let window = payload[key] as? [String: Any],
                  let used = (window["utilization"] as? NSNumber)?.doubleValue
            else { return nil }
            return QuotaWindow(
                label: label,
                usedPercent: used,
                resetsAt: date(from: window["resets_at"]))
        }
    }

    /// ISO 8601, with or without fractional seconds.
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
