// MacTRApp.swift — macOS menu bar app
//
// Uses NSStatusItem directly (not SwiftUI MenuBarExtra) for reliable
// menu bar icon that never disappears regardless of USB state.
//
// CLI mode: --cli flag for headless operation.

import AppKit
import os
import ScreenCaptureKit
import SwiftUI

private let mactrLogger = Logger(subsystem: "com.beret21.MacTR", category: "main")

/// True in the argument-driven console modes, where the user is watching a
/// terminal rather than the menu bar. os_log writes nothing to stdout/stderr,
/// so without this `--cli` ran completely silently.
let isConsoleMode: Bool = {
    let consoleFlags: Set<String> = [
        "--cli", "--benchmark", "--demo", "--gif", "--smc-test",
        "--snapshot", "--settings-snapshot", "--menu-snapshot",
    ]
    return CommandLine.arguments.contains { consoleFlags.contains($0) }
}()

/// Use `.notice`, not `.info`: info-level entries are not persisted to the log
/// store by default, so a running MacTR left nothing behind for `log show` to
/// retrieve after a problem.
func log(_ message: String) {
    mactrLogger.notice("\(message, privacy: .public)")
    if isConsoleMode {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Diagnostics worth having at a terminal but not worth writing to the log
/// store on every single reconnect — hex dumps and the like.
func logVerbose(_ message: String) {
    guard isConsoleMode else { return }
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// Version strings, read from the bundle Info.plist that packaging stamps.
/// Every call site used to carry its own hardcoded fallback copy of the
/// then-current version, so the numbers drifted apart between releases. The
/// fallbacks here are deliberately not real versions: seeing "dev" means the
/// bare SwiftPM binary is running outside an app bundle.
enum AppVersion {
    static var short: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
}

// MARK: - App Entry Point

@main
struct MacTREntry {
    static func main() {
        if CommandLine.arguments.contains("--smc-test") {
            runSMCTest()
            return
        }

        // CLI mode
        if CommandLine.arguments.contains("--cli") {
            runCLI()
            return
        }

        // Benchmark mode: measure achievable frame rate on the real LCD.
        if CommandLine.arguments.contains("--benchmark") {
            runBenchmark()
            return
        }

        // Showcase mode: drive the LCD with deterministic sample data.
        if CommandLine.arguments.contains("--demo") {
            runDemo()
            return
        }

        // GIF mode: render an animated demo GIF (for the README). No LCD needed.
        if CommandLine.arguments.contains("--gif") {
            runGif()
            return
        }

        // Documentation mode: render the real SwiftUI settings interface to PNG.
        if CommandLine.arguments.contains("--settings-snapshot") {
            runSettingsSnapshot()
            return
        }

        // Snapshot mode: render one frame and save as PNG
        // Usage: --snapshot path.png [--cores N] [--redact-agents]
        if CommandLine.arguments.contains("--snapshot") {
            let renderer = MonitorRenderer()
            renderer.configure(
                performanceMode: .balanced,
                customScript: .disabled,
                language: parseLanguage(CommandLine.arguments))
            let simCores = parseFlag(CommandLine.arguments, flag: "--cores")
            renderer.redactAgentDetails =
                CommandLine.arguments.contains("--redact-agents")

            // Prime metrics collection (required for real data render)
            renderer.startMetrics()
            Thread.sleep(forTimeInterval: 0.5)
            for _ in 0..<30 { _ = renderer.render(); Thread.sleep(forTimeInterval: 0.1) }

            let image: CGImage?
            if let cores = simCores {
                log("[Snapshot] Simulating \(cores) cores")
                image = renderer.renderSimulated(coreCount: cores)
            } else {
                image = renderer.render()
            }

            if let image {
                let snapshotIndex = CommandLine.arguments.firstIndex(of: "--snapshot")!
                let path = snapshotIndex + 1 < CommandLine.arguments.count
                    ? CommandLine.arguments[snapshotIndex + 1] : "snapshot.png"
                let url = URL(fileURLWithPath: path)
                if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, image, nil)
                    CGImageDestinationFinalize(dest)
                    log("[Snapshot] Saved to \(url.path)")
                }
            }
            renderer.stopMetrics()
            return
        }

        // Preview mode: live render in a window — no LCD hardware needed
        if CommandLine.arguments.contains("--preview") {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let delegate = PreviewController()
            app.delegate = delegate
            app.run()
            return
        }

        // GUI mode — NSApplication with StatusBar
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // No dock icon
        let delegate = StatusBarController()
        app.delegate = delegate
        app.run()
    }
}

private func runSMCTest() {
    let collector = SystemMetricsCollector()
    let snapshot = collector.collectFans()
    print("[SMC] available=\(snapshot.available) fans=\(snapshot.fans.count)")
    for fan in snapshot.fans {
        let maxValue = fan.maxRPM.map { String(format: "%.0f", $0) } ?? "N/A"
        print("[SMC] \(fan.name): \(String(format: "%.0f", fan.currentRPM)) RPM max=\(maxValue)")
    }
}

// MARK: - Settings Documentation Snapshot

@MainActor
private func runSettingsSnapshot() {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--settings-snapshot"),
          index + 1 < args.count
    else {
        print("[Settings Snapshot] usage: --settings-snapshot output.png")
        return
    }

    let suiteName = "com.beret21.MacTR.documentation"
    guard let defaults = UserDefaults(suiteName: suiteName) else { return }
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let preferences = AppPreferences(defaults: defaults)
    preferences.language = parseLanguage(args)
    preferences.scheduleEnabled = true
    preferences.scheduleAction = .pauseDisplay
    preferences.automaticStartEnabled = true
    preferences.startMinutes = 8 * 60
    preferences.closeMinutes = 23 * 60
    preferences.customScriptEnabled = true
    preferences.customScriptPath = "/Users/me/Scripts/backup-status.zsh"
    preferences.customScriptDisplayName = "BACKUP"
    preferences.customScriptIntervalSeconds = 60

    let state = AppState(preferences: preferences)
    state.setDocumentationCustomScriptSnapshot(CustomScriptSnapshot(
        state: .succeeded,
        title: "BACKUP",
        output: "STATUS  OK\nREPOS   12\nLAST    19:30\nNEXT    20:00",
        message: nil,
        lastRunAt: Date().addingTimeInterval(-30),
        exitCode: 0))
    let launchAtLogin = LaunchAtLoginController(availabilityOverride: true)
    let rootView = SettingsView(
        state: state,
        launchAtLogin: launchAtLogin,
        pauseDisplay: {},
        resumeDisplay: {},
        initialTab: args.contains("--settings-general") ? .general : .customCard)
        .preferredColorScheme(.dark)
        .background(SwiftUI.Color(nsColor: .windowBackgroundColor))

    let url = URL(fileURLWithPath: args[index + 1])
    if renderDocumentationView(
        rootView,
        size: NSSize(width: 580, height: 760),
        title: preferences.language.text(.settingsWindowTitle),
        outputURL: url)
    {
        print("[Settings Snapshot] wrote \(url.path)")
    } else {
        print("[Settings Snapshot] failed")
    }
}

@MainActor
private func renderDocumentationView<Content: View>(
    _ rootView: Content,
    size pointSize: NSSize,
    title: String,
    outputURL: URL
) -> Bool {
    let pixelScale = 2
    let hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = NSRect(origin: .zero, size: pointSize)

    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: pointSize),
        styleMask: [.titled],
        backing: .buffered,
        defer: false)
    window.title = title
    window.contentView = hostingView
    window.orderOut(nil)

    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    hostingView.layoutSubtreeIfNeeded()

    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pointSize.width) * pixelScale,
        pixelsHigh: Int(pointSize.height) * pixelScale,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0)
    else { return false }
    representation.size = pointSize
    hostingView.cacheDisplay(in: hostingView.bounds, to: representation)

    guard let png = representation.representation(using: .png, properties: [:]) else {
        return false
    }
    do {
        try png.write(to: outputURL)
        return true
    } catch {
        log("[Documentation] Snapshot failed: \(error.localizedDescription)")
        return false
    }
}

