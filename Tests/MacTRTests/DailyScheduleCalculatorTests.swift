import Foundation
import Testing
@testable import MacTR

struct DailyScheduleCalculatorTests {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar? = nil
    ) -> Date {
        let calendar = calendar ?? utcCalendar
        return calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute))!
    }

    @Test("A normal daytime active window includes start and excludes close")
    func daytimeWindow() {
        let calendar = utcCalendar
        #expect(DailyScheduleCalculator.isWithinActiveWindow(
            at: date(2026, 7, 27, 8, 0),
            startMinutes: 8 * 60,
            closeMinutes: 23 * 60,
            calendar: calendar))
        #expect(DailyScheduleCalculator.isWithinActiveWindow(
            at: date(2026, 7, 27, 22, 59),
            startMinutes: 8 * 60,
            closeMinutes: 23 * 60,
            calendar: calendar))
        #expect(!DailyScheduleCalculator.isWithinActiveWindow(
            at: date(2026, 7, 27, 23, 0),
            startMinutes: 8 * 60,
            closeMinutes: 23 * 60,
            calendar: calendar))
    }

    @Test("An overnight active window spans midnight")
    func overnightWindow() {
        let calendar = utcCalendar
        #expect(DailyScheduleCalculator.isWithinActiveWindow(
            at: date(2026, 7, 27, 23, 30),
            startMinutes: 22 * 60,
            closeMinutes: 6 * 60,
            calendar: calendar))
        #expect(DailyScheduleCalculator.isWithinActiveWindow(
            at: date(2026, 7, 28, 5, 59),
            startMinutes: 22 * 60,
            closeMinutes: 6 * 60,
            calendar: calendar))
        #expect(!DailyScheduleCalculator.isWithinActiveWindow(
            at: date(2026, 7, 28, 12, 0),
            startMinutes: 22 * 60,
            closeMinutes: 6 * 60,
            calendar: calendar))
    }

    @Test("Equal start and close times represent an always-active window")
    func equalTimes() {
        #expect(DailyScheduleCalculator.isWithinActiveWindow(
            at: date(2026, 7, 27, 12, 0),
            startMinutes: 9 * 60,
            closeMinutes: 9 * 60,
            calendar: utcCalendar))
    }

    @Test("The next boundary chooses the earliest enabled action")
    func nextBoundary() {
        let now = date(2026, 7, 27, 22, 0)
        let boundary = DailyScheduleCalculator.nextBoundary(
            after: now,
            startMinutes: 8 * 60,
            closeMinutes: 23 * 60,
            includesStart: true,
            calendar: utcCalendar)
        #expect(boundary?.kind == .close)
        #expect(boundary?.date == date(2026, 7, 27, 23, 0))

        let closeOnly = DailyScheduleCalculator.nextBoundary(
            after: date(2026, 7, 27, 23, 30),
            startMinutes: 8 * 60,
            closeMinutes: 23 * 60,
            includesStart: false,
            calendar: utcCalendar)
        #expect(closeOnly?.kind == .close)
        #expect(closeOnly?.date == date(2026, 7, 28, 23, 0))
    }

    @Test("Wake reconciliation returns every crossed boundary in order")
    func crossedBoundaries() {
        let boundaries = DailyScheduleCalculator.boundariesCrossed(
            from: date(2026, 7, 27, 22, 30),
            through: date(2026, 7, 28, 8, 30),
            startMinutes: 8 * 60,
            closeMinutes: 23 * 60,
            includesStart: true,
            calendar: utcCalendar)
        #expect(boundaries.map(\.kind) == [.close, .start])
        #expect(boundaries.map(\.date) == [
            date(2026, 7, 27, 23, 0),
            date(2026, 7, 28, 8, 0),
        ])
    }

    @Test("Spring-forward gaps move to the next valid local time")
    func daylightSavingGap() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let beforeGap = date(2026, 3, 8, 1, 45, calendar: calendar)
        let next = try #require(DailyScheduleCalculator.nextDate(
            for: 2 * 60 + 30,
            after: beforeGap,
            calendar: calendar))
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: next)
        #expect(components.year == 2026)
        #expect(components.month == 3)
        #expect(components.day == 8)
        #expect(components.hour == 3)
    }

    @Test("Minute values normalize across day boundaries")
    func normalizedMinutes() {
        #expect(AppPreferences.normalizeMinutes(-1) == 1439)
        #expect(AppPreferences.normalizeMinutes(1440) == 0)
        #expect(AppPreferences.normalizeMinutes(1500) == 60)
    }

    @Test("User-facing display and schedule settings persist")
    @MainActor
    func preferencesPersist() throws {
        let suiteName = "com.beret21.MacTR.tests.preferences"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Defaults to on, so the assertion below is meaningful only if it is
        // flipped off here.
        #expect(AppPreferences(defaults: defaults).countCachedTokens)

        let first = AppPreferences(defaults: defaults)
        first.language = .english
        first.countCachedTokens = false
        first.brightness = 9
        first.refreshInterval = 2
        first.performanceMode = .eco
        first.rotateDisplay = true
        first.autoShowPreviewWhenDisconnected = true
        first.customScriptEnabled = true
        first.customScriptPath = "/tmp/status card.sh"
        first.customScriptDisplayName = "STATUS"
        first.customScriptIntervalSeconds = 45
        first.customScriptFontMode = .large
        first.scheduleEnabled = true
        first.scheduleAction = .quitApp
        first.automaticStartEnabled = false
        first.startMinutes = 7 * 60 + 15
        first.closeMinutes = 22 * 60 + 45

        let restored = AppPreferences(defaults: defaults)
        #expect(restored.language == .english)
        #expect(!restored.countCachedTokens)
        #expect(restored.brightness == 9)
        #expect(restored.refreshInterval == 2)
        #expect(restored.performanceMode == .eco)
        #expect(restored.rotateDisplay)
        #expect(restored.autoShowPreviewWhenDisconnected)
        #expect(restored.customScriptEnabled)
        #expect(restored.customScriptPath == "/tmp/status card.sh")
        #expect(restored.customScriptDisplayName == "STATUS")
        #expect(restored.customScriptIntervalSeconds == 45)
        #expect(restored.customScriptFontMode == .large)
        #expect(restored.scheduleEnabled)
        #expect(restored.scheduleAction == .quitApp)
        #expect(!restored.automaticStartEnabled)
        #expect(restored.startMinutes == 7 * 60 + 15)
        #expect(restored.closeMinutes == 22 * 60 + 45)
    }
}
