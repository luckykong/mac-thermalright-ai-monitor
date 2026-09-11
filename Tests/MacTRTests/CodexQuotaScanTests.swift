import Foundation
import Testing
@testable import MacTR

/// End-to-end over a fake `~/.codex/sessions` tree: which reading the
/// collector picks, given where Codex actually files rollouts and what the
/// guardian subagent writes. Mirrors the layout observed 2026-09-11.
@Suite("Codex quota scan across session directories")
struct CodexQuotaScanTests {

    /// A fresh formatter per call: ISO8601DateFormatter is not Sendable, so
    /// a shared static would trip strict concurrency checking.
    private static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private static func dayDir(root: URL, daysAgo: Int) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd"
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return root.appendingPathComponent(df.string(from: day))
    }

    /// One `token_count` event carrying `rateLimits`, timestamped `at`.
    private static func tokenCountLine(at: Date, rateLimits: String) -> String {
        """
        {"timestamp":"\(iso(at))","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":1,"total_tokens":11}},"rate_limits":\(rateLimits)}}
        """
    }

    private static func write(_ lines: [String], to dir: URL, name: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    @Test("The account pool in a week-old rollout beats a newer side-pool reading in today's directory")
    func accountPoolFromOldDirectoryWins() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactr-codex-quota-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".codex/sessions")

        let now = Date()
        // Reset times are relative to now so the test does not expire: AgentUsage
        // drops any window whose reset has already passed.
        let weekly = Int(now.addingTimeInterval(4 * 86400).timeIntervalSince1970)
        let short = Int(now.addingTimeInterval(3 * 3600).timeIntervalSince1970)

        // Still-active session started seven days ago — outside the four-day
        // directory window the scan used to visit — holding the real reading.
        try Self.write(
            [Self.tokenCountLine(
                at: now.addingTimeInterval(-120),
                rateLimits: """
                {"limit_id":"codex","limit_name":null,"primary":{"used_percent":38.0,"window_minutes":10080,"resets_at":\(weekly)},"secondary":null,"credits":{"has_credits":true,"unlimited":false,"balance":"2937.30"},"plan_type":"prolite","rate_limit_reached_type":null}
                """)],
            to: Self.dayDir(root: sessions, daysAgo: 7), name: "rollout-old-account.jsonl")

        // Guardian subagent started today, newer timestamp, model-specific pool.
        try Self.write(
            [Self.tokenCountLine(
                at: now.addingTimeInterval(-30),
                rateLimits: """
                {"limit_id":"codex_bengalfox","limit_name":"GPT-5.3-Codex-Spark","primary":{"used_percent":0.0,"window_minutes":300,"resets_at":\(short)},"secondary":{"used_percent":0.0,"window_minutes":10080,"resets_at":\(weekly)},"plan_type":null,"rate_limit_reached_type":null}
                """)],
            to: Self.dayDir(root: sessions, daysAgo: 0), name: "rollout-guardian.jsonl")

        let codex = AgentUsageCollector(home: home.path).collect().codex
        #expect(codex.available)
        #expect(codex.quotaWindows.map(\.label) == ["7d"])
        #expect(codex.quotaWindows.map(\.usedPercent) == [38.0])
    }

    /// One rollout can switch model mid-thread, so an account-pool reading may
    /// be followed by a side-pool one in the same file. The newest line alone
    /// would discard the file; the scan must keep going to the account line.
    @Test("An account reading older than a side-pool line in the same file is still found")
    func accountLineBehindSidePoolLineInOneFile() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactr-codex-quota-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".codex/sessions")
        let now = Date()
        let weekly = Int(now.addingTimeInterval(4 * 86400).timeIntervalSince1970)
        let short = Int(now.addingTimeInterval(3 * 3600).timeIntervalSince1970)

        try Self.write(
            [
                Self.tokenCountLine(
                    at: now.addingTimeInterval(-120),
                    rateLimits: """
                    {"limit_id":"codex","primary":{"used_percent":41.0,"window_minutes":10080,"resets_at":\(weekly)},"secondary":null,"plan_type":"prolite"}
                    """),
                Self.tokenCountLine(
                    at: now.addingTimeInterval(-30),
                    rateLimits: """
                    {"limit_id":"codex_bengalfox","primary":{"used_percent":0.0,"window_minutes":300,"resets_at":\(short)},"secondary":{"used_percent":0.0,"window_minutes":10080,"resets_at":\(weekly)},"plan_type":null}
                    """),
            ],
            to: Self.dayDir(root: sessions, daysAgo: 0), name: "rollout-mixed.jsonl")

        let codex = AgentUsageCollector(home: home.path).collect().codex
        #expect(codex.quotaWindows.map(\.label) == ["7d"])
        #expect(codex.quotaWindows.map(\.usedPercent) == [41.0])
    }

    /// The directory window is wide precisely so that the modification-time
    /// cut-off can do the real filtering: a rollout untouched for longer than
    /// three days is not a source, however recent its directory looks.
    @Test("A rollout not modified within three days is ignored even in a recent directory")
    func staleFileIsIgnoredByModificationTime() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactr-codex-quota-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".codex/sessions")
        let now = Date()
        let weekly = Int(now.addingTimeInterval(4 * 86400).timeIntervalSince1970)

        let dir = Self.dayDir(root: sessions, daysAgo: 1)
        try Self.write(
            [Self.tokenCountLine(
                at: now.addingTimeInterval(-5 * 86400),
                rateLimits: """
                {"limit_id":"codex","primary":{"used_percent":9.0,"window_minutes":10080,"resets_at":\(weekly)},"secondary":null,"plan_type":"prolite"}
                """)],
            to: dir, name: "rollout-stale.jsonl")
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-5 * 86400)],
            ofItemAtPath: dir.appendingPathComponent("rollout-stale.jsonl").path)

        let codex = AgentUsageCollector(home: home.path).collect().codex
        #expect(codex.quotaWindows.isEmpty)
    }

    @Test("With only a side-pool reading available the card shows no quota rather than 100%")
    func sidePoolAloneShowsNothing() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("mactr-codex-quota-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".codex/sessions")
        let later = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)

        try Self.write(
            [Self.tokenCountLine(
                at: Date().addingTimeInterval(-30),
                rateLimits: """
                {"limit_id":"codex_bengalfox","primary":{"used_percent":0.0,"window_minutes":300,"resets_at":\(later)},"secondary":{"used_percent":0.0,"window_minutes":10080,"resets_at":\(later)},"plan_type":null}
                """)],
            to: Self.dayDir(root: sessions, daysAgo: 0), name: "rollout-guardian.jsonl")

        let codex = AgentUsageCollector(home: home.path).collect().codex
        #expect(codex.quotaWindows.isEmpty)
    }
}
