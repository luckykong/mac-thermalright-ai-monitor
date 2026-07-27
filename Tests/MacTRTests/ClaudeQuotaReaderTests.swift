import Foundation
import Testing
@testable import MacTR

@Suite("Claude quota cache")
struct ClaudeQuotaReaderTests {

    /// Writes `json` to a throwaway file and returns its path.
    private func fixture(_ json: String) throws -> (path: String, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("claude-usage.json")
        try Data(json.utf8).write(to: file)
        return (file.path, { try? FileManager.default.removeItem(at: directory) })
    }

    private func iso(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(offset))
    }

    @Test("Reads the nested token-usage-dash layout")
    func nestedLayout() throws {
        let (path, cleanup) = try fixture("""
            {"providers": {"claude": {
              "fetched_at": "\(iso(-600))",
              "data": {
                "five_hour": {"utilization": 22.0, "resets_at": "\(iso(3 * 3600))"},
                "seven_day": {"utilization": 9.0, "resets_at": "\(iso(4 * 86400))"}
              }}}}
            """)
        defer { cleanup() }

        let windows = ClaudeQuotaReader(path: path).windows()
        #expect(windows.count == 2)
        #expect(windows[0].label == "5h")
        #expect(windows[0].usedPercent == 22.0)
        #expect(windows[1].label == "7d")
        #expect(windows[1].usedPercent == 9.0)
    }

    @Test("Reads a flat hand-written cache too")
    func flatLayout() throws {
        let (path, cleanup) = try fixture("""
            {"fetched_at": "\(iso(-60))",
             "five_hour": {"utilization": 50.0, "resets_at": "\(iso(1800))"}}
            """)
        defer { cleanup() }

        let windows = ClaudeQuotaReader(path: path).windows()
        #expect(windows.count == 1)
        #expect(windows[0].usedPercent == 50.0)
    }

    /// `resets_at` is absolute, so one in the past proves the percentage beside
    /// it already rolled over — a sharper staleness test than cache age.
    @Test("Drops windows whose reset time has already passed")
    func expiredWindowsAreDropped() throws {
        let (path, cleanup) = try fixture("""
            {"providers": {"claude": {
              "fetched_at": "\(iso(-7200))",
              "data": {
                "five_hour": {"utilization": 80.0, "resets_at": "\(iso(-60))"},
                "seven_day": {"utilization": 12.0, "resets_at": "\(iso(3 * 86400))"}
              }}}}
            """)
        defer { cleanup() }

        let windows = ClaudeQuotaReader(path: path).windows()
        #expect(windows.count == 1)
        #expect(windows[0].label == "7d")
    }

    @Test("Ignores a cache that is far too old to trust")
    func staleCacheIsIgnored() throws {
        let (path, cleanup) = try fixture("""
            {"providers": {"claude": {
              "fetched_at": "\(iso(-24 * 3600))",
              "data": {
                "five_hour": {"utilization": 30.0, "resets_at": "\(iso(3600))"}
              }}}}
            """)
        defer { cleanup() }

        #expect(ClaudeQuotaReader(path: path).windows().isEmpty)
    }

    @Test("A missing or malformed cache yields no windows, not a crash")
    func missingAndMalformed() throws {
        #expect(ClaudeQuotaReader(path: "/nonexistent/claude-usage.json")
            .windows().isEmpty)

        let (path, cleanup) = try fixture("not json at all")
        defer { cleanup() }
        #expect(ClaudeQuotaReader(path: path).windows().isEmpty)
    }

    @Test("Window lengths render as short labels")
    func windowLabels() {
        #expect(QuotaWindow.label(minutes: 10080) == "7d")
        #expect(QuotaWindow.label(minutes: 300) == "5h")
        #expect(QuotaWindow.label(minutes: 45) == "45m")
    }
}
