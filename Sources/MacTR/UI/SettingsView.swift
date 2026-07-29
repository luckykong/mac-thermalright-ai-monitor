// SettingsView.swift — packaged menu-bar app settings

import AppKit
import SwiftUI

enum SettingsTab: Hashable {
    case general
    case display
    case customCard
    case device
    case about
}

struct SettingsView: View {
    @Bindable var state: AppState
    @Bindable var preferences: AppPreferences
    @Bindable var launchAtLogin: LaunchAtLoginController
    @State private var selectedTab: SettingsTab
    let pauseDisplay: () -> Void
    let resumeDisplay: () -> Void

    init(
        state: AppState,
        launchAtLogin: LaunchAtLoginController,
        pauseDisplay: @escaping () -> Void,
        resumeDisplay: @escaping () -> Void,
        initialTab: SettingsTab = .general
    ) {
        self.state = state
        preferences = state.preferences
        self.launchAtLogin = launchAtLogin
        _selectedTab = State(initialValue: initialTab)
        self.pauseDisplay = pauseDisplay
        self.resumeDisplay = resumeDisplay
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab(t(.general), systemImage: "gearshape", value: SettingsTab.general) {
                generalSettings
            }

            Tab(t(.display), systemImage: "display", value: SettingsTab.display) {
                displaySettings
            }

            Tab(t(.customCard), systemImage: "terminal", value: SettingsTab.customCard) {
                customCardSettings
            }

            Tab(t(.device), systemImage: "cable.connector", value: SettingsTab.device) {
                deviceSettings
            }

            Tab(t(.about), systemImage: "info.circle", value: SettingsTab.about) {
                aboutView
            }
        }
        .frame(width: 580, height: 760)
        .environment(\.locale, preferences.language.locale)
    }

    // MARK: - General

    private var generalSettings: some View {
        Form {
            Section(t(.language)) {
                Picker(t(.interfaceLanguage), selection: $preferences.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: preferences.language) {
                    state.applySettings()
                }

                Text(t(.languageChangeHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(t(.startupAndBackground)) {
                Toggle(t(.launchAtLogin), isOn: launchAtLoginBinding)
                    .disabled(!launchAtLogin.isAvailable)

                if launchAtLogin.requiresApproval {
                    HStack {
                        Text(t(.loginApprovalRequired))
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(t(.openSystemSettings)) {
                            openLoginItemsSettings()
                        }
                    }
                } else if let message = launchAtLogin.localizedErrorMessage(
                    language: preferences.language)
                {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !launchAtLogin.isAvailable {
                    Text(t(.packagedAppOnly))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent(t(.backgroundMode)) {
                    Text(t(.menuBar))
                        .foregroundStyle(.secondary)
                }
                Text(t(.backgroundBehaviorHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    t(.autoShowPreview),
                    isOn: $preferences.autoShowPreviewWhenDisconnected)
            }

            Section(t(.dailySchedule)) {
                Toggle(t(.enableDailySchedule), isOn: $preferences.scheduleEnabled)

                Picker(t(.atCloseTime), selection: $preferences.scheduleAction) {
                    ForEach(ScheduleCloseAction.allCases) { action in
                        Text(action.title(language: preferences.language)).tag(action)
                    }
                }
                .disabled(!preferences.scheduleEnabled)

                DatePicker(
                    t(.closeTime),
                    selection: closeTimeBinding,
                    displayedComponents: .hourAndMinute)
                    .disabled(!preferences.scheduleEnabled)

                if preferences.scheduleAction == .pauseDisplay {
                    Toggle(
                        t(.resumeAutomatically),
                        isOn: $preferences.automaticStartEnabled)
                        .disabled(!preferences.scheduleEnabled)

                    DatePicker(
                        t(.resumeTime),
                        selection: startTimeBinding,
                        displayedComponents: .hourAndMinute)
                        .disabled(
                            !preferences.scheduleEnabled
                                || !preferences.automaticStartEnabled)
                } else {
                    Text(t(.quitCannotResume))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(scheduleDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(t(.performance)) {
                Picker(t(.mode), selection: $preferences.performanceMode) {
                    ForEach(PerformanceMode.allCases) { mode in
                        Text(mode.title(language: preferences.language)).tag(mode)
                    }
                }
                .onChange(of: preferences.performanceMode) {
                    state.applySettings()
                }
                Text(preferences.performanceMode.detail(language: preferences.language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(t(.balancedHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Display

    private var displaySettings: some View {
        Form {
            Section(t(.displaySet)) {
                Picker(t(.activeSet), selection: $preferences.currentSet) {
                    ForEach(DisplaySet.allCases) { set in
                        Text(set.title(language: preferences.language)).tag(set)
                    }
                }
                .onChange(of: preferences.currentSet) {
                    state.applySettings()
                }
            }

            Section(t(.brightness)) {
                HStack {
                    Slider(value: brightnessBinding, in: 1...10, step: 1) {
                        Text(t(.level))
                    }
                    Text("\(preferences.brightness)")
                        .monospacedDigit()
                        .frame(width: 24)
                }
                .onChange(of: preferences.brightness) {
                    state.applySettings()
                }
                Text(t(.brightnessHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(t(.rotation)) {
                Toggle(t(.rotate180), isOn: $preferences.rotateDisplay)
                    .onChange(of: preferences.rotateDisplay) {
                        state.applySettings()
                    }
                Text(t(.rotationHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(t(.agentTokenUsage)) {
                Toggle(t(.countCachedTokens), isOn: $preferences.countCachedTokens)
                    .onChange(of: preferences.countCachedTokens) {
                        state.applySettings()
                    }
                Text(t(.countCachedTokensHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Custom Card

    private var customCardSettings: some View {
        Form {
            Section(t(.customScriptCard)) {
                Toggle(t(.showCustomScriptOutput), isOn: $preferences.customScriptEnabled)
                    .onChange(of: preferences.customScriptEnabled) {
                        state.applySettings()
                    }

                LabeledContent(t(.script)) {
                    HStack {
                        Text(preferences.customScriptPath.isEmpty
                             ? t(.notSelected)
                             : preferences.customScriptPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(
                                preferences.customScriptPath.isEmpty
                                    ? .secondary : .primary)
                            .frame(maxWidth: 300, alignment: .trailing)
                        Button(t(.choose)) {
                            chooseCustomScript()
                        }
                    }
                }

                if !preferences.customScriptPath.isEmpty {
                    Button(t(.clearScript), role: .destructive) {
                        preferences.customScriptPath = ""
                        state.applySettings()
                    }
                }

                TextField(t(.cardName), text: $preferences.customScriptDisplayName)
                    .onChange(of: preferences.customScriptDisplayName) {
                        state.applySettings()
                    }

                HStack {
                    Text(t(.runEvery))
                    Spacer()
                    TextField(
                        "",
                        value: $preferences.customScriptIntervalSeconds,
                        format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .onSubmit {
                            state.applySettings()
                        }
                    Text(t(.seconds))
                        .foregroundStyle(.secondary)
                }
                Text(t(.scriptIntervalHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent(t(.scriptFontSize)) {
                    Picker("", selection: $preferences.customScriptFontMode) {
                        ForEach(CustomScriptFontMode.allCases) { mode in
                            Text(mode.title(language: preferences.language)).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                    .onChange(of: preferences.customScriptFontMode) {
                        state.applySettings()
                    }
                }
                Text(t(.scriptFontSizeHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(t(.testAndStatus)) {
                LabeledContent(t(.state)) {
                    HStack {
                        Circle()
                            .fill(scriptStatusColor)
                            .frame(width: 8, height: 8)
                        Text(scriptStatusText)
                    }
                }

                Button(t(.runNow)) {
                    state.applySettings()
                    state.runCustomScriptNow()
                }
                .disabled(
                    !preferences.customScriptEnabled
                        || preferences.customScriptPath.isEmpty)

                if !state.customScriptSnapshot.output.isEmpty {
                    ScrollView {
                        Text(state.customScriptSnapshot.output)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 90, maxHeight: 150)
                }

                if let message = state.customScriptSnapshot.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(
                            state.customScriptSnapshot.state == .running
                                ? SwiftUI.Color(nsColor: .secondaryLabelColor)
                                : SwiftUI.Color.red)
                }
            }

            Section(t(.executionRules)) {
                Text(t(.shellExecutionRule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(t(.scriptSecurityRule))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Device

    private var deviceSettings: some View {
        Form {
            Section(t(.output)) {
                LabeledContent(t(.state)) {
                    HStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(state.localizedStatusMessage)
                    }
                }

                if state.isPaused {
                    Button(t(.resumeDisplayOutput)) {
                        resumeDisplay()
                    }
                } else {
                    Button(t(.pauseDisplayOutput)) {
                        pauseDisplay()
                    }
                }
            }

            Section(t(.connection)) {
                if let info = state.deviceInfo {
                    LabeledContent(t(.resolution), value: "\(info.width) × \(info.height)")
                    LabeledContent("PM / SUB / FBL", value: "\(info.pm) / \(info.sub) / \(info.fbl)")
                    LabeledContent("PID", value: String(format: "0x%04X", info.pid))
                }

                if !state.isConnected && !state.isPaused {
                    Button(t(.reconnect)) {
                        state.connect()
                    }
                }
            }

            Section(t(.statistics)) {
                LabeledContent(t(.framesSent), value: "\(state.frameCount)")
                LabeledContent(t(.lastFrame), value: "\(state.lastFrameSize / 1024) KB")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - About

    private var aboutView: some View {
        VStack(spacing: 12) {
            Image(systemName: "display.2")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("MacTR")
                .font(.title)
                .fontWeight(.semibold)

            Text("\(t(.version)) \(appVersion) (\(appBuild))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(t(.appDescription))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Divider().frame(width: 240)

            Text(t(.builtWith))
                .font(.caption)
                .foregroundStyle(.secondary)

            Link(
                t(.githubReleases),
                destination: URL(
                    string: "https://github.com/luckykong/mac-thermalright-ai-monitor/releases")!)

            Spacer()
        }
        .padding(28)
    }

    // MARK: - Bindings & Helpers

    private func t(_ key: L10nKey) -> String {
        preferences.language.text(key)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin.isEnabled },
            set: { launchAtLogin.setEnabled($0) })
    }

    private var brightnessBinding: Binding<Double> {
        Binding(
            get: { Double(preferences.brightness) },
            set: { preferences.brightness = Int($0) })
    }

    private var startTimeBinding: Binding<Date> {
        timeBinding(
            get: { preferences.startMinutes },
            set: { preferences.startMinutes = $0 })
    }

    private var closeTimeBinding: Binding<Date> {
        timeBinding(
            get: { preferences.closeMinutes },
            set: { preferences.closeMinutes = $0 })
    }

    private func timeBinding(
        get: @escaping () -> Int,
        set: @escaping (Int) -> Void
    ) -> Binding<Date> {
        Binding(
            get: {
                let minutes = AppPreferences.normalizeMinutes(get())
                var components = Calendar.current.dateComponents(
                    [.year, .month, .day], from: Date())
                components.hour = minutes / 60
                components.minute = minutes % 60
                components.second = 0
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                set((components.hour ?? 0) * 60 + (components.minute ?? 0))
            })
    }

    private var scheduleDescription: String {
        guard preferences.scheduleEnabled else {
            return t(.scheduleDisabledDescription)
        }
        let close = AppPreferences.formattedTime(minutes: preferences.closeMinutes)
        if preferences.scheduleAction == .quitApp {
            return AppLocalization.format(
                .scheduleQuitDescription,
                language: preferences.language,
                close)
        }
        guard preferences.automaticStartEnabled else {
            return AppLocalization.format(
                .schedulePauseDescription,
                language: preferences.language,
                close)
        }
        let start = AppPreferences.formattedTime(minutes: preferences.startMinutes)
        return AppLocalization.format(
            .scheduleActiveDescription,
            language: preferences.language,
            start,
            close)
    }

    private var statusColor: SwiftUI.Color {
        if state.isPaused { return SwiftUI.Color.orange }
        if state.isConnected { return SwiftUI.Color.green }
        if case .error = state.runtimeState { return SwiftUI.Color.red }
        return SwiftUI.Color(nsColor: .secondaryLabelColor)
    }

    private var appVersion: String { AppVersion.short }

    private var appBuild: String { AppVersion.build }

    private func openLoginItemsSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private var scriptStatusText: String {
        switch state.customScriptSnapshot.state {
        case .disabled: t(.scriptDisabled)
        case .unconfigured: t(.scriptChoose)
        case .ready: t(.scriptReady)
        case .running: t(.scriptRunning)
        case .succeeded: t(.scriptSucceeded)
        case .failed: t(.scriptFailed)
        case .timedOut: t(.scriptTimedOut)
        case .missing: t(.scriptMissing)
        case .invalid: t(.scriptInvalid)
        }
    }

    private var scriptStatusColor: SwiftUI.Color {
        switch state.customScriptSnapshot.state {
        case .succeeded: .green
        case .running: .cyan
        case .failed, .timedOut, .missing, .invalid: .red
        case .unconfigured: .orange
        case .disabled, .ready: SwiftUI.Color(nsColor: .secondaryLabelColor)
        }
    }

    private func chooseCustomScript() {
        let panel = NSOpenPanel()
        panel.title = t(.chooseScriptTitle)
        panel.prompt = t(.choose)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.customScriptPath = url.path
        if preferences.customScriptDisplayName.isEmpty {
            preferences.customScriptDisplayName =
                url.deletingPathExtension().lastPathComponent
        }
        state.applySettings()
    }
}

struct ScheduleTimeEditorView: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        Form {
            Toggle(t(.enableDailySchedule), isOn: $preferences.scheduleEnabled)

            Picker(t(.closeAction), selection: $preferences.scheduleAction) {
                ForEach(ScheduleCloseAction.allCases) { action in
                    Text(action.title(language: preferences.language)).tag(action)
                }
            }

            DatePicker(
                t(.close),
                selection: timeBinding(isStart: false),
                displayedComponents: .hourAndMinute)

            if preferences.scheduleAction == .pauseDisplay {
                Toggle(t(.automaticResume), isOn: $preferences.automaticStartEnabled)
                DatePicker(
                    t(.resume),
                    selection: timeBinding(isStart: true),
                    displayedComponents: .hourAndMinute)
                    .disabled(!preferences.automaticStartEnabled)
            } else {
                Text(t(.scheduledResumeUnavailable))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 360, height: 260)
        .environment(\.locale, preferences.language.locale)
    }

    private func t(_ key: L10nKey) -> String {
        preferences.language.text(key)
    }

    private func timeBinding(isStart: Bool) -> Binding<Date> {
        Binding(
            get: {
                let minutes = isStart
                    ? preferences.startMinutes : preferences.closeMinutes
                var components = Calendar.current.dateComponents(
                    [.year, .month, .day], from: Date())
                components.hour = minutes / 60
                components.minute = minutes % 60
                components.second = 0
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                let value = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                if isStart {
                    preferences.startMinutes = value
                } else {
                    preferences.closeMinutes = value
                }
            })
    }
}