// MARK: - Preview Window (debug without LCD hardware)

@MainActor
final class PreviewController: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var window: NSWindow!
    private var imageView: NSImageView!
    private let renderer = MonitorRenderer()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("[Preview] Starting preview window (no LCD)")

        // Half-scale window keeps the 1920x480 frame readable on a laptop screen
        let contentSize = NSSize(width: Layout.width / 2, height: Layout.height / 2)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "\(AppLanguage.simplifiedChinese.text(.previewWindow)) — \(Layout.width)x\(Layout.height)"
        window.contentAspectRatio = NSSize(width: Layout.width, height: Layout.height)
        window.delegate = self

        imageView = NSImageView(frame: NSRect(origin: .zero, size: contentSize))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(imageView)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        renderer.startMetrics()
        if CommandLine.arguments.contains("--test-flash") {
            renderer.enableTestFlash(seconds: 10)
        }
        timer = Timer.scheduledTimer(
            timeInterval: 0.125,
            target: self,
            selector: #selector(refreshTimerFired),
            userInfo: nil,
            repeats: true)
        refresh()
    }

    @objc private func refreshTimerFired() {
        refresh()
    }

    private func refresh() {
        guard let image = renderer.render() else { return }
        imageView.image = NSImage(cgImage: image,
                                  size: NSSize(width: Layout.width, height: Layout.height))
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        renderer.stopMetrics()
        NSApp.terminate(nil)
    }
}

// MARK: - Status Bar Controller

