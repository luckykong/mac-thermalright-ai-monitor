// AppState.swift — App-wide state management
//
// USB I/O runs entirely on a background queue. Only UI state updates
// dispatch to @MainActor. This prevents USB timeouts from blocking
// the main thread (which causes macOS rainbow spinner + keyboard freeze).

import AppKit
import Foundation
import Observation
import Synchronization

// MARK: - Display Set

extension Notification.Name {
    static let deviceStateChanged = Notification.Name("deviceStateChanged")
}

enum DisplaySet: String, CaseIterable, Identifiable, Sendable {
    case systemMonitor = "System Monitor"

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .systemMonitor: language.text(.systemMonitor)
        }
    }
}

enum DisplayPauseReason: String, Equatable, Sendable {
    case manual
    case schedule

    var internalStatusMessage: String {
        switch self {
        case .manual: "Paused"
        case .schedule: "Paused by daily schedule"
        }
    }

    func statusMessage(language: AppLanguage) -> String {
        switch self {
        case .manual: language.text(.paused)
        case .schedule: language.text(.pausedBySchedule)
        }
    }
}

enum AppRuntimeState: Equatable, Sendable {
    case stopped
    case connecting
    case running
    case paused(DisplayPauseReason)
    case disconnected
    case error(String)
}

// MARK: - AppState

@Observable
@MainActor
final class AppState {

    let preferences: AppPreferences

    // Connection (UI-facing)
    private(set) var isConnected = false
    private(set) var deviceInfo: DeviceInfo?
    private(set) var statusMessage = "Stopped"
    private(set) var runtimeState: AppRuntimeState = .stopped
    private(set) var pauseReason: DisplayPauseReason?

    // Metrics (for menu bar display)
    private(set) var frameCount = 0
    private(set) var lastFrameSize = 0
    private(set) var customScriptSnapshot = CustomScriptSnapshot.disabled

    // MARK: - Internal

    private var engine: DisplayEngine?
    private var engineGeneration: UUID?

    init(preferences: AppPreferences = AppPreferences()) {
        self.preferences = preferences
    }

    var isPaused: Bool { pauseReason != nil }

    var localizedStatusMessage: String {
        AppLocalization.localizedStatus(statusMessage, language: preferences.language)
    }

    // MARK: - Lifecycle

    func start() {
        guard engine == nil, pauseReason == nil else { return }
        let generation = UUID()
        engineGeneration = generation
        runtimeState = .connecting
        statusMessage = "Connecting..."
        postStateChanged()

        let eng = DisplayEngine { [weak self] status in
            Task { @MainActor in
                guard let self, self.engineGeneration == generation,
                      self.pauseReason == nil
                else { return }
                let prev = self.isConnected
                let previousMessage = self.statusMessage
                self.isConnected = status.connected
                self.deviceInfo = status.deviceInfo ?? self.deviceInfo
                self.statusMessage = status.message
                self.frameCount = status.frameCount
                self.lastFrameSize = status.lastFrameSize
                self.customScriptSnapshot = status.customScriptSnapshot
                self.runtimeState = status.state

                // Log state changes + post notification for UI refresh
                if status.connected != prev {
                    log("[*] LCD \(status.connected ? "connected" : "disconnected")")
                }
                if status.connected != prev || status.message != previousMessage {
                    self.postStateChanged()
                }
            }
        }
        engine = eng
        eng.start(
            set: preferences.currentSet,
            brightness: preferences.brightness,
            performanceMode: preferences.performanceMode,
            rotate: preferences.rotateDisplay,
            customScript: preferences.customScriptConfiguration,
            language: preferences.language,
            customScriptFontMode: preferences.customScriptFontMode)
    }

    func stop() {
        engineGeneration = nil
        engine?.stop()
        engine = nil
        isConnected = false
        statusMessage = "Stopped"
        runtimeState = .stopped
        pauseReason = nil
        frameCount = 0
        lastFrameSize = 0
        customScriptSnapshot = .disabled
        postStateChanged()
    }

    func pauseDisplay(reason: DisplayPauseReason) {
        guard pauseReason != .manual || reason == .manual else { return }
        engineGeneration = nil
        engine?.stop()
        engine = nil
        isConnected = false
        pauseReason = reason
        runtimeState = .paused(reason)
        statusMessage = reason.internalStatusMessage
        frameCount = 0
        lastFrameSize = 0
        customScriptSnapshot = .disabled
        log("[App] Display output paused (\(reason.rawValue))")
        postStateChanged()
    }

