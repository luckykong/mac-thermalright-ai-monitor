import Testing
@testable import MacTR

@Suite("Quota window labels and Codex rate-limit parsing")
struct QuotaWindowTests {

    @Test("Window length in minutes maps to a short label")
    func minuteLabels() {
        #expect(QuotaWindow.label(minutes: 300) == "5h")
        #expect(QuotaWindow.label(minutes: 60) == "1h")
        #expect(QuotaWindow.label(minutes: 10_080) == "7d")
        #expect(QuotaWindow.label(minutes: 1_440) == "1d")
        #expect(QuotaWindow.label(minutes: 90) == "90m")
    }

    /// A real Codex `rate_limits.primary` block, sampled 2026-08-26 right
    /// after the 5-hour cap came back: window_minutes 300 == 5h.
    @Test("A primary block parses into a labeled window")
    func parsesPrimaryBlock() {
        let parsed = QuotaWindow.fromCodexBlock([
            "used_percent": 0.0,
            "window_minutes": 300,
            "resets_at": 1_787_691_728,
        ])
        #expect(parsed?.minutes == 300)
        #expect(parsed?.window.label == "5h")
        #expect(parsed?.window.usedPercent == 0.0)
        #expect(parsed?.window.resetsAt == Date(timeIntervalSince1970: 1_787_691_728))
    }

    @Test("A block missing window_minutes is dropped rather than shown unlabeled")
    func dropsBlockWithoutWindowMinutes() {
        #expect(QuotaWindow.fromCodexBlock(["used_percent": 12.0]) == nil)
    }

    @Test("A block missing used_percent is dropped")
    func dropsBlockWithoutUsedPercent() {
        #expect(QuotaWindow.fromCodexBlock(["window_minutes": 300]) == nil)
    }

    @Test("A missing resets_at still parses, just without a countdown")
    func toleratesMissingResetsAt() {
        let parsed = QuotaWindow.fromCodexBlock([
            "used_percent": 5.0,
            "window_minutes": 10_080,
        ])
        #expect(parsed?.window.resetsAt == nil)
    }

    /// The real shape seen once the 5-hour cap is active again: both blocks
    /// populated, primary == 5h, secondary == 7d.
    @Test("Both windows parse and land in shortest-first order")
    func bothWindowsPresent() {
        let windows = QuotaWindow.codexWindows(from: [
            "primary": ["used_percent": 18.0, "window_minutes": 300, "resets_at": 1_787_691_728],
            "secondary": ["used_percent": 34.0, "window_minutes": 10_080, "resets_at": 1_788_278_528],
        ])
        #expect(windows.map(\.label) == ["5h", "7d"])
        #expect(windows.map(\.usedPercent) == [18.0, 34.0])
    }

    /// Observed while the 5-hour cap was suspended: `primary` carried the
    /// 7-day figure alone and `secondary` was absent. Order must still come
    /// out correctly from the window length, not the JSON key name.
    @Test("A single, longer window under the primary key is still labeled 7d")
    func onlyPrimaryPresentAsSevenDay() {
        let windows = QuotaWindow.codexWindows(from: [
            "primary": ["used_percent": 43.0, "window_minutes": 10_080, "resets_at": 1_788_278_528],
        ])
        #expect(windows.map(\.label) == ["7d"])
    }

    @Test("An empty or malformed rate_limits object yields no windows")
    func emptyRateLimits() {
        #expect(QuotaWindow.codexWindows(from: [:]).isEmpty)
        #expect(QuotaWindow.codexWindows(from: ["primary": "not a dictionary"]).isEmpty)
    }
}
