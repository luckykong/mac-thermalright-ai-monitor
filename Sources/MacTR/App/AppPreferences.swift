// AppPreferences.swift — persistent user-facing application settings

import Foundation
import Observation

extension Notification.Name {
    static let appPreferencesChanged = Notification.Name("appPreferencesChanged")
}

enum AppPreferenceNotification {
    static let key = "preferenceKey"
    static let languageKey = "appLanguage"
}

enum ScheduleCloseAction: String, CaseIterable, Identifiable, Sendable {
    case pauseDisplay
    case quitApp

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .pauseDisplay: language.text(.pauseDisplayOutput)
        case .quitApp: language.text(.quitMacTR)
        }
    }
}

enum PerformanceMode: String, CaseIterable, Identifiable, Sendable {
    case eco
    case balanced
    case smooth

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .eco: language.text(.eco)
        case .balanced: language.text(.balanced)
        case .smooth: language.text(.smooth)
        }
    }

    func detail(language: AppLanguage) -> String {
        switch self {
        case .eco: language.text(.ecoDetail)
        case .balanced: language.text(.balancedDetail)
        case .smooth: language.text(.smoothDetail)
        }
    }

    var idleFrameInterval: Double {
        switch self {
        case .eco: 2.0
        case .balanced: 1.0
        case .smooth: 0.5
        }
    }

    var activeFramesPerSecond: Double {
        switch self {
        case .eco: 2
        case .balanced: 4
        case .smooth: 10
        }
    }

    var fanFramesPerSecond: Double {
        switch self {
        case .eco: 1
        case .balanced: 2
        case .smooth: 6
        }
    }

    var fastMetricsInterval: Double {
        switch self {
        case .eco: 2
        case .balanced: 1
        case .smooth: 0.5
        }
    }

    var slowMetricsInterval: Double {
        switch self {
        case .eco: 6
        case .balanced: 3
        case .smooth: 2
        }
    }

    var agentMetricsInterval: Double {
        switch self {
        case .eco: 8
        case .balanced: 4
        case .smooth: 2
        }
    }
}

enum CustomScriptFontMode: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case small
    case medium
    case large

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .automatic: language.text(.fontAutomatic)
        case .small: language.text(.fontSmall)
        case .medium: language.text(.fontMedium)
        case .large: language.text(.fontLarge)
        }
    }
}

@Observable
@MainActor
final class AppPreferences {
    private enum Key {
        static let language = AppPreferenceNotification.languageKey
        static let displaySet = "displaySet"
        static let brightness = "brightness"
        static let refreshInterval = "refreshInterval"
        static let performanceMode = "performanceMode"
        static let rotateDisplay = "rotateDisplay"
        static let autoShowPreview = "autoShowPreviewWhenDisconnected"
        static let scheduleEnabled = "dailyScheduleEnabled"
        static let scheduleAction = "dailyScheduleAction"
        static let automaticStartEnabled = "dailyScheduleAutomaticStartEnabled"
        static let startMinutes = "dailyScheduleStartMinutes"
        static let closeMinutes = "dailyScheduleCloseMinutes"
        static let customScriptEnabled = "customScriptEnabled"
        static let customScriptPath = "customScriptPath"
        static let customScriptDisplayName = "customScriptDisplayName"
        static let customScriptIntervalSeconds = "customScriptIntervalSeconds"
        static let customScriptFontMode = "customScriptFontMode"
        static let countCachedTokens = "countCachedTokens"
    }

    private let defaults: UserDefaults

    var language: AppLanguage {
        didSet { save(language.rawValue, forKey: Key.language) }
    }

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

    var performanceMode: PerformanceMode {
        didSet {
            save(performanceMode.rawValue, forKey: Key.performanceMode)
            defaults.set(performanceMode.idleFrameInterval, forKey: Key.refreshInterval)
        }
    }