    func resumeDisplay() {
        guard pauseReason != nil else {
            if engine == nil { start() }
            return
        }
        pauseReason = nil
        runtimeState = .connecting
        statusMessage = "Resuming..."
        log("[App] Resuming display output")
        postStateChanged()
        start()
    }

    func connect() {
        guard !isPaused else { return }
        if engine == nil {
            start()
            return
        }
        engine?.reconnect()
    }

    func disconnect() {
        engineGeneration = nil
        engine?.stop()
        engine = nil
        isConnected = false
        statusMessage = "Disconnected"
        runtimeState = .disconnected
        frameCount = 0
        customScriptSnapshot = .disabled
        postStateChanged()
    }

    /// Called when user changes display set, brightness, or interval
    func applySettings() {
        engine?.updateSettings(
            set: preferences.currentSet,
            brightness: preferences.brightness,
            performanceMode: preferences.performanceMode,
            rotate: preferences.rotateDisplay,
            customScript: preferences.customScriptConfiguration,
            language: preferences.language,
            customScriptFontMode: preferences.customScriptFontMode)
    }

    /// Latest rendered frame for the on-Mac preview window
    func currentFrame() -> CGImage? {
        engine?.currentFrame()
    }

    func setPreviewActive(_ active: Bool) {
        engine?.setPreviewActive(active)
    }

    func runCustomScriptNow() {
        engine?.runCustomScriptNow()
    }

    /// Seeds the documentation-only Settings capture without starting USB or
    /// executing a script. The guard keeps this out of normal app behavior.
    func setDocumentationCustomScriptSnapshot(_ snapshot: CustomScriptSnapshot) {
        guard CommandLine.arguments.contains("--settings-snapshot") else { return }
        customScriptSnapshot = snapshot
    }

    private func postStateChanged() {
        NotificationCenter.default.post(name: .deviceStateChanged, object: self)
    }

}

// MARK: - Engine Status

struct EngineStatus: Sendable {
    /// The engine's own view of what it is doing. Carried explicitly because
    /// AppState used to recover it by substring-matching `message` for
    /// "connecting"/"error"/"failed" — which silently coupled the state machine
    /// to user-visible English wording.
    let state: AppRuntimeState
    let deviceInfo: DeviceInfo?
    let message: String
    let frameCount: Int
    let lastFrameSize: Int
    let customScriptSnapshot: CustomScriptSnapshot

    var connected: Bool { state == .running }
}

// MARK: - Display Engine (runs entirely off main thread)

final class DisplayEngine: @unchecked Sendable {

    private let statusCallback: @Sendable (EngineStatus) -> Void
    private let usbQueue = DispatchQueue(label: "com.thermalvision.usb")
    private var device: USBDevice?
    private var hotplug: USBHotplug?

    // `enabled` and `running` are read and written from the main thread
    // (start/stop), from usbQueue (the frame loop) and from the IOKit hotplug
    // queue. As plain Bools that was a data race which @unchecked Sendable hid
    // from the compiler; the computed wrappers keep every call site unchanged.
    private let enabledFlag = Atomic<Bool>(false)
    private let runningFlag = Atomic<Bool>(false)

    private var enabled: Bool {
        get { enabledFlag.load(ordering: .acquiring) }
        set { enabledFlag.store(newValue, ordering: .releasing) }
    }

    private var running: Bool {
        get { runningFlag.load(ordering: .acquiring) }
        set { runningFlag.store(newValue, ordering: .releasing) }
    }

    private var frameCount = 0
    private var lastFrameSize = 0
    private let observerLock = NSLock()
    private var workspaceObservers: [NSObjectProtocol] = []

    // Settings (atomically accessed)
    private var currentSet: DisplaySet = .systemMonitor
    private var brightness: Int = 5
    private var performanceMode: PerformanceMode = .balanced
    private var rotateDisplay: Bool = false
    private var customScript = CustomScriptConfiguration.disabled
    private var customScriptFontMode: CustomScriptFontMode = .automatic
    private var language: AppLanguage = .simplifiedChinese
    private var previewActive = false

    private let frameLock = NSLock()
    private var latestFrame: CGImage?
    private var lastProgressStatusAt = Date.distantPast

