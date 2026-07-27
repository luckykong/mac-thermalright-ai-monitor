// DailyScheduleController.swift — calendar-aware daily display/quit scheduling

import AppKit
import Foundation

enum DailyScheduleBoundaryKind: String, Sendable {
    case start
    case close
}

struct DailyScheduleBoundary: Equatable, Sendable {
    let kind: DailyScheduleBoundaryKind
    let date: Date
}

enum DailyScheduleCalculator {
    static func minuteOfDay(for date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    /// Start and close define the active interval. Equal values mean always active.
    static func isWithinActiveWindow(
        at date: Date,
        startMinutes: Int,
        closeMinutes: Int,
        calendar: Calendar = .current
    ) -> Bool {
        let start = AppPreferences.normalizeMinutes(startMinutes)
        let close = AppPreferences.normalizeMinutes(closeMinutes)
        guard start != close else { return true }

        let current = minuteOfDay(for: date, calendar: calendar)
        if start < close {
            return current >= start && current < close
        }
        return current >= start || current < close
    }

    static func nextDate(
        for minutes: Int,
        after date: Date,
        calendar: Calendar = .current
    ) -> Date? {
        let normalized = AppPreferences.normalizeMinutes(minutes)
        var components = DateComponents()
        components.hour = normalized / 60
        components.minute = normalized % 60
        components.second = 0

        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward)
    }

    static func nextBoundary(
        after date: Date,
        startMinutes: Int,
        closeMinutes: Int,
        includesStart: Bool,
        calendar: Calendar = .current
    ) -> DailyScheduleBoundary? {
        var candidates: [DailyScheduleBoundary] = []
        if includesStart,
           let start = nextDate(for: startMinutes, after: date, calendar: calendar)
        {
            candidates.append(DailyScheduleBoundary(kind: .start, date: start))
        }
        if let close = nextDate(for: closeMinutes, after: date, calendar: calendar) {
            candidates.append(DailyScheduleBoundary(kind: .close, date: close))
        }
        return candidates.min(by: { $0.date < $1.date })
    }

    static func boundariesCrossed(
        from startDate: Date,
        through endDate: Date,
        startMinutes: Int,
        closeMinutes: Int,
        includesStart: Bool,
        calendar: Calendar = .current
    ) -> [DailyScheduleBoundary] {
        guard endDate >= startDate else { return [] }
        var result: [DailyScheduleBoundary] = []

        func appendOccurrences(kind: DailyScheduleBoundaryKind, minutes: Int) {
            var cursor = startDate
            // The wake interval should be short in practice; cap traversal to avoid
            // pathological loops after a very large wall-clock jump.
            for _ in 0..<370 {
                guard let occurrence = nextDate(
                    for: minutes, after: cursor, calendar: calendar),
                    occurrence <= endDate
                else { break }
                result.append(DailyScheduleBoundary(kind: kind, date: occurrence))
                cursor = occurrence.addingTimeInterval(1)
            }
        }

        if includesStart {
            appendOccurrences(kind: .start, minutes: startMinutes)
        }
        appendOccurrences(kind: .close, minutes: closeMinutes)
        return result.sorted(by: { $0.date < $1.date })
    }
}

@MainActor
final class DailyScheduleController {
    private let state: AppState
    private let preferences: AppPreferences
    private let requestQuit: @MainActor () -> Void
    private var timer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var workspaceTokens: [NSObjectProtocol] = []
    private var lastEvaluation = Date()
    private var executedKeys: Set<String> = []
    private var manualResumeUntil: Date?
    private var started = false

    init(
        state: AppState,
        preferences: AppPreferences,
        requestQuit: @escaping @MainActor () -> Void
    ) {
        self.state = state
        self.preferences = preferences
        self.requestQuit = requestQuit
    }