@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem!
    private let preferences = AppPreferences()
    private lazy var appState = AppState(preferences: preferences)
    private let launchAtLogin = LaunchAtLoginController()
    private lazy var scheduleController = DailyScheduleController(
        state: appState,
        preferences: preferences
    ) { [weak self] in
        self?.performQuit(scheduled: true)
    }
    private var menu: NSMenu!

    // On-Mac preview — manual by default; optional auto-fallback while disconnected.
    private var previewWindow: NSWindow?
    private var previewImageView: NSImageView?
    private var previewTimer: Timer?
    private var previewManuallyRequested = false
    private var settingsWindow: NSWindow?
    private var scheduleWindow: NSWindow?
    private var documentationCaptureWindow: NSWindow?
    private var documentationCaptureTimer: Timer?
    private var documentationSnapshotURL: URL?
    private var documentationSnapshotDeadline: Date?

    // Menu items that need updating
    private var statusMenuItem: NSMenuItem!
    private var versionMenuItem: NSMenuItem!
    private var pauseResumeItem: NSMenuItem!
    private var reconnectItem: NSMenuItem!
    private var previewItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private var scheduleEnabledItem: NSMenuItem!
    private var pauseActionItem: NSMenuItem!
    private var quitActionItem: NSMenuItem!
    private var automaticStartItem: NSMenuItem!
    private var startTimeItem: NSMenuItem!
    private var closeTimeItem: NSMenuItem!
    private var simplifiedChineseItem: NSMenuItem!
    private var englishItem: NSMenuItem!
    private var updateTimer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("[*] MacTR starting...")

        // Create status bar item — this NEVER gets removed
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()

        // Build menu
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Watch for device state changes — close menu so it refreshes
        // Update icon immediately on device state change
        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: .deviceStateChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateIcon()
                self?.updateMenuItems()
                self?.updatePreviewForConnection()
            }
        })

        notificationTokens.append(NotificationCenter.default.addObserver(
            forName: .appPreferencesChanged, object: preferences, queue: .main
        ) { [weak self] notification in
            let key = notification.userInfo?[AppPreferenceNotification.key] as? String
            Task { @MainActor in
                guard let self else { return }
                if key == AppPreferenceNotification.languageKey {
                    self.appState.applySettings()
                    self.updateWindowTitles()
                    DispatchQueue.main.async { [weak self] in
                        self?.rebuildMenu()
                    }
                } else {
                    self.updateMenuItems()
                }
                self.updatePreviewForConnection()
            }
        })

        let isMenuSnapshot =
            CommandLine.arguments.contains("--menu-snapshot")
        if isMenuSnapshot {
            // Documentation capture must not contend with the user's running copy
            // for USB ownership. The menu itself remains the production NSMenu;
            // only its runtime state is a deterministic disconnected state.
            appState.disconnect()
        } else {
            // Reconcile the daily schedule before opening the USB device.
            scheduleController.start()
            if !appState.isPaused {
                appState.start()
            }

            // No LCD after the initial connect attempt → fall back to on-Mac preview.
            // Delayed so a present device can connect first without a window flash.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.updatePreviewForConnection()
            }
        }

        updateTimer = Timer.scheduledTimer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(updateStatusTimerFired),
            userInfo: nil,
            repeats: true)

        // Documentation helper: open and optionally capture the real NSStatusItem
        // menu so docs never drift from the production menu implementation.
        if let snapshotIndex = CommandLine.arguments.firstIndex(of: "--menu-snapshot"),
           snapshotIndex + 1 < CommandLine.arguments.count
        {
            let outputURL = URL(
                fileURLWithPath: CommandLine.arguments[snapshotIndex + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.openNativeMenuForDocumentation(snapshotURL: outputURL)
            }
        } else if CommandLine.arguments.contains("--open-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.openNativeMenuForDocumentation()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        scheduleController.stop()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        appState.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func updateStatusTimerFired() {
        updateIcon()
        updateMenuItems()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        launchAtLogin.refresh()
        updateIcon()
        updateMenuItems()
    }

    // MARK: - Icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = makeIcon(
            disconnected: !appState.isConnected,
            paused: appState.isPaused)
    }

    /// Connected = template display; paused = amber badge; disconnected = red badge.
    private func makeIcon(disconnected: Bool, paused: Bool) -> NSImage {
        let hasBadge = disconnected || paused
        let w: CGFloat = hasBadge ? 22 : 18
        let h: CGFloat = 16

        let image = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            let menuBarColor: NSColor = .labelColor  // adapts to dark/light mode

            // Draw monitor shape
            let screenRect = NSRect(x: 0, y: 4, width: 18, height: 11)
            let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 2, yRadius: 2)
            menuBarColor.setStroke()
            screenPath.lineWidth = 1.5
            screenPath.stroke()

            // Stand
            let standTop = NSPoint(x: 9, y: 4)
            let standBot = NSPoint(x: 9, y: 1.5)
            let stand = NSBezierPath()
            stand.move(to: standTop)
            stand.line(to: standBot)
            stand.lineWidth = 1.5
            menuBarColor.setStroke()
            stand.stroke()

            // Base
            let basePath = NSBezierPath()
            basePath.move(to: NSPoint(x: 5, y: 1.5))
            basePath.line(to: NSPoint(x: 13, y: 1.5))
            basePath.lineWidth = 1.5
            basePath.stroke()

            if hasBadge {
                let badgeD: CGFloat = 9
                let badgeRect = NSRect(
                    x: rect.width - badgeD + 0.5,
                    y: rect.height - badgeD + 0.5,
                    width: badgeD, height: badgeD)

                (paused ? NSColor.systemOrange : NSColor.systemRed).setFill()
                NSBezierPath(ovalIn: badgeRect).fill()

                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 7, weight: .black),
                    .foregroundColor: NSColor.white,
                ]
                let mark = (paused ? "Ⅱ" : "!") as NSString
                let markSize = mark.size(withAttributes: attrs)
                mark.draw(at: NSPoint(
                    x: badgeRect.midX - markSize.width / 2,
                    y: badgeRect.midY - markSize.height / 2),
                    withAttributes: attrs)
            }

            return true
        }

        image.isTemplate = !hasBadge
        return image
    }

    // MARK: - Menu

    private func buildMenu() {
        let language = preferences.language
        menu = NSMenu()

        versionMenuItem = NSMenuItem(
            title: "MacTR v\(AppVersion.short)", action: nil, keyEquivalent: "")
        versionMenuItem.isEnabled = false
        menu.addItem(versionMenuItem)

        statusMenuItem = NSMenuItem(
            title: language.text(.disconnected),
            action: nil,
            keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        pauseResumeItem = NSMenuItem(
            title: language.text(.pauseDisplayOutput),
            action: #selector(togglePause),
            keyEquivalent: "")
        pauseResumeItem.target = self
        menu.addItem(pauseResumeItem)

        reconnectItem = NSMenuItem(
            title: language.text(.reconnect),
            action: #selector(reconnect),
            keyEquivalent: "r")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        previewItem = NSMenuItem(
            title: language.text(.previewWindow),
            action: #selector(showPreviewManually),
            keyEquivalent: "p")
        previewItem.target = self
        menu.addItem(previewItem)

        menu.addItem(.separator())

        launchAtLoginItem = NSMenuItem(
            title: language.text(.launchAtLogin),
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: "")
        launchAtLoginItem.target = self
        menu.addItem(launchAtLoginItem)

        let scheduleItem = NSMenuItem(
            title: language.text(.dailySchedule),
            action: nil,
            keyEquivalent: "")
        let scheduleMenu = NSMenu()

        scheduleEnabledItem = NSMenuItem(
            title: language.text(.enabled),
            action: #selector(toggleSchedule),
            keyEquivalent: "")
        scheduleEnabledItem.target = self
        scheduleMenu.addItem(scheduleEnabledItem)
        scheduleMenu.addItem(.separator())

        let closeActionItem = NSMenuItem(
            title: language.text(.atCloseTime),
            action: nil,
            keyEquivalent: "")
        let actionMenu = NSMenu()
        pauseActionItem = NSMenuItem(
            title: language.text(.pauseDisplayOutput),
            action: #selector(selectPauseAction),
            keyEquivalent: "")
        pauseActionItem.target = self
        actionMenu.addItem(pauseActionItem)
        quitActionItem = NSMenuItem(
            title: language.text(.quitMacTR),
            action: #selector(selectQuitAction),
            keyEquivalent: "")
        quitActionItem.target = self
        actionMenu.addItem(quitActionItem)
        closeActionItem.submenu = actionMenu
        scheduleMenu.addItem(closeActionItem)

        automaticStartItem = NSMenuItem(
            title: language.text(.resumeAutomatically),
            action: #selector(toggleAutomaticStart),
            keyEquivalent: "")
        automaticStartItem.target = self
        scheduleMenu.addItem(automaticStartItem)

        startTimeItem = NSMenuItem(
            title: "\(language.text(.resume)): 08:00",
            action: nil,
            keyEquivalent: "")
        startTimeItem.isEnabled = false
        scheduleMenu.addItem(startTimeItem)

        closeTimeItem = NSMenuItem(
            title: "\(language.text(.close)): 23:00",
            action: nil,
            keyEquivalent: "")
        closeTimeItem.isEnabled = false
        scheduleMenu.addItem(closeTimeItem)
        scheduleMenu.addItem(.separator())

        let editScheduleItem = NSMenuItem(
            title: language.text(.editTimes),
            action: #selector(openScheduleEditor),
            keyEquivalent: "")
        editScheduleItem.target = self
        scheduleMenu.addItem(editScheduleItem)

        scheduleItem.submenu = scheduleMenu
        menu.addItem(scheduleItem)

        let languageItem = NSMenuItem(
            title: language.text(.language),
            action: nil,
            keyEquivalent: "")
        let languageMenu = NSMenu()
        simplifiedChineseItem = NSMenuItem(
            title: AppLanguage.simplifiedChinese.displayName,
            action: #selector(selectSimplifiedChinese),
            keyEquivalent: "")
        simplifiedChineseItem.target = self
        languageMenu.addItem(simplifiedChineseItem)
        englishItem = NSMenuItem(
            title: AppLanguage.english.displayName,
            action: #selector(selectEnglish),
            keyEquivalent: "")
        englishItem.target = self
        languageMenu.addItem(englishItem)
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        let settingsItem = NSMenuItem(
            title: language.text(.settings),
            action: #selector(openSettings),
            keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let releasesItem = NSMenuItem(
            title: language.text(.viewLatestRelease),
            action: #selector(openLatestRelease),
            keyEquivalent: "u")
        releasesItem.target = self
        menu.addItem(releasesItem)

        let aboutItem = NSMenuItem(
            title: language.text(.aboutMacTR),
            action: #selector(showAbout),
            keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: language.text(.quitMacTR),
            action: #selector(quit),
            keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        updateMenuItems()
    }

    private func rebuildMenu() {
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Opens the production NSMenu over a small host window. This exists only
    /// for automated documentation capture; all menu items and state are the
    /// exact same instances attached to the live status item.
    private func openNativeMenuForDocumentation(snapshotURL: URL? = nil) {
        let size = NSSize(width: 420, height: 620)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.title = "MacTR Native Menu"
        window.isReleasedWhenClosed = false
        window.backgroundColor = .windowBackgroundColor
        window.center()
        window.makeKeyAndOrderFront(nil)
        documentationCaptureWindow = window
        NSApp.activate(ignoringOtherApps: true)

        guard let view = window.contentView else { return }
        if let snapshotURL {
            let hostWindowID = CGWindowID(window.windowNumber)
            let processID = ProcessInfo.processInfo.processIdentifier
            try? FileManager.default.removeItem(at: snapshotURL)
            try? FileManager.default.removeItem(
                at: snapshotURL.appendingPathExtension("partial"))
            documentationSnapshotURL = snapshotURL
            documentationSnapshotDeadline = Date().addingTimeInterval(15)
            let captureTimer = Timer(
                timeInterval: 0.1,
                target: self,
                selector: #selector(checkNativeMenuDocumentationCapture),
                userInfo: nil,
                repeats: true)
            documentationCaptureTimer = captureTimer
            RunLoop.main.add(captureTimer, forMode: .eventTracking)

            Task.detached {
                try? await Task.sleep(for: .milliseconds(700))
                _ = await Self.captureNativeMenuWindow(
                    processID: processID,
                    excluding: hostWindowID,
                    outputURL: snapshotURL)
            }
        }
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 24, y: view.bounds.height - 24),
            in: view)
    }

    nonisolated private static func captureNativeMenuWindow(
        processID: pid_t,
        excluding hostWindowID: CGWindowID,
        outputURL: URL
    ) async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true)
            let candidates = content.windows.filter { window in
                window.owningApplication?.processID == processID
                    && window.windowID != hostWindowID
                    && window.isOnScreen
                    && window.frame.width >= 120
                    && window.frame.height >= 120
            }
            guard let menuWindow = candidates.max(by: { lhs, rhs in
                if lhs.windowLayer == rhs.windowLayer {
                    return lhs.frame.height < rhs.frame.height
                }
                return lhs.windowLayer < rhs.windowLayer
            }) else {
                log("[Documentation] Native menu window was not found")
                return false
            }

            let filter = SCContentFilter(desktopIndependentWindow: menuWindow)
            let configuration = SCStreamConfiguration()
            configuration.width = max(1, Int(menuWindow.frame.width * 2))
            configuration.height = max(1, Int(menuWindow.frame.height * 2))
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration)

            let partialURL = outputURL.appendingPathExtension("partial")
            guard let destination = CGImageDestinationCreateWithURL(
                partialURL as CFURL,
                "public.png" as CFString,
                1,
                nil)
            else { return false }
            CGImageDestinationAddImage(destination, image, nil)
            let success = CGImageDestinationFinalize(destination)
            if success {
                try? FileManager.default.removeItem(at: outputURL)
                try FileManager.default.moveItem(at: partialURL, to: outputURL)
                log("[Documentation] Native menu saved to \(outputURL.path)")
            }
            return success
        } catch {
            log("[Documentation] Native menu capture failed: \(error.localizedDescription)")
            return false
        }
    }

    @objc private func checkNativeMenuDocumentationCapture() {
        let outputExists = documentationSnapshotURL.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
        let timedOut = documentationSnapshotDeadline.map { Date() >= $0 } ?? true
        guard outputExists || timedOut else { return }
        finishNativeMenuDocumentationCapture(success: outputExists)
    }

    private func finishNativeMenuDocumentationCapture(success: Bool) {
        documentationCaptureTimer?.invalidate()
        documentationCaptureTimer = nil
        documentationSnapshotURL = nil
        documentationSnapshotDeadline = nil
        menu.cancelTracking()
        documentationCaptureWindow?.orderOut(nil)
        print(success
            ? "[Menu Snapshot] wrote native menu"
            : "[Menu Snapshot] failed")
        NSApp.terminate(nil)
    }

    // NOTE: deliberately does not call launchAtLogin.refresh(). This runs from a
    // 1 s timer, and refresh() is an XPC round trip to SMAppService — one per
    // second, forever, for a value that changes about never. It is refreshed
    // when the menu is about to open and when Settings appears instead.
    private func updateMenuItems() {
        let language = preferences.language

        let dot: String
        if appState.isPaused {
            dot = "🟠"
        } else if appState.isConnected {
            dot = "🟢"
        } else {
            dot = "🔴"
        }
        statusMenuItem.title = "\(dot) \(appState.localizedStatusMessage)"

        pauseResumeItem.title = appState.isPaused
            ? language.text(.resumeDisplayOutput)
            : language.text(.pauseDisplayOutput)
        reconnectItem.isHidden = appState.isConnected || appState.isPaused
        previewItem.isEnabled = !appState.isPaused

        launchAtLoginItem.state = launchAtLogin.isEnabled ? .on : .off
        launchAtLoginItem.isEnabled = launchAtLogin.isAvailable

        scheduleEnabledItem.state = preferences.scheduleEnabled ? .on : .off
        pauseActionItem.state = preferences.scheduleAction == .pauseDisplay ? .on : .off
        quitActionItem.state = preferences.scheduleAction == .quitApp ? .on : .off
        automaticStartItem.state = preferences.automaticStartEnabled ? .on : .off
        automaticStartItem.isHidden = preferences.scheduleAction == .quitApp
        startTimeItem.isHidden = preferences.scheduleAction == .quitApp
            || !preferences.automaticStartEnabled
        startTimeItem.title =
            "\(language.text(.resume)): \(AppPreferences.formattedTime(minutes: preferences.startMinutes))"
        closeTimeItem.title =
            "\(language.text(.close)): \(AppPreferences.formattedTime(minutes: preferences.closeMinutes))"
        simplifiedChineseItem.state =
            language == .simplifiedChinese ? .on : .off
        englishItem.state = language == .english ? .on : .off

        if preferences.scheduleEnabled {
            versionMenuItem.title = "MacTR v\(appVersion) • \(scheduleController.nextActionDescription)"
        } else {
            versionMenuItem.title = "MacTR v\(appVersion)"
        }
    }

    // MARK: - Preview Window (auto-fallback when LCD is disconnected)

    private func updateWindowTitles() {
        let language = preferences.language
        previewWindow?.title = language.text(.previewTitle)
        scheduleWindow?.title = language.text(.scheduleWindowTitle)
        settingsWindow?.title = language.text(.settingsWindowTitle)
    }

    private func updatePreviewForConnection() {
        if appState.isPaused {
            previewManuallyRequested = false
            hidePreview()
        } else if previewManuallyRequested
                    || (!appState.isConnected
                        && preferences.autoShowPreviewWhenDisconnected)
        {
            showPreview()
        } else {
            hidePreview()
        }
    }

    private func showPreview() {
        if previewWindow == nil {
            let contentSize = NSSize(width: Layout.width / 2, height: Layout.height / 2)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = preferences.language.text(.previewTitle)
            window.contentAspectRatio = NSSize(width: Layout.width, height: Layout.height)
            window.isReleasedWhenClosed = false
            window.delegate = self

            let imageView = NSImageView(frame: NSRect(origin: .zero, size: contentSize))
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.width, .height]
            window.contentView?.addSubview(imageView)
            window.center()

            previewWindow = window
            previewImageView = imageView
        }
        previewWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        appState.setPreviewActive(true)

        previewTimer?.invalidate()
        previewTimer = Timer.scheduledTimer(
            timeInterval: 1 / max(
                preferences.performanceMode.activeFramesPerSecond, 1),
            target: self,
            selector: #selector(previewTimerFired),
            userInfo: nil,
            repeats: true)
        refreshPreview()
    }

    private func hidePreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        previewWindow?.orderOut(nil)
        appState.setPreviewActive(false)
    }

    @objc private func previewTimerFired() {
        refreshPreview()
    }

    private func refreshPreview() {
        guard let image = appState.currentFrame() else { return }
        previewImageView?.image = NSImage(
            cgImage: image, size: NSSize(width: Layout.width, height: Layout.height))
    }

    @objc private func showPreviewManually() {
        guard !appState.isPaused else { return }
        previewManuallyRequested = true
        showPreview()
    }

    // Closing Preview never quits the menu-bar app.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == previewWindow else { return }
        previewTimer?.invalidate()
        previewTimer = nil
        previewManuallyRequested = false
        appState.setPreviewActive(false)
    }

    // MARK: - Actions

    @objc private func togglePause() {
        if appState.isPaused {
            scheduleController.resumeManually()
        } else {
            scheduleController.pauseManually()
        }
        updateMenuItems()
        updateIcon()
        updatePreviewForConnection()
    }

    @objc private func reconnect() {
        appState.connect()
    }

    @objc private func toggleLaunchAtLogin() {
        launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
        updateMenuItems()
        if let message = launchAtLogin.localizedErrorMessage(
            language: preferences.language)
        {
            let alert = NSAlert()
            alert.messageText = preferences.language.text(.loginAlertTitle)
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func toggleSchedule() {
        preferences.scheduleEnabled.toggle()
    }

    @objc private func selectPauseAction() {
        preferences.scheduleAction = .pauseDisplay
    }

    @objc private func selectQuitAction() {
        preferences.scheduleAction = .quitApp
    }

    @objc private func toggleAutomaticStart() {
        preferences.automaticStartEnabled.toggle()
    }

    @objc private func selectSimplifiedChinese() {
        preferences.language = .simplifiedChinese
    }

    @objc private func selectEnglish() {
        preferences.language = .english
    }

    @objc private func openScheduleEditor() {
        if scheduleWindow == nil {
            let view = ScheduleTimeEditorView(preferences: preferences)
            let hostingController = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hostingController)
            window.title = preferences.language.text(.scheduleWindowTitle)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 360, height: 260))
            window.center()
            scheduleWindow = window
        }
        scheduleWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView(
                state: appState,
                launchAtLogin: launchAtLogin,
                pauseDisplay: { [weak self] in self?.scheduleController.pauseManually() },
                resumeDisplay: { [weak self] in self?.scheduleController.resumeManually() })
            let hostingController = NSHostingController(rootView: settingsView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = preferences.language.text(.settingsWindowTitle)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 580, height: 760))
            window.center()
            settingsWindow = window
        }
        launchAtLogin.refresh()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openLatestRelease() {
        guard let url = URL(
            string: "https://github.com/luckykong/mac-thermalright-ai-monitor/releases/latest")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func showAbout() {
        let version = AppVersion.short
        let build = AppVersion.build

        let alert = NSAlert()
        alert.messageText = "MacTR"
        alert.informativeText = AppLocalization.format(
            .aboutBody,
            language: preferences.language,
            version,
            build)
        alert.alertStyle = .informational
        alert.addButton(withTitle: preferences.language.text(.ok))

        if let icon = NSImage(named: "AppIcon") {
            alert.icon = icon
        }

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        performQuit(scheduled: false)
    }

    private func performQuit(scheduled: Bool) {
        if scheduled {
            log("[Schedule] Closing MacTR at the configured daily time")
        }
        scheduleController.stop()
        appState.stop()
        NSApp.terminate(nil)
    }

    private var appVersion: String { AppVersion.short }
}