    // Renderers
    private let monitorRenderer = MonitorRenderer()

    init(statusCallback: @escaping @Sendable (EngineStatus) -> Void) {
        self.statusCallback = statusCallback
    }

    func start(
        set: DisplaySet,
        brightness: Int,
        performanceMode: PerformanceMode,
        rotate: Bool,
        customScript: CustomScriptConfiguration,
        language: AppLanguage,
        customScriptFontMode: CustomScriptFontMode
    ) {
        enabled = true
        self.currentSet = set
        self.brightness = brightness
        self.performanceMode = performanceMode
        self.rotateDisplay = rotate
        self.customScript = customScript
        self.customScriptFontMode = customScriptFontMode
        self.language = language
        monitorRenderer.configure(
            performanceMode: performanceMode,
            customScript: customScript,
            language: language,
            customScriptFontMode: customScriptFontMode)

        usbQueue.async { [weak self] in
            guard let self else { return }
            // Start background metrics collection (primes before returning)
            self.monitorRenderer.startMetrics()
            self.setupHotplug()
            self.connectAndRun()
        }
    }

    func stop() {
        enabled = false
        running = false
        monitorRenderer.stopMetrics()
        frameLock.lock()
        latestFrame = nil
        frameLock.unlock()
        removeWorkspaceObservers()
        usbQueue.async { [weak self] in
            self?.hotplug?.stop()
            self?.hotplug = nil
            self?.device?.close()
            self?.device = nil
        }
    }

    func reconnect() {
        usbQueue.async { [weak self] in
            guard let self, self.enabled else { return }
            self.connectAndRun()
        }
    }

    /// Latest rendered frame for the on-Mac preview window (used while the LCD
    /// is connected). While disconnected, preview rendering is the only producer.
    func currentFrame() -> CGImage? {
        if running {
            frameLock.lock()
            let frame = latestFrame
            frameLock.unlock()
            return frame
        }
        guard previewActive else { return nil }
        monitorRenderer.startMetrics()
        let frame = monitorRenderer.render()
        if let frame {
            frameLock.lock()
            latestFrame = frame
            frameLock.unlock()
        }
        return frame
    }

    func updateSettings(
        set: DisplaySet,
        brightness: Int,
        performanceMode: PerformanceMode,
        rotate: Bool,
        customScript: CustomScriptConfiguration,
        language: AppLanguage,
        customScriptFontMode: CustomScriptFontMode
    ) {
        log("[Engine] Settings updated: set=\(set.rawValue), brightness=\(brightness), performance=\(performanceMode.rawValue), rotate=\(rotate)")
        self.currentSet = set
        self.brightness = brightness
        self.performanceMode = performanceMode
        self.rotateDisplay = rotate
        self.customScript = customScript
        self.customScriptFontMode = customScriptFontMode
        self.language = language
        monitorRenderer.configure(
            performanceMode: performanceMode,
            customScript: customScript,
            language: language,
            customScriptFontMode: customScriptFontMode)
    }

    func setPreviewActive(_ active: Bool) {
        usbQueue.async { [weak self] in
            guard let self else { return }
            self.previewActive = active
            if active, !self.running {
                self.monitorRenderer.startMetrics()
            } else if !active, !self.running {
                self.monitorRenderer.stopMetrics()
            }
        }
    }

    func runCustomScriptNow() {
        monitorRenderer.runCustomScriptNow()
    }

    // MARK: - Private (all on usbQueue)

    /// The sole connection driver on usbQueue: establish a link, stream frames
    /// until it drops, back off, retry — as a loop.
    ///
    /// This used to be mutual recursion (connectAndRun → runFrameLoop →
    /// connectAndRun on a send error), so every reconnect cycle pushed two
    /// stack frames that never unwound. On a flaky cable that grows without
    /// bound for as long as the app runs.
    private func connectAndRun() {
        guard enabled, !running else { return }

        var backoff: TimeInterval = 5
        while enabled {
            switch establishConnection() {
            case .connected(let device, let info):
                backoff = 5
                // Returns only once the link drops or the engine is stopped.
                runFrameLoop(device: device, info: info)
            case .busy:
                // Fall through to the backoff below and try again. Quitting the
                // app that holds the panel used to leave MacTR disconnected
                // until the user toggled it or replugged, because nothing in
                // the system announces a released USB interface.
                break
            case .unavailable:
                return
            }

            guard enabled else { return }
            log("[Engine] Will retry connection in \(Int(backoff))s...")
            Thread.sleep(forTimeInterval: backoff)
            backoff = min(backoff * 2, 60)
        }
    }

