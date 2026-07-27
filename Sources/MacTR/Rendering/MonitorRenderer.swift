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
    private let networkGraphBars = 60
    private var performanceMode: PerformanceMode = .balanced
    private var customScriptConfiguration = CustomScriptConfiguration.disabled
    private var customScriptFontMode: CustomScriptFontMode = .automatic
    private var language: AppLanguage = .simplifiedChinese

    // Reusable CGContext — avoids allocating 3.6MB every 0.5s (prevents CG raster data leak)
    private var reusableCtx: CGContext?

    private let englishDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEE · MMM d"
        return formatter
    }()

    private let chineseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "M月d日 EEE"
        return formatter
    }()

    private let hourMinuteFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private let secondsFormatter: DateFormatter = {
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
                   quotaUsedPercent: u.quotaUsedPercent,
                   quotaResetsAt: u.quotaResetsAt,
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

    private struct DashboardData {
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

    private func documentationAgents(language: AppLanguage) -> AgentsSnapshot {
        let claudeActivity = language == .simplifiedChinese
            ? "已完成今日任务，等待下一步指令。"
            : "Today's task is complete. Waiting for the next instruction."
        let codexActivity = language == .simplifiedChinese
            ? "正在验证显示布局、性能与发布包。"
            : "Validating the display layout, performance, and release package."
        let codexStep = language == .simplifiedChinese
            ? "验证真实 LCD 输出"
            : "Validate output on the physical LCD"
        return AgentsSnapshot(
            claude: AgentUsage(
                available: true,
                todayInputTokens: 8_420_000,
                todayOutputTokens: 126_000,
                secondsSinceActive: 180,
                project: "example-project",
                activity: claudeActivity,
                needsAttention: false,
                isWorking: false),
            codex: AgentUsage(
                available: true,
                todayInputTokens: 12_600_000,
                todayOutputTokens: 284_000,
                secondsSinceActive: 4,
                project: "dashboard",
                activity: codexActivity,
                quotaUsedPercent: 34,
                quotaResetsAt: Date().addingTimeInterval(6 * 86400),
                needsAttention: false,
                isWorking: true,
                stepCurrent: 4,
                stepTotal: 6,
                stepText: codexStep))
    }

    private func documentationScript() -> CustomScriptSnapshot {
        CustomScriptSnapshot(
            state: .succeeded,
            title: "BACKUP",
            output: "STATUS  OK\nREPOS   12\nLAST    19:30\nNEXT    20:00",
            message: nil,
            lastRunAt: Date().addingTimeInterval(-30),
            exitCode: 0)
    }

    /// Deterministic showcase data. CPU cores gently wave over time so the demo looks
    /// alive on the LCD; everything else is fixed so documentation stays reproducible.
    private func demoData(
        coreCount requestedCoreCount: Int = 10,
        language: AppLanguage
    ) -> DashboardData {
        let tt = Date().timeIntervalSince1970
        let coreCount = max(requestedCoreCount, 1)
        let cores: [Double] = (0..<coreCount).map { i in
            let wave: Double = sin(tt * 1.3 + Double(i) * 0.9)
            return 25.0 + 55.0 * (0.5 + 0.5 * wave)
        }
        let total: Double = cores.reduce(0.0, +) / Double(coreCount)
        let cpu = CPUSnapshot(perCore: cores, total: total,
                              loadAvg: (3.5, 4.2, 3.8),
                              pCoreCount: max(coreCount - 2, 1))
        let gb: UInt64 = 1024 * 1024 * 1024
        let mem = MemorySnapshot(
            total: 32 * gb, active: 9 * gb, wired: 3 * gb,
            compressed: 2 * gb, available: 18 * gb,
            swapUsed: 512 * 1024 * 1024, swapTotal: 4 * gb,
            swapInPerSec: 0, swapOutPerSec: 0, swapAvailable: true, pressure: 1)
        let gpu = GPUSnapshot(
            available: true, name: "Apple M4 Pro", cores: 20,
            deviceUtil: 63, rendererUtil: 58, tilerUtil: 41,
            memUsedMB: 2860, memAllocMB: 4096)
        let historyCount = networkGraphBars
        let rxHistory = (0..<historyCount).map { i -> Double in
            let wave = 0.55 + 0.45 * sin(Double(i) * 0.31 + tt * 0.25)
            return 4_000_000 + 38_000_000 * wave
        }
        let txHistory = (0..<historyCount).map { i -> Double in
            let wave = 0.5 + 0.5 * sin(Double(i) * 0.43 + 1.8 + tt * 0.20)
            return 500_000 + 9_000_000 * wave
        }
        let network = NetworkSnapshot(
            available: true,
            rxBytesPerSec: rxHistory.last ?? 0,
            txBytesPerSec: txHistory.last ?? 0)
        let fans = FanSnapshot(
            available: true,
            fans: [
                FanReading(name: "System", currentRPM: 2_180, minRPM: 1_200, maxRPM: 5_800),
            ])
        let temp = TemperatureSnapshot(cpuTemp: 52, gpuTemp: 45, thermalState: 0)
        let sys = SystemSnapshot(uptimeSeconds: 27 * 3600 + 3 * 60, processCount: 612)
        let claudeActivity = language == .simplifiedChinese
            ? """
              已完成 AI Agents 面板的三项优化，改动集中在两个文件：

              | 文件 | 改动 |
              |---|---|
              | Collector | 解析消息与待办 |
              | Renderer | 表格化排版 |
              """
            : """
              Completed three AI Agents panel improvements across two files:

              | File | Change |
              |---|---|
              | Collector | Parse messages and plans |
              | Renderer | Structured table layout |
              """
        let codexActivity = language == .simplifiedChinese
            ? """
              已完成部署，四个服务全部推送到 `main`：

              | 服务 | 提交 | 文件 |
              |---|---|---:|
              | `api-gateway` | `a4872c56` | 24 |
              | `auth-service` | `4d6934de` | 10 |
              | `web-client` | `9b0e17aa` | 32 |
              | `job-worker` | `ac02bea6` | 88 |
              """
            : """
              Deployment completed. All four services were pushed to `main`:

              | Service | Commit | Files |
              |---|---|---:|
              | `api-gateway` | `a4872c56` | 24 |
              | `auth-service` | `4d6934de` | 10 |
              | `web-client` | `9b0e17aa` | 32 |
              | `job-worker` | `ac02bea6` | 88 |
              """
        let agents = AgentsSnapshot(
            claude: AgentUsage(available: true,
                               todayInputTokens: 48_300_000, todayOutputTokens: 512_000,
                               secondsSinceActive: 3, project: "MacTR",
                               activity: claudeActivity,
                               isWorking: true,
                               stepCurrent: 3, stepTotal: 4,
                               stepText: language == .simplifiedChinese
                                   ? "渲染 Claude 消息表格"
                                   : "Render the Claude message table"),
            codex: AgentUsage(available: true,
                              todayInputTokens: 60_100_000, todayOutputTokens: 375_000,
                              secondsSinceActive: 6, project: "web-service",
                              activity: codexActivity,
                              quotaUsedPercent: 57,
                              quotaResetsAt: Date().addingTimeInterval(3600 * 24 * 6),
                              isWorking: true,
                              stepCurrent: 4, stepTotal: 6,
                              stepText: language == .simplifiedChinese
                                  ? "部署到预发环境并跑冒烟测试"
                                  : "Deploy to staging and run smoke tests"))
        let script = CustomScriptSnapshot(
            state: .succeeded,
            title: language == .simplifiedChinese ? "天气" : "WEATHER",
            output: language == .simplifiedChinese
                ? "广州 · 02:20\n未来两小时无降水\n当前 0  峰值 0\n2h累计 0 mm\n雨势············"
                : "GUANGZHOU · 02:20\nNO RAIN FOR 2 HOURS\nNOW 0  PEAK 0\n2H TOTAL 0 mm\nRAIN ············",
            message: nil,
            lastRunAt: Date().addingTimeInterval(-30),
            exitCode: 0)
        return DashboardData(
            cpu: cpu, mem: mem, gpu: gpu, network: network, fans: fans,
            temp: temp, sys: sys, agents: agents, script: script,
            rxHistory: rxHistory, txHistory: txHistory,
            networkSampleInterval: 0.5)
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

    // MARK: - Compact System Cards

    private func renderCPU(
        _ ctx: CGContext,
        cpu: CPUSnapshot,
        temp: TemperatureSnapshot,
        agentsBusy: Bool,
        language: AppLanguage
    ) {
        let x = Layout.systemTopX(0)
        let y = Layout.panelY
        let w = Layout.systemTopColumnWidth
        let h = Layout.systemTopHeight

        Draw.panel(ctx, x: x, y: y, w: w, h: h, accent: Color.blue)
        Draw.text(ctx, "CPU", x: x + 14, y: y + 11,
                  font: Fonts.system(18, weight: .bold), color: Color.blue)
        drawCompactGauge(
            ctx, cx: x + 48, cy: y + 76, percent: cpu.total,
            color: Color.forPercent(cpu.total), dark: Color.forPercentDark(cpu.total))

        let statX = x + 88
        Draw.text(ctx, language.text(.cpuTemperature), x: statX, y: y + 44,
                  font: Fonts.system(10, weight: .semibold), color: Color.textL)
        let tempString = temp.cpuTemp.map { String(format: "%.0f°C", $0) } ?? "N/A"
        let tempColor: CGColor
        if let value = temp.cpuTemp {
            tempColor = value > 65 ? Color.red : (value > 50 ? Color.orange : Color.green)
        } else {
            tempColor = Color.textD
        }
        Draw.text(ctx, tempString, x: statX, y: y + 57,
                  font: Fonts.system(17, weight: .bold), color: tempColor)

        Draw.text(ctx, language.text(.cpuLoadOneMinute), x: statX, y: y + 81,
                  font: Fonts.system(10, weight: .semibold), color: Color.textL)
        Draw.text(ctx, String(format: "%.1f", cpu.loadAvg.0), x: statX, y: y + 94,
                  font: Fonts.system(17, weight: .semibold), color: Color.textS)

        if let pika = PikachuAsset.image {
            let t = Date().timeIntervalSince1970
            let size: CGFloat = 49
            var rect = CGRect(x: CGFloat(x + w - 65), y: CGFloat(y + 48),
                              width: size, height: size)
            if agentsBusy {
                rect.origin.y -= CGFloat(abs(sin(t * .pi * 2)) * 3)
            }
            drawElectricity(ctx, around: rect, intensity: cpu.total, t: t)
            drawImageUpright(
                ctx, pika, in: rect,
                flipX: agentsBusy && Int(t * 2) % 4 >= 2)
        }

        drawCoreStrip(
            ctx, values: cpu.perCore, pCoreCount: cpu.pCoreCount,
            x: x + 14, y: y + h - 27, w: w - 28, h: 13)
    }

    private func renderGPU(
        _ ctx: CGContext,
        gpu: GPUSnapshot?,
        temp: TemperatureSnapshot,
        language: AppLanguage
    ) {
        let x = Layout.systemTopX(1)
        let y = Layout.panelY
        let w = Layout.systemTopColumnWidth
        let h = Layout.systemTopHeight

        Draw.panel(ctx, x: x, y: y, w: w, h: h, accent: Color.magenta)
        Draw.text(ctx, "GPU", x: x + 14, y: y + 11,
                  font: Fonts.system(18, weight: .bold), color: Color.magenta)

        guard let gpu, gpu.available else {
            Draw.centeredText(ctx, "N/A", cx: x + w / 2, y: y + 61,
                              font: Fonts.system(25, weight: .semibold), color: Color.textD)
            return
        }

        let gpuName = truncate(
            gpu.name, font: Fonts.system(11, weight: .medium),
            maxW: CGFloat(w - 70))
        Draw.text(ctx, gpuName, x: x + 66, y: y + 15,
                  font: Fonts.system(11, weight: .medium), color: Color.textL)

        drawCompactGauge(
            ctx, cx: x + 48, cy: y + 76, percent: Double(gpu.deviceUtil),
            color: Color.forPercent(Double(gpu.deviceUtil)),
            dark: Color.forPercentDark(Double(gpu.deviceUtil)))

        let sx = x + 91
        let sw = w - 105
        drawLabeledMiniBar(
            ctx, label: language.text(.gpuRender), value: Double(gpu.rendererUtil),
            x: sx, y: y + 43, w: sw, color: Color.magenta)
        drawLabeledMiniBar(
            ctx, label: language.text(.gpuTiler), value: Double(gpu.tilerUtil),
            x: sx, y: y + 75, w: sw, color: Color.purple)

        let usedGB = Double(gpu.memUsedMB) / 1024
        let allocGB = Double(gpu.memAllocMB) / 1024
        let memoryString = allocGB > 0
            ? String(
                format: "\(language.text(.gpuMemory)) %.1f / %.1f GB",
                usedGB, allocGB)
            : String(format: "\(language.text(.gpuMemory)) %.1f GB", usedGB)
        Draw.text(ctx, memoryString, x: sx, y: y + 108,
                  font: Fonts.system(11, weight: .medium), color: Color.textS)
        if let gpuTemp = temp.gpuTemp {
            let value = String(format: "%.0f°C", gpuTemp)
            let font = Fonts.system(11, weight: .semibold)
            let width = (value as NSString).size(withAttributes: [.font: font]).width
            Draw.text(ctx, value, x: Int(CGFloat(x + w - 14) - width), y: y + 108,
                      font: font, color: gpuTemp > 70 ? Color.red : Color.green)
        }
    }

    private func renderMemory(
        _ ctx: CGContext,
        mem: MemorySnapshot,
        language: AppLanguage
    ) {
        let x = Layout.systemTopX(2)
        let y = Layout.panelY
        let w = Layout.systemTopColumnWidth
        let h = Layout.systemTopHeight
        let bytesPerGB = 1024.0 * 1024 * 1024
        let totalGB = Double(mem.total) / bytesPerGB
        let usedGB = Double(mem.total > mem.available ? mem.total - mem.available : 0) / bytesPerGB
        let pct = mem.total > 0 ? mem.percent : 0
        let pressureColor = Color.forPressure(mem.pressure)

        Draw.panel(ctx, x: x, y: y, w: w, h: h, accent: Color.green)
        Draw.text(ctx, language.text(.memory), x: x + 14, y: y + 11,
                  font: Fonts.system(18, weight: .bold), color: Color.green)
        Draw.text(ctx, String(format: "%.0f GB", totalGB), x: x + w - 62, y: y + 14,
                  font: Fonts.system(11, weight: .medium), color: Color.textL)

        drawCompactGauge(
            ctx, cx: x + 48, cy: y + 76, percent: pct,
            color: pressureColor, dark: Color.forPressureDark(mem.pressure))

        let pressureText = mem.pressure >= 4 ? language.text(.memoryCritical)
            : (mem.pressure >= 2
                ? language.text(.memoryPressure)
                : language.text(.memoryNormal))
        Draw.text(ctx, pressureText, x: x + 91, y: y + 43,
                  font: Fonts.system(11, weight: .bold), color: pressureColor)
        Draw.text(ctx, String(format: "%.1f / %.0f GB", usedGB, totalGB),
                  x: x + 91, y: y + 61,
                  font: Fonts.system(18, weight: .semibold), color: Color.textW)

        let activeGB = Double(mem.active) / bytesPerGB
        let wiredGB = Double(mem.wired) / bytesPerGB
        let compressedGB = Double(mem.compressed) / bytesPerGB
        let availableGB = Double(mem.available) / bytesPerGB
        let breakdown = String(
            format: language.text(.memoryBreakdown), activeGB, wiredGB,
            compressedGB, availableGB)
        Draw.text(ctx, breakdown, x: x + 14, y: y + 99,
                  font: Fonts.system(10, weight: .medium), color: Color.textS)
        drawStackedBar(
            ctx,
            values: [activeGB, wiredGB, compressedGB, availableGB],
            colors: [Color.green, Color.orange, Color.purple, Color.cyan],
            x: x + 14, y: y + h - 27, w: w - 28, h: 10)
    }

    private func renderNetwork(
        _ ctx: CGContext,
        network: NetworkSnapshot?,
        rxHistory: [Double],
        txHistory: [Double],
        sampleInterval: Double,
        language: AppLanguage
    ) {
        let x = Layout.networkX
        let y = Layout.systemBottomY
        let w = Layout.networkWidth
        let h = Layout.systemBottomHeight

        Draw.panel(ctx, x: x, y: y, w: w, h: h, accent: Color.cyan)
        Draw.text(ctx, language.text(.network), x: x + 14, y: y + 11,
                  font: Fonts.system(18, weight: .bold), color: Color.cyan)
        let rangeLabel = language.text(.thirtySeconds)
        let rangeFont = Fonts.system(10, weight: .semibold)
        let rangeWidth = (rangeLabel as NSString)
            .size(withAttributes: [.font: rangeFont]).width
        Draw.text(
            ctx, rangeLabel, x: Int(CGFloat(x + w - 14) - rangeWidth), y: y + 15,
            font: rangeFont, color: Color.textD)

        guard let network, network.available else {
            Draw.centeredText(ctx, "N/A", cx: x + w / 2, y: y + 116,
                              font: Fonts.system(25, weight: .semibold), color: Color.textD)
            return
        }

        let down = "\(language.text(.download)) \(Draw.formatBytesPerSec(network.rxBytesPerSec))"
        let up = "\(language.text(.upload)) \(Draw.formatBytesPerSec(network.txBytesPerSec))"
        let downColor = Color.forNetworkRate(
            network.rxBytesPerSec, normal: Color.green)
        let upColor = Color.forNetworkRate(
            network.txBytesPerSec, normal: Color.cyan)
        let rateFont = Fonts.system(14, weight: .semibold)
        Draw.text(ctx, down, x: x + 14, y: y + 43,
                  font: rateFont, color: downColor)
        let upWidth = (up as NSString).size(withAttributes: [.font: rateFont]).width
        Draw.text(ctx, up, x: Int(CGFloat(x + w - 14) - upWidth), y: y + 43,
                  font: rateFont, color: upColor)

        // Pad startup history on the left so bar width stays stable instead of
        // rendering a handful of oversized columns during the first 30 seconds.
        let rxValues = paddedNetworkHistory(rxHistory, sampleInterval: sampleInterval)
        let txValues = paddedNetworkHistory(txHistory, sampleInterval: sampleInterval)
        Draw.mirrorBarChart(
            ctx,
            topValues: rxValues, bottomValues: txValues,
            x: x + 14, y: y + 72, w: w - 28, h: h - 88,
            topColor: Color.green, bottomColor: Color.cyan,
            topCallout: "↓ \(Draw.formatBytesPerSec(network.rxBytesPerSec))",
            bottomCallout: "↑ \(Draw.formatBytesPerSec(network.txBytesPerSec))")
    }

    private func paddedNetworkHistory(
        _ values: [Double],
        sampleInterval: Double
    ) -> [Double] {
        let expectedSamples = max(1, Int(ceil(30 / max(sampleInterval, 0.1))))
        let recent = Array(values.suffix(expectedSamples))
        let padded = Array(repeating: 0, count: max(expectedSamples - recent.count, 0))
            + recent
        guard padded.count != networkGraphBars else { return padded }

        // Resample the mode-dependent 30-second history to a stable 60 bars.
        return (0..<networkGraphBars).map { index in
            let source = min(
                Int(Double(index) / Double(networkGraphBars) * Double(padded.count)),
                padded.count - 1)
            return padded[source]
        }
    }

    private func renderCustomScript(
        _ ctx: CGContext,
        snapshot: CustomScriptSnapshot,
        language: AppLanguage,
        fontMode: CustomScriptFontMode
    ) {
        let x = Layout.scriptX
        let y = Layout.systemBottomY
        let w = Layout.scriptWidth
        let h = Layout.systemBottomHeight
        let accent = Color.purple

        Draw.panel(ctx, x: x, y: y, w: w, h: h, accent: accent)
        let title = truncate(
            snapshot.title.uppercased(),
            font: Fonts.system(18, weight: .bold),
            maxW: CGFloat(w - 98))
        Draw.text(ctx, title, x: x + 14, y: y + 11,
                  font: Fonts.system(18, weight: .bold), color: accent)

        let stateText: String
        let stateColor: CGColor
        switch snapshot.state {
        case .succeeded:
            stateText = language.text(.scriptStateOK); stateColor = Color.green
        case .running:
            stateText = language.text(.scriptStateRun); stateColor = Color.cyan
        case .failed, .timedOut, .missing, .invalid:
            stateText = language.text(.scriptStateError); stateColor = Color.red
        case .ready:
            stateText = language.text(.scriptStateReady); stateColor = Color.textS
        case .disabled:
            stateText = language.text(.scriptStateOff); stateColor = Color.textD
        case .unconfigured:
            stateText = language.text(.scriptStateSetup); stateColor = Color.orange
        }
        let stateFont = Fonts.system(11, weight: .bold)
        let stateWidth = (stateText as NSString)
            .size(withAttributes: [.font: stateFont]).width
        let dotX = CGFloat(x + w - 18) - stateWidth - 9
        ctx.setFillColor(stateColor)
        ctx.fillEllipse(in: CGRect(x: dotX, y: CGFloat(y + 18), width: 6, height: 6))
        Draw.text(ctx, stateText, x: Int(dotX + 10), y: y + 13,
                  font: stateFont, color: stateColor)

        if snapshot.state == .disabled || snapshot.state == .unconfigured {
            let primary = snapshot.state == .disabled
                ? language.text(.scriptOff) : language.text(.addScript)
            Draw.centeredText(ctx, primary, cx: x + w / 2, y: y + 104,
                              font: Fonts.system(25, weight: .semibold),
                              color: snapshot.state == .disabled ? Color.textD : Color.orange)
            Draw.centeredText(
                ctx,
                snapshot.state == .disabled
                    ? language.text(.enableInSettings)
                    : language.text(.customCardSettingsPath),
                cx: x + w / 2, y: y + 139,
                font: Fonts.system(13, weight: .medium), color: Color.textL)
            return
        }

        var bodyY = y + 50
        if let message = snapshot.message,
           [.failed, .timedOut, .missing, .invalid].contains(snapshot.state)
        {
            Draw.text(
                ctx,
                truncate(message, font: Fonts.system(12, weight: .semibold),
                         maxW: CGFloat(w - 28)),
                x: x + 14, y: bodyY,
                font: Fonts.system(12, weight: .semibold), color: Color.red)
            bodyY += 23
        }

        let output = snapshot.output.isEmpty
            ? (snapshot.state == .running
                ? language.text(.runningEllipsis)
                : language.text(.noOutput))
            : snapshot.output
        let availableHeight = max(y + h - 37 - bodyY, 1)
        let textLayout = CustomScriptTypography.layout(
            output: output,
            mode: fontMode,
            maxWidth: CGFloat(w - 28),
            availableHeight: availableHeight)
        let outputFont = Fonts.mono(textLayout.fontSize)
        bodyY += textLayout.topInset
        for (index, line) in textLayout.lines.enumerated() {
            let lineY = bodyY + index * textLayout.lineHeight
            if textLayout.centered {
                Draw.centeredText(
                    ctx,
                    line,
                    cx: x + w / 2,
                    y: lineY,
                    font: outputFont,
                    color: Color.textW)
            } else {
                Draw.text(
                    ctx,
                    line,
                    x: x + 14,
                    y: lineY,
                    font: outputFont,
                    color: Color.textW)
            }
        }

        if let lastRunAt = snapshot.lastRunAt {
            let age = max(0, Int(Date().timeIntervalSince(lastRunAt)))
            let ageText: String
            if age < 60 {
                ageText = language == .simplifiedChinese
                    ? "\(age) 秒前" : "\(age)s ago"
            } else if age < 3600 {
                ageText = AppLocalization.format(
                    .minutesAgo, language: language, age / 60)
            } else {
                ageText = AppLocalization.format(
                    .hoursAgo, language: language, age / 3600)
            }
            let lastRunText = AppLocalization.format(
                .lastRun, language: language, ageText)
            Draw.text(ctx, lastRunText, x: x + 14, y: y + h - 27,
                      font: Fonts.system(10, weight: .semibold), color: Color.textD)
        }
    }

    private func renderClockAndFan(
        _ ctx: CGContext,
        fans: FanSnapshot?,
        sys: SystemSnapshot?,
        agentsBusy: Bool,
        language: AppLanguage
    ) {
        let x = Layout.clockX
        let y = Layout.systemBottomY
        let w = Layout.clockWidth
        let h = Layout.systemBottomHeight

        Draw.panel(ctx, x: x, y: y, w: w, h: h, accent: Color.orange)
        let now = Date()
        let dateText = language == .simplifiedChinese
            ? chineseDateFormatter.string(from: now)
            : englishDateFormatter.string(from: now).uppercased()
        Draw.centeredText(
            ctx, dateText,
            cx: x + w / 2, y: y + 15,
            font: Fonts.system(12, weight: .semibold), color: Color.textS)

        let hm = hourMinuteFormatter.string(from: now)
        let seconds = ":" + secondsFormatter.string(from: now)
        let hmFont = Fonts.mono(43)
        let secondsFont = Fonts.mono(18)
        let hmWidth = (hm as NSString).size(withAttributes: [.font: hmFont]).width
        let secondsWidth = (seconds as NSString)
            .size(withAttributes: [.font: secondsFont]).width
        let combinedX = CGFloat(x) + (CGFloat(w) - hmWidth - secondsWidth) / 2
        Draw.text(ctx, hm, x: Int(combinedX), y: y + 42,
                  font: hmFont, color: Color.textW)
        Draw.text(ctx, seconds, x: Int(combinedX + hmWidth), y: y + 65,
                  font: secondsFont, color: Color.textS)

        if let sys {
            let hours = sys.uptimeSeconds / 3600
            let minutes = (sys.uptimeSeconds % 3600) / 60
            let uptime: String
            if language == .simplifiedChinese {
                uptime = hours >= 24
                    ? "\(hours / 24)天 \(hours % 24)时"
                    : "\(hours)时 \(minutes)分"
            } else {
                uptime = hours >= 24
                    ? "\(hours / 24)d \(hours % 24)h"
                    : "\(hours)h \(minutes)m"
            }
            let summary = AppLocalization.format(
                .uptimeSummary, language: language, uptime, sys.processCount)
            Draw.centeredText(ctx, summary,
                              cx: x + w / 2, y: y + 108,
                              font: Fonts.system(10, weight: .medium),
                              color: Color.textL)
        }

        let fanLabel: String
        let fanColor: CGColor
        let fanTurnsPerSecond: Double
        let showFanRotor: Bool
        if let fans, fans.available {
            if fans.fans.isEmpty {
                fanLabel = language.text(.fanless)
                fanColor = Color.textD
                fanTurnsPerSecond = 0
                showFanRotor = false
            } else {
                let fan = fans.fans[0]
                fanLabel = String(format: "%.0f RPM", fan.currentRPM)
                    + (fans.fans.count > 1 ? " ×\(fans.fans.count)" : "")
                fanColor = Color.forPercent(fan.percentOfMax ?? min(fan.currentRPM / 60, 100))
                let normalized = fan.percentOfMax.map { $0 / 100 }
                    ?? min(max(fan.currentRPM / 6_000, 0), 1)
                fanTurnsPerSecond = 0.18 + normalized * 1.45
                showFanRotor = true
            }
        } else {
            fanLabel = language.text(.fanUnavailable)
            fanColor = Color.textD
            fanTurnsPerSecond = 0
            showFanRotor = false
        }

        let t = now.timeIntervalSince1970
        let fanFont = Fonts.system(12, weight: .semibold)
        let fanTextY = y + 142
        if showFanRotor {
            // Treat the rotor and RPM as one centered status row. This keeps the
            // animation visually tied to its value and leaves clean air above
            // Bongo Cat instead of making the rotor look like part of its head.
            let rotorFootprint: CGFloat = 20
            let rotorTextGap: CGFloat = 7
            let labelWidth = (fanLabel as NSString)
                .size(withAttributes: [.font: fanFont]).width
            let rowWidth = rotorFootprint + rotorTextGap + labelWidth
            let rowX = CGFloat(x) + (CGFloat(w) - rowWidth) / 2
            drawFanRotor(
                ctx,
                center: CGPoint(
                    x: rowX + rotorFootprint / 2,
                    y: CGFloat(fanTextY) + 8),
                radius: 8,
                angle: CGFloat(t * fanTurnsPerSecond * 2 * .pi),
                color: fanColor,
                available: true)
            Draw.text(
                ctx, fanLabel,
                x: Int(rowX + rotorFootprint + rotorTextGap), y: fanTextY,
                font: fanFont, color: fanColor)
        } else {
            Draw.centeredText(
                ctx, fanLabel, cx: x + w / 2, y: fanTextY,
                font: fanFont, color: fanColor)
        }

        let catScale: CGFloat = 0.54
        drawBongoCat(
            ctx, cx: x + w / 2, baseY: y + h - 12,
            tapping: agentsBusy, phase: Int(t * 5) % 2 == 0, scale: catScale)
    }

    private func drawFanRotor(
        _ ctx: CGContext,
        center: CGPoint,
        radius: CGFloat,
        angle: CGFloat,
        color: CGColor,
        available: Bool
    ) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        ctx.setFillColor(color.copy(alpha: 0.88) ?? color)
        for index in 0..<4 {
            ctx.saveGState()
            ctx.rotate(by: CGFloat(index) * .pi / 2)
            let blade = CGMutablePath()
            blade.move(to: CGPoint(x: 2, y: -2))
            blade.addCurve(
                to: CGPoint(x: radius, y: -1),
                control1: CGPoint(x: radius * 0.42, y: -radius * 0.62),
                control2: CGPoint(x: radius * 0.96, y: -radius * 0.48))
            blade.addCurve(
                to: CGPoint(x: 2, y: 2),
                control1: CGPoint(x: radius * 0.86, y: radius * 0.25),
                control2: CGPoint(x: radius * 0.30, y: radius * 0.30))
            blade.closeSubpath()
            ctx.addPath(blade)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.setFillColor(Color.panelBG)
        ctx.fillEllipse(in: CGRect(x: -3, y: -3, width: 6, height: 6))
        ctx.setStrokeColor(color)
        ctx.setLineWidth(1.4)
        ctx.strokeEllipse(in: CGRect(
            x: -radius - 2, y: -radius - 2,
            width: (radius + 2) * 2, height: (radius + 2) * 2))
        if !available {
            ctx.move(to: CGPoint(x: -radius, y: radius))
            ctx.addLine(to: CGPoint(x: radius, y: -radius))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawCompactGauge(_ ctx: CGContext, cx: Int, cy: Int,
                                  percent: Double, color: CGColor, dark: CGColor) {
        Draw.arcGauge(
            ctx, cx: cx, cy: cy, radius: 29, percent: percent,
            color: color, colorDark: dark, thickness: 6)
        Draw.centeredText(
            ctx, String(format: "%.0f", percent), cx: cx, y: cy - 17,
            font: Fonts.system(25, weight: .bold), color: Color.textW)
        Draw.centeredText(
            ctx, "%", cx: cx, y: cy + 10,
            font: Fonts.system(10, weight: .medium), color: Color.textS)
    }

    private func drawLabeledMiniBar(_ ctx: CGContext, label: String, value: Double,
                                    x: Int, y: Int, w: Int, color: CGColor) {
        Draw.text(ctx, label, x: x, y: y,
                  font: Fonts.system(10, weight: .semibold), color: Color.textL)
        let valueText = String(format: "%.0f%%", value)
        let font = Fonts.system(10, weight: .semibold)
        let valueWidth = (valueText as NSString).size(withAttributes: [.font: font]).width
        Draw.text(ctx, valueText, x: Int(CGFloat(x + w) - valueWidth), y: y,
                  font: font, color: Color.textS)
        Draw.bar(ctx, x: x, y: y + 16, w: w, h: 6, percent: value, color: color)
    }

    private func drawCoreStrip(_ ctx: CGContext, values: [Double], pCoreCount: Int,
                               x: Int, y: Int, w: Int, h: Int) {
        guard !values.isEmpty else { return }
        let pCount = min(max(pCoreCount, 0), values.count)
        let eCount = values.count - pCount
        let reordered = Array(values[pCount...]) + Array(values[..<pCount])
        let gap: CGFloat = 2
        let barWidth = max(
            2, (CGFloat(w) - gap * CGFloat(values.count - 1)) / CGFloat(values.count))

        for (index, value) in reordered.enumerated() {
            let bx = CGFloat(x) + CGFloat(index) * (barWidth + gap)
            let background = CGRect(x: bx, y: CGFloat(y), width: barWidth, height: CGFloat(h))
            ctx.setFillColor(Color.barBG)
            ctx.addPath(CGPath(
                roundedRect: background, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()

            let fillHeight = max(2, CGFloat(h) * CGFloat(min(max(value, 0), 100) / 100))
            let fillRect = CGRect(
                x: bx, y: CGFloat(y + h) - fillHeight,
                width: barWidth, height: fillHeight)
            let color = index < eCount ? Color.cyan : Color.forPercent(value)
            ctx.setFillColor(color)
            ctx.addPath(CGPath(
                roundedRect: fillRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
        }
    }

    private func drawStackedBar(_ ctx: CGContext, values: [Double], colors: [CGColor],
                                x: Int, y: Int, w: Int, h: Int) {
        let total = values.reduce(0, +)
        let rect = CGRect(x: x, y: y, width: w, height: h)
        let path = CGPath(
            roundedRect: rect, cornerWidth: CGFloat(h) / 2,
            cornerHeight: CGFloat(h) / 2, transform: nil)
        ctx.setFillColor(Color.barBG)
        ctx.addPath(path)
        ctx.fillPath()
        guard total > 0 else { return }

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        var cursor = CGFloat(x)
        for (index, value) in values.enumerated() where index < colors.count {
            let segmentWidth = CGFloat(value / total) * CGFloat(w)
            ctx.setFillColor(colors[index])
            ctx.fill(CGRect(x: cursor, y: CGFloat(y), width: segmentWidth, height: CGFloat(h)))
            cursor += segmentWidth
        }
        ctx.restoreGState()
    }

    /// Yellow lightning crackling around Pikachu — more/brighter bolts as `intensity`
    /// (CPU %) rises. Flickers with `t` so it animates while the frame rate is high.
    private func drawElectricity(_ ctx: CGContext, around rect: CGRect,
                                 intensity: Double, t: Double) {
        let level = min(max(intensity / 100, 0), 1)
        let yellow = CGColor(red: 1.0, green: 0.9, blue: 0.15, alpha: 1)
        let bolts = 2 + Int(level * 5)
        ctx.setStrokeColor(yellow)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for i in 0..<bolts {
            if (Int(t * 14) + i * 5) % 3 == 0 { continue }
            let angle = Double(i) / Double(bolts) * 2 * .pi + t * 0.7
            let ax = rect.midX + CGFloat(cos(angle)) * rect.width * 0.44
            let ay = rect.midY + CGFloat(sin(angle)) * rect.height * 0.42
            let length = max(5, rect.width * CGFloat(0.10 + level * 0.14))
            let dx = CGFloat(cos(angle))
            let dy = CGFloat(sin(angle))
            let nx = -dy
            let ny = dx
            let jag = max(2, rect.width * CGFloat(0.035 + level * 0.025))
            ctx.setLineWidth(1 + CGFloat(level))
            ctx.move(to: CGPoint(x: ax, y: ay))
            ctx.addLine(to: CGPoint(
                x: ax + dx * length * 0.4 + nx * jag,
                y: ay + dy * length * 0.4 + ny * jag))
            ctx.addLine(to: CGPoint(
                x: ax + dx * length * 0.7 - nx * jag,
                y: ay + dy * length * 0.7 - ny * jag))
            ctx.addLine(to: CGPoint(x: ax + dx * length, y: ay + dy * length))
            ctx.strokePath()
        }
    }

    // MARK: - Compact Bongo Cat

    private func drawBongoCat(_ ctx: CGContext, cx: Int, baseY: Int,
                              tapping: Bool, phase: Bool, scale: CGFloat) {
        let dark = CGColor(red: 30/255, green: 34/255, blue: 48/255, alpha: 1)
        let pink = CGColor(red: 244/255, green: 150/255, blue: 174/255, alpha: 1)
        let keyboard = CGColor(red: 210/255, green: 216/255, blue: 230/255, alpha: 1)
        let center = CGFloat(cx)
        let base = CGFloat(baseY)
        let keyboardWidth = 152 * scale
        let keyboardHeight = 15 * scale
        let keyboardX = center - keyboardWidth / 2
        let keyboardY = base - keyboardHeight
        let keyboardRect = CGRect(
            x: keyboardX, y: keyboardY, width: keyboardWidth, height: keyboardHeight)
        let keyboardPath = CGPath(
            roundedRect: keyboardRect, cornerWidth: 4 * scale,
            cornerHeight: 4 * scale, transform: nil)
        ctx.setFillColor(keyboard)
        ctx.addPath(keyboardPath)
        ctx.fillPath()
        ctx.setStrokeColor(dark)
        ctx.setLineWidth(max(0.7, 1.5 * scale))
        ctx.addPath(keyboardPath)
        ctx.strokePath()

        if let cat = BongoCatAsset.image {
            let catWidth = 148 * scale
            let catHeight = catWidth * CGFloat(cat.height) / CGFloat(cat.width)
            let rect = CGRect(
                x: center - catWidth / 2,
                y: keyboardY - 4 * scale - catHeight,
                width: catWidth, height: catHeight)
            drawImageUpright(ctx, cat, in: rect)
        }

        let pawRX = 13 * scale
        let pawRY = 10 * scale
        let downY = keyboardY + 2 * scale
        let upY = keyboardY - 14 * scale
        let leftY = tapping ? (phase ? upY : downY) : downY
        let rightY = tapping ? (phase ? downY : upY) : downY
        for (px, py) in [(center - 34 * scale, leftY), (center + 34 * scale, rightY)] {
            let rect = CGRect(
                x: px - pawRX, y: py - pawRY, width: pawRX * 2, height: pawRY * 2)
            ctx.setFillColor(pink)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(dark)
            ctx.setLineWidth(max(0.7, 2 * scale))
            ctx.strokeEllipse(in: rect)
        }

        if !tapping {
            Draw.text(ctx, "z", x: Int(center + 28 * scale), y: Int(keyboardY - 35 * scale),
                      font: Fonts.system(max(8, 12 * scale), weight: .bold),
                      color: Color.textL)
        }
    }

    /// Draw a CGImage upright inside `rect` within the flipped (y-down) context.
    /// `flipX` mirrors it horizontally (for facing left/right).
    private func drawImageUpright(_ ctx: CGContext, _ image: CGImage, in rect: CGRect,
                                 flipX: Bool = false) {
        ctx.saveGState()
        if flipX {
            ctx.translateBy(x: rect.maxX, y: rect.minY + rect.height)
            ctx.scaleBy(x: -1, y: -1)
        } else {
            ctx.translateBy(x: rect.minX, y: rect.minY + rect.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    // MARK: - AI Agents Panel

    private func renderAgents(
        _ ctx: CGContext,
        agents: AgentsSnapshot,
        language: AppLanguage
    ) {
        let x = Layout.agentsX
        let pw = Layout.agentsWidth
        let py = Layout.panelY
        let ph = Layout.panelHeight

        Draw.panel(ctx, x: x, y: py, w: pw, h: ph, accent: Color.purple)
        Draw.text(ctx, language.text(.aiAgents), x: x + 20, y: py + 14,
                  font: Fonts.system(22, weight: .bold), color: Color.purple)

        // Vertical divider between columns
        let midX = x + pw / 2
        Draw.line(ctx, from: CGPoint(x: midX, y: py + 52),
                  to: CGPoint(x: midX, y: py + ph - 14), color: Color.border)

        let colW = pw / 2 - 40
        renderAgentColumn(ctx, x: x + 22, w: colW, py: py,
                          name: "CLAUDE", accent: Color.claude,
                          usage: agents.claude, language: language)
        renderAgentColumn(ctx, x: midX + 18, w: colW, py: py,
                          name: "CODEX", accent: Color.cyan,
                          usage: agents.codex, language: language)
    }

    private func renderAgentColumn(_ ctx: CGContext, x: Int, w: Int, py: Int,
                                   name: String, accent: CGColor, usage: AgentUsage,
                                   language: AppLanguage) {
        let ph = Layout.panelHeight

        // Column background — three states, agent-tinted:
        //   needsAttention (done / waiting) → hard on/off blink (high-contrast alert)
        //   isWorking      (running a turn)  → slow, gentle breathing (~5s period)
        //   idle                            → static tint
        // render() runs every 0.5s, smooth enough for both sin() and the blink.
        let bgRect = CGRect(x: CGFloat(x - 12), y: CGFloat(py + 42),
                            width: CGFloat(w + 24), height: CGFloat(ph - 56))
        let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 12, cornerHeight: 12,
                            transform: nil)
        let base: CGFloat = name == "CLAUDE" ? 0.09 : 0.08
        let t = Date().timeIntervalSince1970
        let blinkOn = Int(t * 2) % 2 == 0
        // Linear triangle breathing (0→1→0 over 5s). A constant per-frame delta reads
        // far smoother than cosine easing at the display's low frame rate — no stutter
        // where the cosine flattens near its peaks/troughs.
        let phase = t.truncatingRemainder(dividingBy: 5) / 5        // 0..1
        let breath = CGFloat(phase < 0.5 ? phase * 2 : (1 - phase) * 2)
        var bgAlpha = base
        if usage.needsAttention {
            bgAlpha = blinkOn ? 0.36 : 0.10
        } else if usage.isWorking {
            bgAlpha = base + 0.13 * breath
        }
        ctx.setFillColor(accent.copy(alpha: bgAlpha) ?? accent)
        ctx.addPath(bgPath)
        ctx.fillPath()
        if usage.needsAttention {
            ctx.setStrokeColor(accent.copy(alpha: blinkOn ? 0.9 : 0.25) ?? accent)
            ctx.setLineWidth(2)
            ctx.addPath(bgPath)
            ctx.strokePath()
        } else if usage.isWorking {
            // Faint breathing border to reinforce the "alive/working" feel
            ctx.setStrokeColor(accent.copy(alpha: 0.12 + 0.28 * breath) ?? accent)
            ctx.setLineWidth(1.5)
            ctx.addPath(bgPath)
            ctx.strokePath()
        }

        // Header: name + activity indicator (right-aligned "● now" / "12m ago")
        Draw.text(ctx, name, x: x, y: py + 50,
                  font: Fonts.system(22, weight: .bold), color: accent)
        let active = (usage.secondsSinceActive ?? Int.max) < 90
        let agoStr: String
        if !usage.available {
            agoStr = language.text(.notFound)
        } else if let s = usage.secondsSinceActive {
            if active {
                agoStr = language.text(.now)
            } else if s < 3600 {
                agoStr = AppLocalization.format(
                    .minutesAgo, language: language, s / 60)
            } else if s < 86400 {
                agoStr = AppLocalization.format(
                    .hoursAgo, language: language, s / 3600)
            } else {
                agoStr = AppLocalization.format(
                    .daysAgo, language: language, s / 86400)
            }
        } else {
            agoStr = language.text(.noSession)
        }
        let agoFont = Fonts.system(15, weight: .medium)
        let agoColor = active ? Color.green : Color.textD
        let agoW = (agoStr as NSString).size(withAttributes: [.font: agoFont]).width
        Draw.text(ctx, agoStr, x: Int(CGFloat(x + w) - agoW), y: py + 56,
                  font: agoFont, color: agoColor)
        let dotR: CGFloat = 5
        ctx.setFillColor(agoColor)
        ctx.fillEllipse(in: CGRect(x: CGFloat(x + w) - agoW - dotR * 2 - 8,
                                   y: CGFloat(py + 56) + 10 - dotR,
                                   width: dotR * 2, height: dotR * 2))

        // Current session — TOP. Project (+ step badge), plan progress, live activity.
        var y = py + 90
        if let project = usage.project {
            // Step badge "步骤 4/6" right-aligned on the project line, when a plan exists
            var projMaxW = CGFloat(w)
            if let cur = usage.stepCurrent, let total = usage.stepTotal {
                let badge = AppLocalization.format(
                    .step, language: language, cur, total)
                let bFont = Fonts.system(16, weight: .semibold)
                let bW = (badge as NSString).size(withAttributes: [.font: bFont]).width
                Draw.text(ctx, badge, x: Int(CGFloat(x + w) - bW), y: y + 4,
                          font: bFont, color: accent)
                projMaxW = CGFloat(w) - bW - 16
            }
            Draw.text(ctx, truncate(project, font: Fonts.system(22, weight: .semibold),
                                    maxW: projMaxW),
                      x: x, y: y, font: Fonts.system(22, weight: .semibold), color: Color.textW)
            y += 34
        }

        // Plan progress — compact segmented bar (the badge conveys N/M; no text line,
        // so the message below gets the room)
        if let cur = usage.stepCurrent, let total = usage.stepTotal, total > 0 {
            drawStepBar(ctx, x: x, y: y, w: w, current: cur, total: total, accent: accent)
            y += 20
        }

        // Latest message — what the agent last said (never the commands it ran).
        // Markdown tables/lists are laid out structurally; plain text just wraps.
        let actText = usage.activity ?? (usage.available ? language.text(.idle) : "—")
        let msgBottom = py + ph - 140   // token divider sits here
        renderMessage(ctx, text: actText, x: x, y: y, w: w, bottom: msgBottom, accent: accent)

        // Token usage — large, anchored near the bottom of the column
        let tokY = py + ph - 126
        Draw.line(ctx, from: CGPoint(x: x, y: tokY - 12),
                  to: CGPoint(x: x + w, y: tokY - 12), color: Color.border)
        Draw.text(ctx, language.text(.todayTokens), x: x, y: tokY,
                  font: Fonts.system(17), color: Color.textL)
        Draw.text(ctx, formatTokens(usage.todayTotalTokens, language: language),
                  x: x, y: tokY + 24,
                  font: Fonts.system(40, weight: .bold), color: Color.textW)

        // In / Out — right-aligned, level with the label + big number
        let ioFont = Fonts.system(18, weight: .medium)
        let ioRows: [(String, UInt64)] = [
            (language.text(.tokenInput), usage.todayInputTokens),
            (language.text(.tokenOutput), usage.todayOutputTokens),
        ]
        for (i, row) in ioRows.enumerated() {
            let ry = tokY + 6 + i * 30
            let valStr = formatTokens(row.1, language: language)
            let valW = (valStr as NSString).size(withAttributes: [.font: ioFont]).width
            Draw.text(ctx, valStr, x: Int(CGFloat(x + w) - valW), y: ry,
                      font: ioFont, color: Color.textS)
            let labelW = (row.0 as NSString).size(withAttributes: [.font: ioFont]).width
            Draw.text(ctx, row.0, x: Int(CGFloat(x + w) - valW - labelW - 10), y: ry,
                      font: ioFont, color: Color.textL)
        }

        // Quota (Codex): remaining percentage + reset countdown + bar
        if let used = usage.quotaUsedPercent {
            let remaining = max(0, 100 - used)
            let qColor: CGColor = remaining > 50 ? Color.green
                : (remaining > 20 ? Color.orange : Color.red)
            let qy = tokY + 78
            Draw.text(
                ctx,
                AppLocalization.format(
                    .quotaRemaining, language: language, remaining),
                x: x, y: qy,
                      font: Fonts.system(18, weight: .medium), color: qColor)
            if let resets = usage.quotaResetsAt {
                let secs = max(0, Int(resets.timeIntervalSinceNow))
                let resetStr: String
                if secs >= 86400 {
                    resetStr = AppLocalization.format(
                        .resetDays, language: language, secs / 86400)
                } else if secs >= 3600 {
                    resetStr = AppLocalization.format(
                        .resetHours, language: language, secs / 3600)
                } else {
                    resetStr = AppLocalization.format(
                        .resetMinutes, language: language, max(secs / 60, 1))
                }
                let rFont = Fonts.system(15)
                let rW = (resetStr as NSString).size(withAttributes: [.font: rFont]).width
                Draw.text(ctx, resetStr, x: Int(CGFloat(x + w) - rW), y: qy + 3,
                          font: rFont, color: Color.textD)
            }
            Draw.bar(ctx, x: x, y: qy + 28, w: w, h: 8,
                     percent: remaining, color: qColor)
        }
    }

    /// Segmented plan-progress bar: completed steps solid, current bright, pending dim.
    private func drawStepBar(_ ctx: CGContext, x: Int, y: Int, w: Int,
                             current: Int, total: Int, accent: CGColor) {
        guard total > 0 else { return }
        let gap = 4
        let segW = (w - gap * (total - 1)) / total
        guard segW > 0 else { return }
        for i in 0..<total {
            let sx = x + i * (segW + gap)
            let color: CGColor
            if i < current - 1 {          // completed
                color = accent.copy(alpha: 0.5) ?? accent
            } else if i == current - 1 {  // current
                color = accent
            } else {                      // pending
                color = Color.barBG
            }
            let rect = CGRect(x: CGFloat(sx), y: CGFloat(y), width: CGFloat(segW), height: 7)
            ctx.setFillColor(color)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil))
            ctx.fillPath()
        }
    }

    /// Locale-aware compact token quantities. Chinese uses 万/亿 while English
    /// uses K/M/B, keeping the large total readable in the same fixed-width area.
    private func formatTokens(_ n: UInt64, language: AppLanguage) -> String {
        let v = Double(n)
        if language == .english {
            if v >= 1e9 {
                let b = v / 1e9
                return String(format: b < 100 ? "%.2fB" : "%.1fB", b)
            }
            if v >= 1e6 {
                let m = v / 1e6
                return String(format: m < 100 ? "%.2fM" : "%.1fM", m)
            }
            if v >= 1e3 {
                let k = v / 1e3
                return String(format: k < 100 ? "%.2fK" : "%.1fK", k)
            }
            return "\(n)"
        }
        if v >= 1e8 {
            let y = v / 1e8
            return String(format: y < 100 ? "%.2f亿" : "%.1f亿", y)
        }
        if v >= 1e4 {
            let w = v / 1e4
            return String(format: w < 100 ? "%.2f万" : (w < 1000 ? "%.1f万" : "%.0f万"), w)
        }
        return "\(n)"
    }

    // MARK: - Agent message layout (markdown-aware)

    /// Render an agent message top-down within [y, bottom): markdown tables become
    /// aligned grids, `- ` bullets and prose wrap. Stops when vertical space runs out.
    private func renderMessage(_ ctx: CGContext, text: String, x: Int, y: Int, w: Int,
                               bottom: Int, accent: CGColor) {
        let proseFont = Fonts.system(17)
        let lineH = 24
        var cy = y
        let raw = text.components(separatedBy: "\n")
        var i = 0
        while i < raw.count && cy + 20 <= bottom {
            let line = raw[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { i += 1; continue }

            if isTableLine(line) {
                // Consume the contiguous run of table rows and render as a grid
                var block: [String] = []
                while i < raw.count && isTableLine(raw[i].trimmingCharacters(in: .whitespaces)) {
                    block.append(raw[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                cy = renderTable(ctx, rows: block, x: x, y: cy, w: w, bottom: bottom, accent: accent)
            } else {
                // Prose / bullet — wrap, but cap each block so a table below still fits
                let remaining = (bottom - cy) / lineH
                guard remaining > 0 else { break }
                let wrapped = wrap(stripMarkdown(line), font: proseFont,
                                   maxW: CGFloat(w), maxLines: min(2, remaining))
                for wl in wrapped {
                    if cy + lineH > bottom { break }
                    Draw.text(ctx, wl, x: x, y: cy, font: proseFont, color: Color.textS)
                    cy += lineH
                }
                i += 1
            }
        }
    }

    private func isTableLine(_ s: String) -> Bool {
        s.hasPrefix("|") && s.filter { $0 == "|" }.count >= 2
    }

    /// A markdown separator cell like `---`, `:--`, `--:`, `:-:`.
    private func isSeparatorCell(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0 == "-" || $0 == ":" } && s.contains("-")
    }

    private func stripMarkdown(_ s: String) -> String {
        s.replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
    }

    /// Render markdown table rows as an aligned grid. Returns the new y below it.
    private func renderTable(_ ctx: CGContext, rows rawRows: [String], x: Int, y: Int,
                             w: Int, bottom: Int, accent: CGColor) -> Int {
        // Parse into cell rows, dropping the separator row and empty edge cells
        var rows: [[String]] = []
        for line in rawRows {
            var cells = line.components(separatedBy: "|").map {
                stripMarkdown($0.trimmingCharacters(in: .whitespaces))
            }
            if cells.first == "" { cells.removeFirst() }
            if cells.last == "" { cells.removeLast() }
            if cells.allSatisfy({ isSeparatorCell($0) }) { continue }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard !rows.isEmpty else { return y }

        let cols = rows.map(\.count).max() ?? 1
        let rowH = 24
        let colGap = 8
        let colW = (w - colGap * (cols - 1)) / max(cols, 1)
        guard colW > 20 else { return y }
        let cellFont = Fonts.system(16)
        let headFont = Fonts.system(16, weight: .semibold)

        var cy = y + 2
        for (ri, row) in rows.enumerated() {
            if cy + rowH > bottom { break }
            for ci in 0..<cols {
                let cell = ci < row.count ? row[ci] : ""
                if cell.isEmpty { continue }
                let cx = x + ci * (colW + colGap)
                let font = ri == 0 ? headFont : cellFont
                let color = ri == 0 ? accent : Color.textS
                Draw.text(ctx, truncate(cell, font: font, maxW: CGFloat(colW)),
                          x: cx, y: cy, font: font, color: color)
            }
            cy += rowH
            if ri == 0 {  // underline under the header row
                Draw.line(ctx, from: CGPoint(x: x, y: cy - 4),
                          to: CGPoint(x: x + w, y: cy - 4), color: Color.border)
            }
        }
        return cy + 4
    }

    /// Truncate a single line with "…" to fit maxW.
    private func truncate(_ s: String, font: NSFont, maxW: CGFloat) -> String {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        if (s as NSString).size(withAttributes: attrs).width <= maxW { return s }
        var t = s
        while !t.isEmpty {
            t.removeLast()
            if ((t + "…") as NSString).size(withAttributes: attrs).width <= maxW {
                return t + "…"
            }
        }
        return "…"
    }

    /// Greedy character wrap (activity text may be CJK — no word boundaries).
    private func wrap(_ s: String, font: NSFont, maxW: CGFloat, maxLines: Int) -> [String] {
        guard maxLines >= 1 else { return [] }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var lines: [String] = []
        var current = ""
        for ch in s {
            let candidate = current + String(ch)
            if (candidate as NSString).size(withAttributes: attrs).width > maxW {
                // Reached the last allowed line → fold the whole remainder into it
                if lines.count == maxLines - 1 {
                    let rest = String(s[s.index(s.startIndex, offsetBy: lines.joined().count)...])
                    lines.append(truncate(rest, font: font, maxW: maxW))
                    return lines
                }
                lines.append(current)
                current = String(ch)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

}
