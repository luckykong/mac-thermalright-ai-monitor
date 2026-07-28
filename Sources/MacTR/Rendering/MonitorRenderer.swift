// MonitorRenderer.swift — System telemetry + AI agents dashboard
//
// Left: compact CPU/GPU/MEMORY + NETWORK/CUSTOM/CLOCK grid
// Right: wide, two-column AI AGENTS activity panel
// The AGENTS panel shows each agent's current activity (top) and today's
// token usage + quota (bottom), sourced from local session transcripts.

import AppKit
import CoreGraphics
import Foundation

final class MonitorRenderer: FrameRenderer, @unchecked Sendable {

    private let collector = SystemMetricsCollector()
    private let agentCollector = AgentUsageCollector()
    private let scriptRunner = CustomScriptRunner()

    // Background metrics collection — decoupled from frame loop for consistent refresh
    private let metricsQueue = DispatchQueue(label: "com.thermalvision.metrics")
    private var metricsRunning = false
    private var metricsGeneration: UInt64 = 0
    private let lock = NSLock()

    // Cached snapshots (written by metricsQueue, read by render thread)
    private var _cpu: CPUSnapshot?
    private var _mem: MemorySnapshot?
    private var _gpu: GPUSnapshot?
    private var _network: NetworkSnapshot?
    private var _fans: FanSnapshot?
    private var _temp: TemperatureSnapshot?
    private var _agents: AgentsSnapshot?
    private var _sys: SystemSnapshot?
    private var _networkRxHistory: [Double] = []
    private var _networkTxHistory: [Double] = []
    let networkGraphBars = 60
    private var performanceMode: PerformanceMode = .balanced
    private var customScriptConfiguration = CustomScriptConfiguration.disabled
    private var customScriptFontMode: CustomScriptFontMode = .automatic
    private var language: AppLanguage = .simplifiedChinese

    // Reusable CGContext — avoids allocating 3.6MB every 0.5s (prevents CG raster data leak)
    private var reusableCtx: CGContext?