    /// Opens the device and completes the handshake.
    ///
    /// Returns nil when there is nothing worth retrying against right now — no
    /// device, or another process owns it. Hotplug and wake notifications call
    /// back in when that changes, so spinning here would only burn power.
    private enum ConnectionAttempt {
        case connected(device: USBDevice, info: DeviceInfo)
        /// Nothing to connect to, or something that will not fix itself by
        /// waiting. Plugging the panel back in raises a hotplug event, so the
        /// engine can go dormant instead of polling.
        case unavailable
        /// The panel is present but another process owns it. Whoever holds it
        /// letting go produces no USB event at all, so nothing will ever wake
        /// us — this is the one case that has to be retried on a timer.
        case busy
    }

    private func establishConnection() -> ConnectionAttempt {
        // Metrics may have been stopped on a previous disconnect or on sleep.
        monitorRenderer.startMetrics()

        device?.close()
        device = nil
        frameCount = 0

        postStatus(.connecting, message: "Connecting...")

        let dev = USBDevice()
        do {
            try dev.open()
        } catch {
            // Mapping preserved from the old substring matching: a missing or
            // busy device is not an error state, an unexpected failure is.
            let message: String
            let state: AppRuntimeState
            let outcome: ConnectionAttempt
            switch error {
            case USBError.deviceNotFound:
                message = "Device not found"
                state = .disconnected
                outcome = .unavailable
            case USBError.deviceBusy:
                message = "Device busy (another app?)"
                state = .disconnected
                outcome = .busy
            default:
                message = "Error: \(error)"
                state = .error(message)
                outcome = .unavailable
            }
            postStatus(state, message: message)
            if !previewActive { monitorRenderer.stopMetrics() }
            return outcome
        }

        do {
            let info = try LYProtocol.handshake(device: dev)
            device = dev
            postStatus(.running, deviceInfo: info,
                       message: "Connected (\(info.width)x\(info.height))")
            return .connected(device: dev, info: info)
        } catch {
            dev.close()
            postStatus(.error("Handshake failed"), message: "Handshake failed")
            return .unavailable
        }
    }

