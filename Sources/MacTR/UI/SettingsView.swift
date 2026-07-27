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
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                generalSettings
            }

            Tab("Display", systemImage: "display", value: SettingsTab.display) {
                displaySettings
            }

            Tab("Custom Card", systemImage: "terminal", value: SettingsTab.customCard) {
                customCardSettings
            }

            Tab("Device", systemImage: "cable.connector", value: SettingsTab.device) {
                deviceSettings
            }

            Tab("About", systemImage: "info.circle", value: SettingsTab.about) {
                aboutView
            }
        }
        .frame(width: 580, height: 760)
    }

    // MARK: - General

    private var generalSettings: some View {
        Form {
            Section("Startup & Background") {
                Toggle("Launch at Login", isOn: launchAtLoginBinding)
                    .disabled(!launchAtLogin.isAvailable)

                if launchAtLogin.requiresApproval {
                    HStack {
                        Text("Approval is required in System Settings → Login Items.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open System Settings") {
                            openLoginItemsSettings()
                        }
                    }
                } else if let message = launchAtLogin.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if !launchAtLogin.isAvailable {
                    Text("Available when running the packaged MacTR.app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Background mode") {
                    Text("Menu bar")
                        .foregroundStyle(.secondary)
                }
                Text("Closing Settings or Preview keeps MacTR running. Use Quit MacTR in the menu to stop it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Show Preview automatically when the LCD is disconnected",
                    isOn: $preferences.autoShowPreviewWhenDisconnected)
            }

            Section("Daily Schedule") {
                Toggle("Enable daily schedule", isOn: $preferences.scheduleEnabled)

                Picker("At close time", selection: $preferences.scheduleAction) {
                    ForEach(ScheduleCloseAction.allCases) { action in
                        Text(action.title).tag(action)
                    }
                }
                .disabled(!preferences.scheduleEnabled)

                DatePicker(
                    "Close time",
                    selection: closeTimeBinding,
                    displayedComponents: .hourAndMinute)
                    .disabled(!preferences.scheduleEnabled)

                if preferences.scheduleAction == .pauseDisplay {
                    Toggle(
                        "Resume output automatically",
                        isOn: $preferences.automaticStartEnabled)
                        .disabled(!preferences.scheduleEnabled)

                    DatePicker(
                        "Resume time",
                        selection: startTimeBinding,
                        displayedComponents: .hourAndMinute)
                        .disabled(
                            !preferences.scheduleEnabled
                                || !preferences.automaticStartEnabled)
                } else {
                    Text("A quit app cannot start itself later. Reopen MacTR manually or enable Launch at Login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(scheduleDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Performance") {
                Picker("Mode", selection: $preferences.performanceMode) {
                    ForEach(PerformanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .onChange(of: preferences.performanceMode) {
                    state.applySettings()
                }
                Text(preferences.performanceMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Balanced lowers animation and metric cadence without removing any dashboard data.")
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
            Section("Display Set") {
                Picker("Active Set", selection: $preferences.currentSet) {
                    ForEach(DisplaySet.allCases) { set in
                        Text(set.rawValue).tag(set)
                    }
                }
                .onChange(of: preferences.currentSet) {
                    state.applySettings()
                }
            }

            Section("Brightness") {
                HStack {
                    Slider(value: brightnessBinding, in: 1...10, step: 1) {
                        Text("Level")
                    }
                    Text("\(preferences.brightness)")
                        .monospacedDigit()
                        .frame(width: 24)
                }
                .onChange(of: preferences.brightness) {
                    state.applySettings()
                }
                Text("1 = original, 10 = maximum")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Rotation") {
                Toggle("Rotate 180°", isOn: $preferences.rotateDisplay)
                    .onChange(of: preferences.rotateDisplay) {
                        state.applySettings()
                    }
                Text("Enable if the physical display appears upside down.")
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
            Section("Custom Script Card") {
                Toggle("Show custom script output", isOn: $preferences.customScriptEnabled)
                    .onChange(of: preferences.customScriptEnabled) {
                        state.applySettings()
                    }

                LabeledContent("Script") {
                    HStack {
                        Text(preferences.customScriptPath.isEmpty
                             ? "Not selected"
                             : preferences.customScriptPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(
                                preferences.customScriptPath.isEmpty
                                    ? .secondary : .primary)
                            .frame(maxWidth: 300, alignment: .trailing)
                        Button("Choose…") {
                            chooseCustomScript()
                        }
                    }
                }

                if !preferences.customScriptPath.isEmpty {
                    Button("Clear Script", role: .destructive) {
                        preferences.customScriptPath = ""
                        state.applySettings()
                    }
                }

                TextField("Card name", text: $preferences.customScriptDisplayName)
                    .onChange(of: preferences.customScriptDisplayName) {
                        state.applySettings()
                    }

                HStack {
                    Text("Run every")
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
                    Text("seconds")
                        .foregroundStyle(.secondary)
                }
                Text("Allowed range: 5 seconds to 24 hours. Runs never overlap and time out automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Test & Status") {
                LabeledContent("State") {
                    HStack {
                        Circle()
                            .fill(scriptStatusColor)
                            .frame(width: 8, height: 8)
                        Text(scriptStatusText)
                    }
                }

                Button("Run Now") {
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

            Section("Execution Rules") {
                Text("Shell files (.sh, .zsh and .command) run with the system /bin/zsh. Other files must be executable and include a valid shebang. MacTR passes the selected path directly and never evaluates a command string.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The script runs as the current user without administrator privileges. stdout and stderr are capped at 8 KB; ANSI control sequences are removed.")
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
            Section("Output") {
                LabeledContent("State") {
                    HStack {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(state.statusMessage)
                    }
                }

                if state.isPaused {
                    Button("Resume Display Output") {
                        resumeDisplay()
                    }
                } else {
                    Button("Pause Display Output") {
                        pauseDisplay()
                    }
                }
            }

            Section("Connection") {
                if let info = state.deviceInfo {
                    LabeledContent("Resolution", value: "\(info.width) × \(info.height)")
                    LabeledContent("PM / SUB / FBL", value: "\(info.pm) / \(info.sub) / \(info.fbl)")
                    LabeledContent("PID", value: String(format: "0x%04X", info.pid))
                }

                if !state.isConnected && !state.isPaused {
                    Button("Reconnect") {
                        state.connect()
                    }
                }
            }

            Section("Statistics") {
                LabeledContent("Frames Sent", value: "\(state.frameCount)")
                LabeledContent("Last Frame", value: "\(state.lastFrameSize / 1024) KB")
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

            Text("Version \(appVersion) (\(appBuild))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("AI agent and system monitor for the Thermalright Trofeo Vision 9.16 LCD")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Divider().frame(width: 240)

            Text("Built with Swift and libusb")
                .font(.caption)
                .foregroundStyle(.secondary)

            Link(
                "GitHub Releases",
                destination: URL(
                    string: "https://github.com/luckykong/mac-thermalright-ai-monitor/releases")!)

            Spacer()
        }
        .padding(28)
    }

    // MARK: - Bindings & Helpers

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
            return "The schedule is disabled."
        }
        let close = AppPreferences.formattedTime(minutes: preferences.closeMinutes)
        if preferences.scheduleAction == .quitApp {
            return "MacTR quits every day at \(close)."
        }
        guard preferences.automaticStartEnabled else {
            return "Display output pauses every day at \(close) and resumes manually."
        }
        let start = AppPreferences.formattedTime(minutes: preferences.startMinutes)
        return "Display output runs daily from \(start) to \(close). Overnight ranges are supported."
    }

    private var statusColor: SwiftUI.Color {
        if state.isPaused { return SwiftUI.Color.orange }
        if state.isConnected { return SwiftUI.Color.green }
        if case .error = state.runtimeState { return SwiftUI.Color.red }
        return SwiftUI.Color(nsColor: .secondaryLabelColor)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.4.1"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "141"
    }

    private func openLoginItemsSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private var scriptStatusText: String {
        switch state.customScriptSnapshot.state {
        case .disabled: "Disabled"
        case .unconfigured: "Choose a script"
        case .ready: "Ready"
        case .running: "Running"
        case .succeeded: "Last run succeeded"
        case .failed: "Last run failed"
        case .timedOut: "Timed out"
        case .missing: "File not found"
        case .invalid: "Invalid script"
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
        panel.title = "Choose a Script for the Custom Card"
        panel.prompt = "Choose"
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
            Toggle("Enable daily schedule", isOn: $preferences.scheduleEnabled)

            Picker("Close action", selection: $preferences.scheduleAction) {
                ForEach(ScheduleCloseAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }

            DatePicker(
                "Close",
                selection: timeBinding(isStart: false),
                displayedComponents: .hourAndMinute)

            if preferences.scheduleAction == .pauseDisplay {
                Toggle("Automatic resume", isOn: $preferences.automaticStartEnabled)
                DatePicker(
                    "Resume",
                    selection: timeBinding(isStart: true),
                    displayedComponents: .hourAndMinute)
                    .disabled(!preferences.automaticStartEnabled)
            } else {
                Text("Scheduled resume is unavailable after quitting the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 360, height: 260)
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