    let englishDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEE · MMM d"
        return formatter
    }()

    let chineseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日 EEE"
        return formatter
    }()

    let hourMinuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    let secondsFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "ss"
        return formatter
    }()

    // Test mode (--test-flash): force both columns into the flashing state until
    // this deadline, to preview the alert visuals without waiting for a real event
    private var testFlashUntil: Date?

    func enableTestFlash(seconds: TimeInterval) {
        testFlashUntil = Date().addingTimeInterval(seconds)
        log("[Metrics] Test flash enabled for \(Int(seconds))s")
    }

    private func withAttention(_ u: AgentUsage) -> AgentUsage {
        AgentUsage(available: u.available,
                   todayInputTokens: u.todayInputTokens,
                   todayOutputTokens: u.todayOutputTokens,
                   secondsSinceActive: u.secondsSinceActive,
                   project: u.project, activity: u.activity,
                   quotaWindows: u.quotaWindows,
                   needsAttention: true)
    }

    func configure(
        performanceMode: PerformanceMode,
        customScript: CustomScriptConfiguration,
        language: AppLanguage,
        customScriptFontMode: CustomScriptFontMode = .automatic
    ) {
        lock.lock()
        self.performanceMode = performanceMode
        self.language = language
        self.customScriptFontMode = customScriptFontMode
        let scriptChanged = customScript != customScriptConfiguration
        customScriptConfiguration = customScript
        let running = metricsRunning
        lock.unlock()
        if running, scriptChanged {
            scriptRunner.update(configuration: customScript)
        }
    }

    func runCustomScriptNow() {
        scriptRunner.runNow()
    }

    func customScriptSnapshot() -> CustomScriptSnapshot {
        scriptRunner.currentSnapshot()
    }

    /// Start background metrics collection. Call before first render().
    /// Primes all metrics synchronously, then starts async collection loop.
    /// Safe to call multiple times — returns immediately if already running.
    func startMetrics() {
        lock.lock()
        guard !metricsRunning else { lock.unlock(); return }
        metricsRunning = true
        metricsGeneration &+= 1
        let generation = metricsGeneration
        let scriptConfiguration = customScriptConfiguration
        lock.unlock()
        log("[Metrics] Starting collection...")
        scriptRunner.start(configuration: scriptConfiguration)
        // First pass primes all counters; CPU/network deltas will be zero.
        let cpu0 = collector.collectCPU()
        let mem = collector.collectMemory()
        let gpu = collector.collectGPU()
        let network0 = collector.collectNetwork()
        let fans = collector.collectFans()
        let temp = collector.collectTemperature()
        let agents = agentCollector.collect()
        let sys = collector.collectSystem()
        lock.lock()
        _cpu = cpu0; _mem = mem; _gpu = gpu; _network = network0; _fans = fans
        _temp = temp; _agents = agents; _sys = sys
        appendNetworkHistoryLocked(network0)
        lock.unlock()

        // Second pass gets real CPU and network deltas.
        Thread.sleep(forTimeInterval: 0.3)
        let cpu1 = collector.collectCPU()
        let network1 = collector.collectNetwork()
        lock.lock()
        _cpu = cpu1; _network = network1
        appendNetworkHistoryLocked(network1)
        lock.unlock()

        // Start async collection loop
        metricsQueue.async { [weak self] in
            self?.metricsLoop(generation: generation)
        }
    }

    func stopMetrics() {
        log("[Metrics] Stopping collection")
        lock.lock()
        metricsRunning = false
        metricsGeneration &+= 1
        lock.unlock()
        scriptRunner.stop()
    }

    /// Adaptive interval for the current visual state. A fan keeps a modest
    /// animation cadence, while active agent/CPU animation gets the selected mode's
    /// faster cadence. Idle content stays at the mode's low-power interval.
    func preferredFrameInterval() -> Double {
        lock.lock()
        let mode = performanceMode
        // Heavy CPU → Pikachu crackles with electricity, worth animating smoothly
        let active = (_cpu?.total ?? 0) > 55
            || (_agents?.claude.isWorking ?? false)
            || (_agents?.claude.needsAttention ?? false)
            || (_agents?.codex.isWorking ?? false)
            || (_agents?.codex.needsAttention ?? false)
        let hasFan = _fans?.available == true && !(_fans?.fans.isEmpty ?? true)
        lock.unlock()
        if active { return 1.0 / mode.activeFramesPerSecond }
        if hasFan { return 1.0 / mode.fanFramesPerSecond }
        return mode.idleFrameInterval
    }

    private func metricsLoop(generation: UInt64) {
        log("[Metrics] Loop started on metricsQueue")
        var lastSlow = Date.distantPast
        var lastAgents = Date.distantPast
        while true {
            lock.lock()
            let running = metricsRunning && metricsGeneration == generation
            let mode = performanceMode
            lock.unlock()
            guard running else { break }

            // This loop is one long-lived GCD work item. Without an explicit pool,
            // Foundation bridge objects created while scanning JSONL transcripts
            // never reached the queue's work-item drain and accumulated indefinitely.
            autoreleasepool {
                // Fast metrics every tick
                let cpu = collector.collectCPU()
                let mem = collector.collectMemory()
                let network = collector.collectNetwork()
                lock.lock()
                _cpu = cpu; _mem = mem; _network = network
                appendNetworkHistoryLocked(network)
                lock.unlock()

                let now = Date()
                if now.timeIntervalSince(lastSlow) >= mode.slowMetricsInterval {
                    let gpu = collector.collectGPU()
                    let temp = collector.collectTemperature()
                    let fans = collector.collectFans()
                    let sys = collector.collectSystem()
                    lock.lock()
                    _gpu = gpu; _temp = temp; _fans = fans
                    _sys = sys
                    lock.unlock()
                    lastSlow = now
                }
                if now.timeIntervalSince(lastAgents) >= mode.agentMetricsInterval {
                    let agents = agentCollector.collect()
                    lock.lock()
                    _agents = agents
                    lock.unlock()
                    lastAgents = now
                }
            }

            Thread.sleep(forTimeInterval: mode.fastMetricsInterval)
        }
        log("[Metrics] Loop exited (metricsRunning=false)")
    }

    /// Caller must hold `lock`.
    private func appendNetworkHistoryLocked(_ network: NetworkSnapshot) {
        guard network.available else { return }
        _networkRxHistory.append(max(network.rxBytesPerSec, 0))
        _networkTxHistory.append(max(network.txBytesPerSec, 0))
        let historyLimit = max(
            1, Int(ceil(30 / performanceMode.fastMetricsInterval)))
        if _networkRxHistory.count > historyLimit {
            _networkRxHistory.removeFirst(_networkRxHistory.count - historyLimit)
        }
        if _networkTxHistory.count > historyLimit {
            _networkTxHistory.removeFirst(_networkTxHistory.count - historyLimit)
        }
    }

    // Showcase mode drives the display with deterministic sample data for documentation.
    // Set before render(); the frame loop keeps its normal
    // memory-safe path (reusable context + autoreleasepool) and animations stay live.
    var demoMode = false
    /// Preserve real system metrics while replacing local project names, messages,
    /// token totals and quota in a screenshot intended for public documentation.
    var redactAgentDetails = false

    struct DashboardData {
        let cpu: CPUSnapshot
        let mem: MemorySnapshot
        let gpu: GPUSnapshot?
        let network: NetworkSnapshot?
        let fans: FanSnapshot?
        let temp: TemperatureSnapshot
        let sys: SystemSnapshot?
        let agents: AgentsSnapshot
        let script: CustomScriptSnapshot
        let rxHistory: [Double]
        let txHistory: [Double]
        let networkSampleInterval: Double
    }


    /// Render one demo frame with the showcase data (for --snapshot).
    func renderSimulated(coreCount: Int) -> CGImage? {
        lock.lock()
        let renderLanguage = language
        let renderScriptFontMode = customScriptFontMode
        lock.unlock()
        let data = demoData(coreCount: coreCount, language: renderLanguage)
        let w = Layout.width, h = Layout.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        Draw.gradientBackground(ctx)
        renderDashboard(
            ctx,
            data: data,
            language: renderLanguage,
            customScriptFontMode: renderScriptFontMode)
        return ctx.makeImage()
    }

    // Serializes render() callers — the USB frame loop and the on-Mac preview
    // window can both render around a connect/disconnect transition, and they
    // share reusableCtx + sparkline history
    private let renderMutex = NSLock()

    func render() -> CGImage? {
        renderMutex.lock()
        defer { renderMutex.unlock() }

        lock.lock()
        let renderLanguage = language
        let renderScriptFontMode = customScriptFontMode
        lock.unlock()

        var data: DashboardData
        if demoMode {
            data = demoData(language: renderLanguage)
        } else {
            // Read cached metrics (never blocks — uses latest available values)
            lock.lock()
            guard let c = _cpu, let m = _mem, let tp = _temp, let a = _agents else {
                lock.unlock(); return nil
            }
            let visibleAgents = redactAgentDetails
                ? documentationAgents(language: renderLanguage)
                : a
            data = DashboardData(
                cpu: c, mem: m, gpu: _gpu, network: _network, fans: _fans,
                temp: tp, sys: _sys, agents: visibleAgents,
                script: redactAgentDetails
                    ? documentationScript() : scriptRunner.currentSnapshot(),
                rxHistory: _networkRxHistory, txHistory: _networkTxHistory,
                networkSampleInterval: performanceMode.fastMetricsInterval)
            lock.unlock()
        }

        if let until = testFlashUntil, Date() < until {
            data = DashboardData(
                cpu: data.cpu, mem: data.mem, gpu: data.gpu,
                network: data.network, fans: data.fans, temp: data.temp,
                sys: data.sys,
                agents: AgentsSnapshot(
                    claude: withAttention(data.agents.claude),
                    codex: withAttention(data.agents.codex)),
                script: data.script,
                rxHistory: data.rxHistory, txHistory: data.txHistory,
                networkSampleInterval: data.networkSampleInterval)
        }

        // Reuse CGContext to prevent CG raster data memory growth
        let w = Layout.width
        let h = Layout.height
        if reusableCtx == nil {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            reusableCtx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx = reusableCtx else { return nil }

        // Reset transform and clear for new frame
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        // Background
        Draw.gradientBackground(ctx)

        renderDashboard(
            ctx,
            data: data,
            language: renderLanguage,
            customScriptFontMode: renderScriptFontMode)

        let image = ctx.makeImage()
        ctx.restoreGState()
        return image
    }

    private func renderDashboard(
        _ ctx: CGContext,
        data: DashboardData,
        language: AppLanguage,
        customScriptFontMode: CustomScriptFontMode
    ) {
        let agentsBusy = data.agents.claude.isWorking || data.agents.claude.needsAttention
            || data.agents.codex.isWorking || data.agents.codex.needsAttention
        renderCPU(
            ctx, cpu: data.cpu, temp: data.temp,
            agentsBusy: agentsBusy, language: language)
        renderGPU(ctx, gpu: data.gpu, temp: data.temp, language: language)
        renderMemory(ctx, mem: data.mem, language: language)
        renderNetwork(
            ctx, network: data.network,
            rxHistory: data.rxHistory, txHistory: data.txHistory,
            sampleInterval: data.networkSampleInterval,
            language: language)
        renderCustomScript(
            ctx,
            snapshot: data.script,
            language: language,
            fontMode: customScriptFontMode)
        renderClockAndFan(
            ctx, fans: data.fans, sys: data.sys,
            agentsBusy: agentsBusy, language: language)
        renderAgents(ctx, agents: data.agents, language: language)
    }



}