// MARK: - CLI Mode

// MARK: - Benchmark Mode

/// Measure achievable frame rate on the connected LCD. Breaks timing into render,
/// JPEG encode, and USB send so we know which stage bounds the fps.
private func runBenchmark() {
    let args = CommandLine.arguments
    let frames = parseFlag(args, flag: "--benchmark") ?? 120
    let brightness = parseFlag(args, flag: "-b") ?? 5
    // Matches the "Rotate 180°" setting: set for panels mounted the other way
    // up. It XORs with the panel's own `needsRotation` exactly as the GUI
    // engine does in AppState, so both paths land the same way up.
    let rotate = args.contains("--rotate")

    print("[Bench] Frame-rate benchmark — \(frames) frames")
    let device = USBDevice()
    do { try device.open() } catch {
        print("[Bench][ERROR] open failed: \(error) — is MacTR still running and holding the device?")
        return
    }
    defer { device.close() }

    let info: DeviceInfo
    do { info = try LYProtocol.handshake(device: device) }
    catch { print("[Bench][ERROR] handshake failed: \(error)"); return }
    let rotate180 = info.needsRotation != rotate

    let renderer = MonitorRenderer()
    renderer.startMetrics()
    Thread.sleep(forTimeInterval: 1.0)  // prime metrics so render() returns frames

    func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }  // ms

    // Warm up: first render + JPEG/rotation contexts allocate; discard 5 frames
    for _ in 0..<5 {
        if let img = renderer.render(),
           let j = JPEGEncoder.encode(img, brightness: brightness, rotate180: rotate180) {
            try? LYProtocol.sendFrame(device: device, jpegData: j)
        }
    }

    var renderMs = [Double](), encodeMs = [Double](), sendMs = [Double]()
    var jpegBytes = [Int]()
    var sent = 0
    let t0 = now()

    for _ in 0..<frames {
        let r0 = now()
        guard let image = renderer.render() else { continue }
        let r1 = now()
        guard let jpeg = JPEGEncoder.encode(image, brightness: brightness, rotate180: rotate180) else { continue }
        let r2 = now()
        do { try LYProtocol.sendFrame(device: device, jpegData: jpeg) }
        catch { print("[Bench][ERROR] send failed at frame \(sent): \(error)"); break }
        let r3 = now()

        renderMs.append(r1 - r0)
        encodeMs.append(r2 - r1)
        sendMs.append(r3 - r2)
        jpegBytes.append(jpeg.count)
        sent += 1
    }

    let elapsed = (now() - t0) / 1000  // seconds
    renderer.stopMetrics()

    guard sent > 0 else { print("[Bench] No frames sent"); return }
    func avg(_ a: [Double]) -> Double { a.reduce(0, +) / Double(a.count) }
    func pctl(_ a: [Double], _ p: Double) -> Double {
        let s = a.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))]
    }
    let perFrame = avg(renderMs) + avg(encodeMs) + avg(sendMs)
    let avgKB = jpegBytes.reduce(0, +) / jpegBytes.count / 1024

    print("========== Benchmark Result ==========")
    print(String(format: "Sent %d frames in %.2fs → %.1f fps (back-to-back, no delay)", sent, elapsed, Double(sent) / elapsed))
    print(String(format: "Per-frame avg: %.1f ms  → theoretical max %.1f fps", perFrame, 1000 / perFrame))
    print(String(format: "  render  : avg %.1f ms  p95 %.1f ms", avg(renderMs), pctl(renderMs, 0.95)))
    print(String(format: "  encode  : avg %.1f ms  p95 %.1f ms", avg(encodeMs), pctl(encodeMs, 0.95)))
    print(String(format: "  USB send: avg %.1f ms  p95 %.1f ms  (%d KB/frame avg)", avg(sendMs), pctl(sendMs, 0.95), avgKB))
    print("======================================")
}