    /// Compatibility bridge for v1.4.0 settings/tests. New UI uses `performanceMode`.
    var refreshInterval: Double {
        get { performanceMode.idleFrameInterval }
        set {
            performanceMode = if newValue >= 1.5 {
                .eco
            } else if newValue <= 0.6 {
                .smooth
            } else {
                .balanced
            }
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

    var customScriptEnabled: Bool {
        didSet { save(customScriptEnabled, forKey: Key.customScriptEnabled) }
    }

    var customScriptPath: String {
        didSet { save(customScriptPath, forKey: Key.customScriptPath) }
    }

    var customScriptDisplayName: String {
        didSet {
            let normalized = customScriptDisplayName
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let capped = String(normalized.prefix(32))
            if customScriptDisplayName != capped {
                customScriptDisplayName = capped
                return
            }
            save(customScriptDisplayName, forKey: Key.customScriptDisplayName)
        }
    }

    var customScriptIntervalSeconds: Int {
        didSet {
            let clamped = min(max(customScriptIntervalSeconds, 5), 86_400)
            if customScriptIntervalSeconds != clamped {
                customScriptIntervalSeconds = clamped
                return
            }
            save(customScriptIntervalSeconds, forKey: Key.customScriptIntervalSeconds)
        }
    }

    var customScriptFontMode: CustomScriptFontMode {
        didSet { save(customScriptFontMode.rawValue, forKey: Key.customScriptFontMode) }
    }

    /// Whether the AGENTS card's token totals include context re-read from the
    /// prompt cache. Defaults to on so an upgrade does not silently redefine
    /// the number people have been watching; turning it off leaves only the
    /// content actually sent fresh, which is the smaller figure the CLIs show.
    var countCachedTokens: Bool {
        didSet { save(countCachedTokens, forKey: Key.countCachedTokens) }
    }

    var customScriptConfiguration: CustomScriptConfiguration {
        CustomScriptConfiguration(
            enabled: customScriptEnabled,
            path: customScriptPath,
            displayName: customScriptDisplayName,
            intervalSeconds: customScriptIntervalSeconds)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let rawLanguage = defaults.string(forKey: Key.language),
           let savedLanguage = AppLanguage(rawValue: rawLanguage)
        {
            language = savedLanguage
        } else {
            // MacTR intentionally defaults to Simplified Chinese regardless of
            // the system language. English remains one click away in Settings/menu.
            language = .simplifiedChinese
        }

        if let rawSet = defaults.string(forKey: Key.displaySet),
           let set = DisplaySet(rawValue: rawSet)
        {
            currentSet = set
        } else {
            currentSet = .systemMonitor
        }

        brightness = defaults.object(forKey: Key.brightness) == nil
            ? 5 : min(max(defaults.integer(forKey: Key.brightness), 1), 10)

        if let rawMode = defaults.string(forKey: Key.performanceMode),
           let mode = PerformanceMode(rawValue: rawMode)
        {
            performanceMode = mode
        } else {
            // v1.4.1 deliberately moves the default away from the old 15fps-heavy
            // behavior. Users can opt back into Smooth from Settings.
            performanceMode = .balanced
        }

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

        customScriptEnabled = defaults.bool(forKey: Key.customScriptEnabled)
        customScriptPath = defaults.string(forKey: Key.customScriptPath) ?? ""
        customScriptDisplayName =
            defaults.string(forKey: Key.customScriptDisplayName) ?? ""
        customScriptIntervalSeconds = min(
            max(
                defaults.object(forKey: Key.customScriptIntervalSeconds) == nil
                    ? 60 : defaults.integer(forKey: Key.customScriptIntervalSeconds),
                5),
            86_400)
        if let rawFontMode = defaults.string(forKey: Key.customScriptFontMode),
           let fontMode = CustomScriptFontMode(rawValue: rawFontMode)
        {
            customScriptFontMode = fontMode
        } else {
            customScriptFontMode = .automatic
        }

        countCachedTokens = defaults.object(forKey: Key.countCachedTokens) == nil
            ? true : defaults.bool(forKey: Key.countCachedTokens)
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