    func start() {
        guard !started else { return }
        started = true

        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: .appPreferencesChanged, object: preferences, queue: .main
        ) { [weak self] notification in
            guard let key = notification.userInfo?[AppPreferenceNotification.key]
                as? String,
                key.hasPrefix("dailySchedule")
            else { return }
            Task { @MainActor in self?.preferencesDidChange() }
        })

        for name in [
            Notification.Name.NSSystemClockDidChange,
            Notification.Name.NSSystemTimeZoneDidChange,
            Notification.Name.NSCalendarDayChanged,
        ] {
            notificationTokens.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.temporalContextChanged() }
            })
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        })

        lastEvaluation = Date()
        reconcileColdLaunch(at: lastEvaluation)
        scheduleNext(after: lastEvaluation)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceTokens.forEach(workspaceCenter.removeObserver)
        workspaceTokens.removeAll()
        started = false
    }

    func pauseManually() {
        manualResumeUntil = nil
        state.pauseDisplay(reason: .manual)
        scheduleNext(after: Date())
    }

    func resumeManually() {
        let now = Date()
        if preferences.scheduleEnabled,
           preferences.scheduleAction == .pauseDisplay
        {
            manualResumeUntil = DailyScheduleCalculator.nextDate(
                for: preferences.closeMinutes, after: now)
        } else {
            manualResumeUntil = nil
        }
        state.resumeDisplay()
        scheduleNext(after: now)
    }

    func preferencesDidChange() {
        guard started else { return }
        manualResumeUntil = nil
        let now = Date()

        if !preferences.scheduleEnabled {
            if state.pauseReason == .schedule {
                state.resumeDisplay()
            }
        } else if preferences.scheduleAction == .pauseDisplay {
            reconcilePauseState(at: now)
        } else if state.pauseReason == .schedule {
            state.resumeDisplay()
        }

        lastEvaluation = now
        scheduleNext(after: now)
    }

    var nextActionDescription: String {
        guard preferences.scheduleEnabled else { return "Off" }
        guard let boundary = nextBoundary(after: Date()) else { return "Unavailable" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        let action = boundary.kind == .start ? "Start" :
            (preferences.scheduleAction == .quitApp ? "Quit" : "Pause")
        return "\(action) \(formatter.string(from: boundary.date))"
    }

    private func reconcileColdLaunch(at now: Date) {
        guard preferences.scheduleEnabled,
              preferences.scheduleAction == .pauseDisplay,
              preferences.automaticStartEnabled
        else { return }
        reconcilePauseState(at: now)
    }

    private func reconcilePauseState(at now: Date) {
        guard preferences.scheduleEnabled,
              preferences.scheduleAction == .pauseDisplay,
              preferences.automaticStartEnabled
        else { return }

        if let override = manualResumeUntil, now < override {
            return
        }
        manualResumeUntil = nil

        let active = DailyScheduleCalculator.isWithinActiveWindow(
            at: now,
            startMinutes: preferences.startMinutes,
            closeMinutes: preferences.closeMinutes)
        if active {
            if state.pauseReason == .schedule {
                state.resumeDisplay()
            }
        } else if state.pauseReason == nil || state.pauseReason == .schedule {
            state.pauseDisplay(reason: .schedule)
        }
    }

    private func handleWake() {
        let now = Date()
        if now >= lastEvaluation {
            let crossed = DailyScheduleCalculator.boundariesCrossed(
                from: lastEvaluation,
                through: now,
                startMinutes: preferences.startMinutes,
                closeMinutes: preferences.closeMinutes,
                includesStart: includesStartBoundary)
            for boundary in crossed {
                execute(boundary)
            }
        }
        if preferences.scheduleAction == .pauseDisplay {
            reconcilePauseState(at: now)
        }
        lastEvaluation = now
        scheduleNext(after: now)
    }

    private func temporalContextChanged() {
        let now = Date()
        if preferences.scheduleAction == .pauseDisplay {
            reconcilePauseState(at: now)
        }
        lastEvaluation = now
        scheduleNext(after: now)
    }

    private var includesStartBoundary: Bool {
        preferences.scheduleAction == .pauseDisplay
            && preferences.automaticStartEnabled
    }

    private func nextBoundary(after date: Date) -> DailyScheduleBoundary? {
        guard preferences.scheduleEnabled else { return nil }
        return DailyScheduleCalculator.nextBoundary(
            after: date,
            startMinutes: preferences.startMinutes,
            closeMinutes: preferences.closeMinutes,
            includesStart: includesStartBoundary)
    }

    private func scheduleNext(after date: Date) {
        timer?.invalidate()
        timer = nil
        guard let boundary = nextBoundary(after: date) else { return }

        let timer = Timer(fire: boundary.date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.execute(boundary)
                self.lastEvaluation = Date()
                self.scheduleNext(after: self.lastEvaluation)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func execute(_ boundary: DailyScheduleBoundary) {
        guard preferences.scheduleEnabled else { return }
        let key = executionKey(for: boundary)
        guard executedKeys.insert(key).inserted else { return }

        switch boundary.kind {
        case .start:
            guard preferences.scheduleAction == .pauseDisplay,
                  preferences.automaticStartEnabled
            else { return }
            if state.pauseReason == .schedule {
                state.resumeDisplay()
            }

        case .close:
            manualResumeUntil = nil
            if preferences.scheduleAction == .quitApp {
                requestQuit()
            } else if state.pauseReason != .manual {
                state.pauseDisplay(reason: .schedule)
            }
        }
    }

    private func executionKey(for boundary: DailyScheduleBoundary) -> String {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day], from: boundary.date)
        return "\(boundary.kind.rawValue)-\(components.year ?? 0)-\(components.month ?? 0)-\(components.day ?? 0)"
    }
}