// MARK: - GIF Mode (animated demo for the README)

/// Render an animated GIF of the demo dashboard. No LCD required — pure rendering.
/// Usage: --gif out.gif [--frames N] [--fps F] [--scale S]
private func runGif() {
    let args = CommandLine.arguments
    guard let gi = args.firstIndex(of: "--gif"), gi + 1 < args.count else {
        print("[GIF] usage: --gif out.gif [--frames N] [--fps F] [--scale S]"); return
    }
    let path = args[gi + 1]
    let frames = parseFlag(args, flag: "--frames") ?? 40
    let fps = parseFlag(args, flag: "--fps") ?? 12
    let scale = max(1, parseFlag(args, flag: "--scale") ?? 2)
    let outW = Layout.width / scale, outH = Layout.height / scale
    let delay = 1.0 / Double(fps)

    let renderer = MonitorRenderer()
    renderer.demoMode = true

    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "com.compuserve.gif" as CFString,
                                                     frames, nil) else {
        print("[GIF][ERROR] cannot create \(path)"); return
    }
    CGImageDestinationSetProperties(dest, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
    ] as CFDictionary)
    let frameProps = [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
    ] as CFDictionary

    print("[GIF] rendering \(frames) frames at \(outW)x\(outH), \(fps)fps → \(path)")
    for _ in 0..<frames {
        autoreleasepool {
            if let img = renderer.render(), let small = downscaleImage(img, outW, outH) {
                CGImageDestinationAddImage(dest, small, frameProps)
            }
        }
        Thread.sleep(forTimeInterval: delay)   // advance the Date()-based animations
    }
    if CGImageDestinationFinalize(dest) {
        print("[GIF] wrote \(path)")
    } else {
        print("[GIF][ERROR] finalize failed")
    }
}