    private func runFrameLoop(device: USBDevice, info: DeviceInfo) {
        running = true
        // Clearing on every exit path — including "enabled went false" — keeps a
        // later connectAndRun() from being blocked by its own `!running` guard.
        defer { running = false }
        // Metrics already collecting in background via startMetrics()

        var nextDeadline = DispatchTime.now()

        while running && enabled {
            // Adaptive frame rate: the device sustains ~19fps, but the dashboard's
            // data only changes every ~2s. Run fast (15fps) ONLY while a column is
            // animating (agent working → breathing, or done → blinking); otherwise
            // idle at the configured interval to save CPU/power on this always-on app.
            let frameInterval = (currentSet == .systemMonitor)
                ? monitorRenderer.preferredFrameInterval()
                : performanceMode.idleFrameInterval
            nextDeadline = nextDeadline + .milliseconds(Int(frameInterval * 1000))

            // autoreleasepool forces CG raster data / CGImage release each frame
            // Without this, Core Graphics caches hundreds of 3.6MB images → GB leak
            autoreleasepool {
                let set = currentSet
                let bright = brightness
                // The handshake reports how this panel is mounted, and the
                // "Rotate 180°" switch is for panels mounted the other way up,
                // so the two XOR together. Until now needsRotation was parsed
                // and then never read.
                let rotate180 = info.needsRotation != rotateDisplay

                let jpeg: Data?

                switch set {
                case .systemMonitor:
                    if let image = monitorRenderer.render() {
                        frameLock.lock()
                        latestFrame = image
                        frameLock.unlock()
                        jpeg = JPEGEncoder.encode(
                            image, brightness: bright, rotate180: rotate180)
                    } else {
                        jpeg = nil
                    }
                }

                if let jpeg {
                    do {
                        try LYProtocol.sendFrame(device: device, jpegData: jpeg)
                        frameCount += 1
                        lastFrameSize = jpeg.count
                        if frameCount == 1 {
                            log("[OK] Active! ~\(jpeg.count / 1024)KB/frame")
                        }
                        postStatus(.running, message: "Active")
                    } catch let error as LYError {
                        // A rejected frame is our problem, not the device's.
                        // Tearing the connection down here would report a
                        // disconnect the user cannot act on, then reconnect
                        // straight back into the same bad frame, forever.
                        log("[ERROR] Frame rejected, skipping it: \(error)")
                    } catch {
                        log("[ERROR] Frame send failed: \(error)")
                        self.device?.close()
                        self.device = nil
                        postStatus(
                            .error("Disconnected (send error)"),
                            message: "Disconnected (send error)")
                        // Drop out of the frame loop and let connectAndRun()
                        // own the backoff and reconnect. (`return` here only
                        // leaves the autoreleasepool closure, so clearing
                        // `running` is what actually ends the loop.)
                        running = false
                        return
                    }
                }
            }  // autoreleasepool

            // Sleep only the remaining time until next deadline
            // If work took longer than interval, send next frame immediately
            let now = DispatchTime.now()
            if nextDeadline > now {
                Thread.sleep(forTimeInterval: Double(nextDeadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000)
            } else {
                // Work exceeded interval — reset deadline to avoid cascading catch-up
                nextDeadline = now
            }
        }
    }

    private func setupHotplug() {
        let hp = USBHotplug()

        hp.onConnect = { [weak self] in
            guard let self else { return }
            self.usbQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.enabled, !self.running else { return }
                log("[Hotplug] Attempting reconnect...")
                self.monitorRenderer.startMetrics()
                self.connectAndRun()
            }
        }

        hp.onDisconnect = { [weak self] in
            guard let self, self.enabled else { return }
            log("[Hotplug] Device removed")
            // Deliberately set from the hotplug queue, not usbQueue: the frame
            // loop is occupying usbQueue and clearing this flag is the only
            // thing that makes it return. Safe now that it is atomic.
            self.running = false
            // Everything else touches usbQueue-owned state, so it goes through
            // the queue — `previewActive` in particular was being read here.
            self.usbQueue.async { [weak self] in
                guard let self else { return }
                self.device?.close()
                self.device = nil
                if !self.previewActive {
                    self.monitorRenderer.stopMetrics()
                }
                self.postStatus(.disconnected, message: "Disconnected (unplugged)")
            }
        }

        hp.start()
        hotplug = hp

        // Watch for macOS wake from sleep — USB needs reconnect after sleep
        // MUST register on main thread for NSWorkspace notifications to fire
        DispatchQueue.main.async { [weak self] in
            guard let self, self.enabled else { return }
            let center = NSWorkspace.shared.notificationCenter

            let wakeObserver = center.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, self.enabled else { return }
                log("[Wake] macOS woke from sleep — reconnecting in 3s...")
                self.usbQueue.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    guard let self, self.enabled else { return }
                    self.running = false
                    self.device?.close()
                    self.device = nil
                    log("[Wake] Attempting reconnect...")
                    self.connectAndRun()
                }
            }

            let screenObserver = center.addObserver(
                forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, self.enabled else { return }
                if !self.running {
                    log("[Wake] Screens woke — reconnecting in 2s...")
                    self.usbQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                        guard let self, self.enabled, !self.running else { return }
                        self.connectAndRun()
                    }
                }
            }

            self.observerLock.lock()
            self.workspaceObservers.append(contentsOf: [wakeObserver, screenObserver])
            self.observerLock.unlock()
        }
    }

    private func removeWorkspaceObservers() {
        observerLock.lock()
        let observers = workspaceObservers
        workspaceObservers.removeAll()
        observerLock.unlock()

        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
    }

    private func postStatus(
        _ state: AppRuntimeState,
        deviceInfo: DeviceInfo? = nil,
        message: String
    ) {
        let status = EngineStatus(
            state: state,
            deviceInfo: deviceInfo,
            message: message,
            frameCount: frameCount,
            lastFrameSize: lastFrameSize,
            customScriptSnapshot: monitorRenderer.customScriptSnapshot())
        if status.connected, message == "Active" {
            let now = Date()
            guard now.timeIntervalSince(lastProgressStatusAt) >= 1 else { return }
            lastProgressStatusAt = now
        }
        statusCallback(status)
    }
}
