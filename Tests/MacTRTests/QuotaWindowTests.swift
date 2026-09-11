import Foundation
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
        #expect(parsed?.window.windowMinutes == 300)
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

    // MARK: - Pools and plans

    /// The real account-pool reading from a Pro Lite account, sampled
    /// 2026-09-11 from a rollout started 2026-09-04: only the 7-day window
    /// exists, `secondary` is JSON null, and the plan is named.
    @Test("A Pro Lite account reading yields the weekly window alone")
    func proLiteAccountReading() {
        let windows = QuotaWindow.codexWindows(from: [
            "limit_id": "codex",
            "limit_name": NSNull(),
            "primary": ["used_percent": 38.0, "window_minutes": 10_080, "resets_at": 1_789_474_020],
            "secondary": NSNull(),
            "plan_type": "prolite",
        ])
        #expect(windows.map(\.label) == ["7d"])
        #expect(windows.map(\.usedPercent) == [38.0])
    }

    /// The reading that produced the "100% remaining" display: a guardian
    /// subagent drawing on the model-specific `codex_bengalfox` pool, which
    /// reports both windows at 0% and no plan. Sampled 2026-09-11.
    @Test("A model-specific side pool is ignored entirely")
    func sidePoolIsIgnored() {
        let windows = QuotaWindow.codexWindows(from: [
            "limit_id": "codex_bengalfox",
            "limit_name": "GPT-5.3-Codex-Spark",
            "primary": ["used_percent": 0.0, "window_minutes": 300, "resets_at": 1_789_154_493],
            "secondary": ["used_percent": 0.0, "window_minutes": 10_080, "resets_at": 1_789_741_293],
            "plan_type": NSNull(),
        ])
        #expect(windows.isEmpty)
    }

    @Test("A reading without limit_id (older Codex) counts as the account pool")
    func missingLimitIdIsAccountPool() {
        #expect(QuotaWindow.isCodexAccountPool([:]))
        #expect(QuotaWindow.isCodexAccountPool(["limit_id": "codex"]))
        #expect(!QuotaWindow.isCodexAccountPool(["limit_id": "codex_bengalfox"]))
        // Present but null is an unknown pool, not a missing field.
        #expect(!QuotaWindow.isCodexAccountPool(["limit_id": NSNull()]))
    }

    @Test("Pro plans drop a 5-hour block even when one is reported")
    func proPlansDropShortWindow() {
        for plan in ["pro", "prolite", "Pro"] {
            let windows = QuotaWindow.codexWindows(from: [
                "limit_id": "codex",
                "primary": ["used_percent": 0.0, "window_minutes": 300, "resets_at": 1_789_154_493],
                "secondary": ["used_percent": 38.0, "window_minutes": 10_080, "resets_at": 1_789_474_020],
                "plan_type": plan,
            ])
            #expect(windows.map(\.label) == ["7d"], "plan \(plan)")
        }
    }

    @Test("Plus keeps both windows, and an unnamed plan keeps whatever is reported")
    func plusAndUnknownPlansKeepShortWindow() {
        let blocks: [String: Any] = [
            "limit_id": "codex",
            "primary": ["used_percent": 18.0, "window_minutes": 300, "resets_at": 1_787_691_728],
            "secondary": ["used_percent": 34.0, "window_minutes": 10_080, "resets_at": 1_788_278_528],
        ]
        var plus = blocks; plus["plan_type"] = "plus"
        #expect(QuotaWindow.codexWindows(from: plus).map(\.label) == ["5h", "7d"])
        var unnamed = blocks; unnamed["plan_type"] = NSNull()
        #expect(QuotaWindow.codexWindows(from: unnamed).map(\.label) == ["5h", "7d"])
        #expect(QuotaWindow.codexWindows(from: blocks).map(\.label) == ["5h", "7d"])
    }

    // MARK: - rolledForward

    @Test("rolledForward leaves an unexpired window untouched")
    func rolledForwardNoOpWhenFresh() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let window = QuotaWindow(
            label: "5h", usedPercent: 42, resetsAt: now.addingTimeInterval(60),
            windowMinutes: 300)
        #expect(window.rolledForward(now: now) == window)
    }

    @Test("rolledForward leaves a window without a known length untouched")
    func rolledForwardNoOpWithoutWindowMinutes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Mirrors Claude's windows, which never carry windowMinutes.
        let window = QuotaWindow(
            label: "5h", usedPercent: 42, resetsAt: now.addingTimeInterval(-60))
        #expect(window.rolledForward(now: now) == window)
    }

    @Test("rolledForward leaves a window without a reset time untouched")
    func rolledForwardNoOpWithoutResetsAt() {
        let window = QuotaWindow(
            label: "7d", usedPercent: 12, resetsAt: nil, windowMinutes: 10_080)
        #expect(window.rolledForward() == window)
    }

    /// The exact scenario this exists for: Codex idle well past its 5-hour
    /// reset, no fresher reading available. Mirrors the real gap observed
    /// 2026-08-26 (~13h41m idle against a 5h window) that inspired this fix.
    @Test("An expired window snaps forward across multiple missed cycles, zeroed")
    func rolledForwardMultipleCycles() {
        let windowSeconds: TimeInterval = 300 * 60
        let resetsAt = Date(timeIntervalSince1970: 1_000_000)
        // Just past the boundary of the 3rd cycle after resetsAt.
        let now = resetsAt.addingTimeInterval(windowSeconds * 2 + 60)
        let window = QuotaWindow(
            label: "5h", usedPercent: 80, resetsAt: resetsAt, windowMinutes: 300)

        let rolled = window.rolledForward(now: now)
        #expect(rolled.label == "5h")
        #expect(rolled.usedPercent == 0)
        #expect(rolled.windowMinutes == 300)
        #expect(rolled.resetsAt == resetsAt.addingTimeInterval(windowSeconds * 3))
        #expect(rolled.resetsAt! > now)  // never re-emerges as still-expired
    }

    @Test("An expired window barely past its boundary rolls forward exactly one cycle")
    func rolledForwardOneCycle() {
        let windowSeconds: TimeInterval = 10_080 * 60
        let resetsAt = Date(timeIntervalSince1970: 1_000_000)
        let now = resetsAt.addingTimeInterval(1)
        let window = QuotaWindow(
            label: "7d", usedPercent: 57, resetsAt: resetsAt, windowMinutes: 10_080)

        let rolled = window.rolledForward(now: now)
        #expect(rolled.usedPercent == 0)
        #expect(rolled.resetsAt == resetsAt.addingTimeInterval(windowSeconds))
    }
}
