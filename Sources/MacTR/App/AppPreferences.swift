// AppPreferences.swift — persistent user-facing application settings

import Foundation
import Observation

extension Notification.Name {
    static let appPreferencesChanged = Notification.Name("appPreferencesChanged")
}

enum AppPreferenceNotification {
    static let key = "preferenceKey"
}

enum ScheduleCloseAction: String, CaseIterable, Identifiable, Sendable {
    case pauseDisplay
    case quitApp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pauseDisplay: "Pause display output"
        case .quitApp: "Quit MacTR"
        }
    }
}

@Observable
@MainActor
final class AppPreferences {
    private enum Key {
        static let displaySet = "displaySet"
        static let brightness = "brightness"
        static let refreshInterval = "refreshInterval"
        static let rotateDisplay = "rotateDisplay"
        static let autoShowPreview = "autoShowPreviewWhenDisconnected"
        static let scheduleEnabled = "dailyScheduleEnabled"
        static let scheduleAction = "dailyScheduleAction"
        static let automaticStartEnabled = "dailyScheduleAutomaticStartEnabled"
        static let startMinutes = "dailyScheduleStartMinutes"
        static let closeMinutes = "dailyScheduleCloseMinutes"
    }

    private let defaults: UserDefaults

    var currentSet: DisplaySet {
        didSet { save(currentSet.rawValue, forKey: Key.displaySet) }
    }

    var brightness: Int {
        didSet {
            let clamped = min(max(brightness, 1), 10)
            if brightness != clamped {
                brightness = clamped
                return
            }
            save(brightness, forKey: Key.brightness)
        }
    }

    var refreshInterval: Double {
        didSet {
            let allowed = [0.5, 1.0, 2.0]
            let normalized = allowed.min(by: {
                abs($0 - refreshInterval) < abs($1 - refreshInterval)
            }) ?? 0.5
            if refreshInterval != normalized {
                refreshInterval = normalized
                return
            }
            save(refreshInterval, forKey: Key.refreshInterval)
        }
    }

    var rotateDisplay: Bool {
        didSet { save(rotateDisplay, forKey: Key.rotateDisplay) }
    }

    /// The packaged menu-bar app stays quiet when the USB LCD is absent by default.
    var autoShowPreviewWhenDisconnected: Bool {
        didSet { save(autoShowPreviewWhenDisconnected, forKey: Key.autoShowPreview) }
    }

    var scheduleEnabled: Bool {
        didSet { save(scheduleEnabled, forKey: Key.scheduleEnabled) }
    }

    var scheduleAction: ScheduleCloseAction {
        didSet { save(scheduleAction.rawValue, forKey: Key.scheduleAction) }
    }

    var automaticStartEnabled: Bool {
        didSet { save(automaticStartEnabled, forKey: Key.automaticStartEnabled) }
    }

    /// Minutes after midnight in the user's current calendar/time zone.
    var startMinutes: Int {
        didSet {
            let normalized = Self.normalizeMinutes(startMinutes)
            if startMinutes != normalized {
                startMinutes = normalized
                return
            }
            save(startMinutes, forKey: Key.startMinutes)
        }
    }

    /// Minutes after midnight in the user's current calendar/time zone.
    var closeMinutes: Int {
        didSet {
            let normalized = Self.normalizeMinutes(closeMinutes)
            if closeMinutes != normalized {
                closeMinutes = normalized
                return
            }
            save(closeMinutes, forKey: Key.closeMinutes)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let rawSet = defaults.string(forKey: Key.displaySet),
           let set = DisplaySet(rawValue: rawSet)
        {
            currentSet = set
        } else {
            currentSet = .systemMonitor
        }

        brightness = defaults.object(forKey: Key.brightness) == nil
            ? 5 : min(max(defaults.integer(forKey: Key.brightness), 1), 10)

        let storedInterval = defaults.object(forKey: Key.refreshInterval) == nil
            ? 0.5 : defaults.double(forKey: Key.refreshInterval)
        refreshInterval = [0.5, 1.0, 2.0].min(by: {
            abs($0 - storedInterval) < abs($1 - storedInterval)
        }) ?? 0.5

        rotateDisplay = defaults.bool(forKey: Key.rotateDisplay)
        autoShowPreviewWhenDisconnected = defaults.bool(forKey: Key.autoShowPreview)
        scheduleEnabled = defaults.bool(forKey: Key.scheduleEnabled)

        if let rawAction = defaults.string(forKey: Key.scheduleAction),
           let action = ScheduleCloseAction(rawValue: rawAction)
        {
            scheduleAction = action
        } else {
            scheduleAction = .pauseDisplay
        }

        automaticStartEnabled = defaults.object(forKey: Key.automaticStartEnabled) == nil
            ? true : defaults.bool(forKey: Key.automaticStartEnabled)
        startMinutes = Self.normalizeMinutes(
            defaults.object(forKey: Key.startMinutes) == nil
                ? 8 * 60 : defaults.integer(forKey: Key.startMinutes))
        closeMinutes = Self.normalizeMinutes(
            defaults.object(forKey: Key.closeMinutes) == nil
                ? 23 * 60 : defaults.integer(forKey: Key.closeMinutes))
    }

    nonisolated static func normalizeMinutes(_ value: Int) -> Int {
        let remainder = value % (24 * 60)
        return remainder >= 0 ? remainder : remainder + (24 * 60)
    }

    nonisolated static func formattedTime(minutes: Int) -> String {
        let normalized = normalizeMinutes(minutes)
        return String(format: "%02d:%02d", normalized / 60, normalized % 60)
    }

    private func save(_ value: Any, forKey key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(
            name: .appPreferencesChanged,
            object: self,
            userInfo: [AppPreferenceNotification.key: key])
    }
}
