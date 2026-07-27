// SettingsView.swift — packaged menu-bar app settings

import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState
    @Bindable var preferences: AppPreferences
    @Bindable var launchAtLogin: LaunchAtLoginController
    let pauseDisplay: () -> Void
    let resumeDisplay: () -> Void

    init(
        state: AppState,
        launchAtLogin: LaunchAtLoginController,
        pauseDisplay: @escaping () -> Void,
        resumeDisplay: @escaping () -> Void
    ) {
        self.state = state
        preferences = state.preferences
        self.launchAtLogin = launchAtLogin
        self.pauseDisplay = pauseDisplay
        self.resumeDisplay = resumeDisplay
    }

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                generalSettings
            }

            Tab("Display", systemImage: "display") {
                displaySettings
            }

            Tab("Device", systemImage: "cable.connector") {
                deviceSettings
            }

            Tab("About", systemImage: "info.circle") {
                aboutView
            }
        }
        .frame(width: 560, height: 620)
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

            Section("Refresh") {
                Picker("Idle interval", selection: $preferences.refreshInterval) {
                    Text("0.5s (default)").tag(0.5)
                    Text("1.0s").tag(1.0)
                    Text("2.0s").tag(2.0)
                }
                .onChange(of: preferences.refreshInterval) {
                    state.applySettings()
                }
                Text("Animations temporarily use a higher adaptive frame rate.")
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
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.4.0"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "140"
    }

    private func openLoginItemsSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
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

/// Deterministic documentation rendering of the controls exposed by the
/// native NSStatusItem menu. The production app continues to use NSMenu.
struct MenuDocumentationView: View {
    var body: some View {
        ZStack {
            SwiftUI.Color(nsColor: .windowBackgroundColor)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MacTR v1.4.0")
                            .font(.headline)
                        Text("Next: Pause today at 23:00")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "display")
                        .font(.title2)
                        .foregroundStyle(.cyan)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 15)

                Divider()
                menuRow("Active · 1920×480", icon: "circle.fill", color: .green)
                Divider().padding(.horizontal, 12)
                menuRow("Pause Display Output", icon: "pause.circle")
                menuRow("Preview Window", icon: "rectangle.on.rectangle")

                Divider().padding(.horizontal, 12)
                menuRow("Launch at Login", icon: "power", trailing: "✓")

                VStack(alignment: .leading, spacing: 9) {
                    Label("Daily Schedule", systemImage: "clock")
                        .font(.headline)

                    scheduleRow("Enabled", value: "✓")
                    scheduleRow("At close time", value: "Pause output")
                    scheduleRow("Resume automatically", value: "✓")
                    scheduleRow("Resume", value: "08:00")
                    scheduleRow("Close", value: "23:00")

                    HStack {
                        Image(systemName: "slider.horizontal.3")
                        Text("Edit Times…")
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.cyan)
                    .padding(.top, 3)
                }
                .padding(14)
                .background(
                    SwiftUI.Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

                menuRow("Settings…", icon: "gearshape")
                Divider().padding(.horizontal, 12)
                menuRow("View Latest Release…", icon: "arrow.down.circle")
                menuRow("About MacTR", icon: "info.circle")
                Divider().padding(.horizontal, 12)
                menuRow("Quit MacTR", icon: "xmark.circle")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(SwiftUI.Color.white.opacity(0.12), lineWidth: 1))
        .padding(8)
    }

    private func menuRow(
        _ title: String,
        icon: String,
        color: SwiftUI.Color = .primary,
        trailing: String? = nil
    ) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .frame(width: 20)
                .foregroundStyle(color)
            Text(title)
            Spacer()
            if let trailing {
                Text(trailing)
                    .foregroundStyle(.cyan)
                    .fontWeight(.semibold)
            }
        }
        .font(.callout)
        .padding(.horizontal, 18)
        .frame(height: 38)
    }

    private func scheduleRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.caption)
    }
}