private func downscaleImage(_ image: CGImage, _ w: Int, _ h: Int) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

// MARK: - Showcase Mode

/// Drive the LCD with deterministic sample data at 15fps.
/// Stop the running MacTR first (it holds the device); Ctrl+C to end.
private func runDemo() {
    let brightness = parseFlag(CommandLine.arguments, flag: "-b") ?? 5
    let rotate = CommandLine.arguments.contains("--rotate")

    log("[Demo] Showcase mode — sample data")
    let device = USBDevice()
    do { try device.open() } catch {
        print("[Demo][ERROR] open failed: \(error) — stop the running MacTR first")
        return
    }
    defer { device.close() }
    let info: DeviceInfo
    do { info = try LYProtocol.handshake(device: device) }
    catch { print("[Demo][ERROR] handshake failed: \(error)"); return }
    let rotate180 = info.needsRotation != rotate

    let renderer = MonitorRenderer()
    renderer.demoMode = true
    print("[Demo] Sending showcase frames at 15fps (Ctrl+C to stop)...")
    signal(SIGINT, SIG_DFL)
    while true {
        autoreleasepool {
            if let image = renderer.render(),
               let jpeg = JPEGEncoder.encode(image, brightness: brightness, rotate180: rotate180) {
                try? LYProtocol.sendFrame(device: device, jpegData: jpeg)
            }
        }
        Thread.sleep(forTimeInterval: 1.0 / 15.0)
    }
}

private func runCLI() {
    let args = CommandLine.arguments
    let isTest = args.contains("--test")
    let brightness = parseFlag(args, flag: "-b") ?? 5
    // Matches the "Rotate 180°" setting: set for panels mounted the other way
    // up. It XORs with the panel's own `needsRotation` exactly as the GUI
    // engine does in AppState, so both paths land the same way up.
    let rotate = args.contains("--rotate")

    log("[*] MacTR CLI — \(isTest ? "USB Test" : "System Monitor")")
    log("[*] Brightness: level \(brightness) (\(Brightness.factor(for: brightness))x), Rotate: \(rotate)")
    log("[*] Searching for Thermalright LCD...")

    let device = USBDevice()

    do {
        try device.open()
    } catch {
        log("[ERROR] \(error)")
        return
    }

    defer { device.close() }

    let info: DeviceInfo
    do {
        info = try LYProtocol.handshake(device: device)
    } catch {
        log("[ERROR] Handshake failed: \(error)")
        return
    }

    if isTest {
        guard let jpeg = makeTestJPEG(width: info.width, height: info.height) else {
            log("[ERROR] Failed to create test image")
            return
        }
        log("[*] JPEG size: \(jpeg.count) bytes")
        cliFrameLoop(device: device, staticJPEG: jpeg)
    } else {
        let renderer = MonitorRenderer()
        renderer.startMetrics()
        Thread.sleep(forTimeInterval: 0.3)

        log("[*] Sending frames (press Ctrl+C to stop)...")
        signal(SIGINT, SIG_DFL)

        var count = 0
        while true {
            guard let image = renderer.render(),
                  let jpeg = JPEGEncoder.encode(
                      image, brightness: brightness,
                      rotate180: info.needsRotation != rotate)
            else {
                Thread.sleep(forTimeInterval: 1)
                continue
            }

            do {
                try LYProtocol.sendFrame(device: device, jpegData: jpeg)
                count += 1
                if count == 1 {
                    log("[OK] Monitor active! ~\(jpeg.count / 1024)KB/frame (Ctrl+C to stop)")
                }
            } catch {
                log("[ERROR] Frame send failed: \(error)")
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}

private func cliFrameLoop(device: USBDevice, staticJPEG: Data) {
    log("[*] Sending frames (press Ctrl+C to stop)...")
    signal(SIGINT, SIG_DFL)
    var count = 0
    while true {
        do {
            try LYProtocol.sendFrame(device: device, jpegData: staticJPEG)
            count += 1
            if count == 1 { log("[OK] Display active! Looping...") }
        } catch {
            log("[ERROR] Frame send failed: \(error)")
            break
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
}

private func parseFlag(_ args: [String], flag: String) -> Int? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return Int(args[idx + 1])
}

private func parseLanguage(_ args: [String]) -> AppLanguage {
    guard let index = args.firstIndex(of: "--language"),
          index + 1 < args.count
    else { return .simplifiedChinese }
    switch args[index + 1].lowercased() {
    case "en", "english":
        return .english
    default:
        return .simplifiedChinese
    }
}

// MARK: - Test Image

func makeTestJPEG(width: Int, height: Int) -> Data? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let colors = [
        CGColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1),
        CGColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: CGFloat(height)),
                               end: CGPoint(x: 0, y: 0), options: [])
    }

    let text = "MacTR — Swift USB Test" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 48, weight: .medium),
        .foregroundColor: NSColor.white,
    ]
    let textSize = text.size(withAttributes: attrs)
    let x = (CGFloat(width) - textSize.width) / 2

    ctx.saveGState()
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    text.draw(at: NSPoint(x: x, y: CGFloat(height) / 2 - textSize.height / 2), withAttributes: attrs)

    let sub = "macOS 26 \u{2022} Swift 6.3 \u{2022} libusb" as NSString
    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 24),
        .foregroundColor: NSColor(white: 0.6, alpha: 1),
    ]
    let subSize = sub.size(withAttributes: subAttrs)
    sub.draw(at: NSPoint(x: (CGFloat(width) - subSize.width) / 2,
                         y: CGFloat(height) / 2 + textSize.height / 2 + 10),
             withAttributes: subAttrs)
    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { return nil }
    return JPEGEncoder.encode(image)
}
