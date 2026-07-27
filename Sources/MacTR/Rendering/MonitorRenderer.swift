// MonitorRenderer.swift — System telemetry + AI agents dashboard
//
// Left: compact CPU/GPU/MEMORY/NETWORK/FANS grid
// Right: wide, two-column AI AGENTS activity panel
// The AGENTS panel shows each agent's current activity (top) and today's
// token usage + quota (bottom), sourced from local session transcripts.

import AppKit
import CoreGraphics
import Foundation

final class MonitorRenderer: FrameRenderer, @unchecked Sendable {

    private let collector = SystemMetricsCollector()
    private let agentCollector = AgentUsageCollector()

    // Background metrics collection — decoupled from frame loop for consistent refresh
    private let metricsQueue = DispatchQueue(label: "com.thermalvision.metrics")
    private var metricsRunning = false
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
    private let networkHistoryLimit = 60  // 30 seconds at the 0.5s collection cadence

    // Reusable CGContext — avoids allocating 3.6MB every 0.5s (prevents CG raster data leak)
    private var reusableCtx: CGContext?

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

    /// Start background metrics collection. Call before first render().
    /// Primes all metrics synchronously, then starts async collection loop.
    /// Safe to call multiple times — returns immediately if already running.
    func startMetrics() {
        lock.lock()
        guard !metricsRunning else { lock.unlock(); return }
        metricsRunning = true
        lock.unlock()
        log("[Metrics] Starting collection...")
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
        metricsQueue.async { [weak self] in self?.metricsLoop() }
    }

    func stopMetrics() {
        log("[Metrics] Stopping collection")
        metricsRunning = false
    }

    /// True when a column has a live animation (breathing while working, or the
    /// done/waiting blink) — the frame loop uses this to raise the LCD frame rate
    /// only while something is actually moving, and idle low otherwise.
    func wantsHighFrameRate() -> Bool {
        lock.lock(); defer { lock.unlock() }
        // Heavy CPU → Pikachu crackles with electricity, worth animating smoothly
        if let c = _cpu, c.total > 55 { return true }
        guard let a = _agents else { return false }
        return a.claude.isWorking || a.claude.needsAttention
            || a.codex.isWorking || a.codex.needsAttention
    }

    private func metricsLoop() {
        log("[Metrics] Loop started on metricsQueue")
        var slowTick = 0
        while metricsRunning {
            // Fast metrics every tick
            let cpu = collector.collectCPU()
            let mem = collector.collectMemory()
            let network = collector.collectNetwork()
            lock.lock()
            _cpu = cpu; _mem = mem; _network = network
            appendNetworkHistoryLocked(network)
            lock.unlock()

            // Slow metrics every 4th tick (~2s)
            slowTick += 1
            if slowTick >= 4 {
                let gpu = collector.collectGPU()
                let temp = collector.collectTemperature()
                let fans = collector.collectFans()
                let agents = agentCollector.collect()
                let sys = collector.collectSystem()
                lock.lock()
                _gpu = gpu; _temp = temp; _fans = fans
                _agents = agents; _sys = sys
                lock.unlock()
                slowTick = 0
            }

            Thread.sleep(forTimeInterval: 0.5)
        }
        log("[Metrics] Loop exited (metricsRunning=false)")
    }

    /// Caller must hold `lock`.
    private func appendNetworkHistoryLocked(_ network: NetworkSnapshot) {
        guard network.available else { return }
        _networkRxHistory.append(max(network.rxBytesPerSec, 0))
        _networkTxHistory.append(max(network.txBytesPerSec, 0))
        if _networkRxHistory.count > networkHistoryLimit {
            _networkRxHistory.removeFirst(_networkRxHistory.count - networkHistoryLimit)
        }
        if _networkTxHistory.count > networkHistoryLimit {
            _networkTxHistory.removeFirst(_networkTxHistory.count - networkHistoryLimit)
        }
    }

    // Demo mode: drive the display with polished fake data (for screenshots / photos
    // and open-source showcase). Set before render(); the frame loop keeps its normal
    // memory-safe path (reusable context + autoreleasepool) and animations stay live.
    var demoMode = false

    private struct DashboardData {
        let cpu: CPUSnapshot
        let mem: MemorySnapshot
        let gpu: GPUSnapshot?
        let network: NetworkSnapshot?
        let fans: FanSnapshot?
        let temp: TemperatureSnapshot
        let sys: SystemSnapshot?
        let agents: AgentsSnapshot
        let rxHistory: [Double]
        let txHistory: [Double]
    }

    /// Deterministic showcase data. CPU cores gently wave over time so the demo looks
    /// alive on the LCD; everything else is fixed so it reads clearly in a photo.
    private func demoData(coreCount requestedCoreCount: Int = 10) -> DashboardData {
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
        let historyCount = networkHistoryLimit
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
                FanReading(name: "Left", currentRPM: 2_180, minRPM: 1_200, maxRPM: 5_800),
                FanReading(name: "Right", currentRPM: 2_040, minRPM: 1_200, maxRPM: 5_800),
            ])
        let temp = TemperatureSnapshot(cpuTemp: 52, gpuTemp: 45, thermalState: 0)
        let sys = SystemSnapshot(uptimeSeconds: 27 * 3600 + 3 * 60, processCount: 612)
        let agents = AgentsSnapshot(
            claude: AgentUsage(available: true,
                               todayInputTokens: 48_300_000, todayOutputTokens: 512_000,
                               secondsSinceActive: 3, project: "MacTR",
                               activity: """
                               已完成 AI Agents 面板的三项优化，改动集中在两个文件：

                               | 文件 | 改动 |
                               |---|---|
                               | Collector | 解析消息与待办 |
                               | Renderer | 表格化排版 |
                               """,
                               isWorking: true,
                               stepCurrent: 3, stepTotal: 4,
                               stepText: "渲染 Claude 消息表格"),
            codex: AgentUsage(available: true,
                              todayInputTokens: 60_100_000, todayOutputTokens: 375_000,
                              secondsSinceActive: 6, project: "web-service",
                              activity: """
                              已完成部署，四个服务全部推送到 `main`：

                              | 服务 | 提交 | 文件 |
                              |---|---|---:|
                              | `api-gateway` | `a4872c56` | 24 |
                              | `auth-service` | `4d6934de` | 10 |
                              | `web-client` | `9b0e17aa` | 32 |
                              | `job-worker` | `ac02bea6` | 88 |
                              """,
                              quotaUsedPercent: 57,
                              quotaResetsAt: Date().addingTimeInterval(3600 * 24 * 6),
                              isWorking: true,
                              stepCurrent: 4, stepTotal: 6,
                              stepText: "部署到预发环境并跑冒烟测试"))
        return DashboardData(
            cpu: cpu, mem: mem, gpu: gpu, network: network, fans: fans,
            temp: temp, sys: sys, agents: agents,
            rxHistory: rxHistory, txHistory: txHistory)
    }

    /// Render one demo frame with the showcase data (for --snapshot).
    func renderSimulated(coreCount: Int) -> CGImage? {
        let data = demoData(coreCount: coreCount)
        let w = Layout.width, h = Layout.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        Draw.gradientBackground(ctx)
        renderDashboard(ctx, data: data)
        return ctx.makeImage()
    }

    // Serializes render() callers — the USB frame loop and the on-Mac preview
    // window can both render around a connect/disconnect transition, and they
    // share reusableCtx + sparkline history
    private let renderMutex = NSLock()

    func render() -> CGImage? {
        renderMutex.lock()
        defer { renderMutex.unlock() }

        var data: DashboardData
        if demoMode {
            data = demoData()
        } else {
            // Read cached metrics (never blocks — uses latest available values)
            lock.lock()
            guard let c = _cpu, let m = _mem, let tp = _temp, let a = _agents else {
                lock.unlock(); return nil
            }
            data = DashboardData(
                cpu: c, mem: m, gpu: _gpu, network: _network, fans: _fans,
                temp: tp, sys: _sys, agents: a,
                rxHistory: _networkRxHistory, txHistory: _networkTxHistory)
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
                rxHistory: data.rxHistory, txHistory: data.txHistory)
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

        renderDashboard(ctx, data: data)

        let image = ctx.makeImage()
        ctx.restoreGState()
        return image
    }

    private func renderDashboard(_ ctx: CGContext, data: DashboardData) {
        let agentsBusy = data.agents.claude.isWorking || data.agents.claude.needsAttention
            || data.agents.codex.isWorking || data.agents.codex.needsAttention
        renderCPU(ctx, cpu: data.cpu, temp: data.temp, agentsBusy: agentsBusy)
        renderGPU(ctx, gpu: data.gpu, temp: data.temp)
        renderMemory(ctx, mem: data.mem)
        renderNetwork(
            ctx, network: data.network,
            rxHistory: data.rxHistory, txHistory: data.txHistory)
        renderFansAndSystem(
            ctx, fans: data.fans, sys: data.sys, agentsBusy: agentsBusy)
        renderAgents(ctx, agents: data.agents)
    }

    // MARK: - Compact System Cards

    private func renderCPU(_ ctx: CGContext, cpu: CPUSnapshot, temp: TemperatureSnapshot,
                           agentsBusy: Bool) {
        let x = Layout.systemCardX(0)
        let y = Layout.systemCardY(0)
        let w = Layout.systemColumnWidth
        let h = Layout.systemRowHeight

        Draw.panel(ctx, x: x, y: y, w: w, h: h, accent: Color.blue)
        Draw.text(ctx, "CPU", x: x + 14, y: y + 11,
                  font: Fonts.system(18, weight: .bold), color: Color.blue)
        drawCompactGauge(
            ctx, cx: x + 48, cy: y + 76, percent: cpu.total,
            color: Color.forPercent(cpu.total), dark: Color.forPercentDark(cpu.total))

        let statX = x + 88
        Draw.text(ctx, "TEMP", x: statX, y: y + 44,
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

        Draw.text(ctx, "LOAD 1M", x: statX, y: y + 81,
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

    private func renderGPU(_ ctx: CGContext, gpu: GPUSnapshot?,
                           temp: TemperatureSnapshot) {
        let x = Layout.systemCardX(1)
        let y = Layout.systemCardY(0)
        let w = Layout.systemColumnWidth
        let h = Layout.systemRowHeight

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
            ctx, label: "RENDER", value: Double(gpu.rendererUtil),
            x: sx, y: y + 43, w: sw, color: Color.magenta)
        drawLabeledMiniBar(
            ctx, label: "TILER", value: Double(gpu.tilerUtil),
            x: sx, y: y + 75, w: sw, color: Color.purple)

        let usedGB = Double(gpu.memUsedMB) / 1024
        let allocGB = Double(gpu.memAllocMB) / 1024
        let memoryString = allocGB > 0
            ? String(format: "MEM %.1f / %.1f GB", usedGB, allocGB)
            : String(format: "MEM %.1f GB", usedGB)
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

    private func renderMemory(_ ctx: CGContext, mem: MemorySnapshot) {
        let x = Layout.systemCardX(0)
        let y = Layout.systemCardY(1)
        let w = Layout.systemColumnWidth
        let h = Layout.systemRowHeight
        let bytesPerGB = 1024.0 * 1024 * 1024
        let totalGB = Double(mem.total) / bytesPerGB
        let usedGB = Double(mem.total > mem.available ? mem.total - mem.available : 0) / bytesPerGB
        let pct = mem.total > 0 ? mem.percent : 0
        let pressureColor = Color.forPressure(mem.pressure)

        Draw.panel(ctx, x: x, y: y, w: w, h: h, accent: Color.green)
        Draw.text(ctx, "MEMORY", x: x + 14, y: y + 11,
                  font: Fonts.system(18, weight: .bold), color: Color.green)
        Draw.text(ctx, String(format: "%.0f GB", totalGB), x: x + w - 62, y: y + 14,
                  font: Fonts.system(11, weight: .medium), color: Color.textL)

        drawCompactGauge(
            ctx, cx: x + 48, cy: y + 76, percent: pct,
            color: pressureColor, dark: Color.forPressureDark(mem.pressure))

        let pressureText = mem.pressure >= 4 ? "CRITICAL"
            : (mem.pressure >= 2 ? "PRESSURE" : "NORMAL")
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
            format: "A %.1f  W %.1f  C %.1f  F %.1f", activeGB, wiredGB,
            compressedGB, availableGB)
        Draw.text(ctx, breakdown, x: x + 14, y: y + 99,
                  font: Fonts.system(10, weight: .medium), color: Color.textS)
        drawStackedBar(
            ctx,
            values: [activeGB, wiredGB, compressedGB, availableGB],
            colors: [Color.green, Color.orange, Color.purple, Color.cyan],
            x: x + 14, y: y + h - 27, w: w - 28, h: 10)
    }

    private func renderNetwork(_ ctx: CGContext, network: NetworkSnapshot?,
                               rxHistory: [Double], txHistory: [Double]) {
        let x = Layout.systemCardX(1)
        let y = Layout.systemCardY(1)
        let w = Layout.systemColumnWidth
        let h = Layout.systemRowHeight

        Draw.panel(ctx, x: x, y: y, w: w, h: h, accent: Color.cyan)
        Draw.text(ctx, "NETWORK", x: x + 14, y: y + 11,
                  font: Fonts.system(18, weight: .bold), color: Color.cyan)
        Draw.text(ctx, "30 SEC", x: x + w - 57, y: y + 15,
                  font: Fonts.system(10, weight: .semibold), color: Color.textD)

        guard let network, network.available else {
            Draw.centeredText(ctx, "N/A", cx: x + w / 2, y: y + 61,
                              font: Fonts.system(25, weight: .semibold), color: Color.textD)
            return
        }

        // Pad startup history on the left so bar width stays stable instead of
        // rendering a handful of oversized columns during the first 30 seconds.
        let rxValues = paddedNetworkHistory(rxHistory)
        let txValues = paddedNetworkHistory(txHistory)
        Draw.mirrorBarChart(
            ctx,
            topValues: rxValues, bottomValues: txValues,
            x: x + 14, y: y + 38, w: w - 28, h: h - 49,
            topColor: Color.green, bottomColor: Color.cyan,
            topLabel: "DOWN", bottomLabel: "UP",
            topCurrent: Draw.formatBytesPerSec(network.rxBytesPerSec),
            bottomCurrent: Draw.formatBytesPerSec(network.txBytesPerSec))
    }

    private func paddedNetworkHistory(_ values: [Double]) -> [Double] {
        let recent = Array(values.suffix(networkHistoryLimit))
        guard recent.count < networkHistoryLimit else { return recent }
        return Array(repeating: 0, count: networkHistoryLimit - recent.count) + recent
    }

    private func renderFansAndSystem(_ ctx: CGContext, fans: FanSnapshot?,
                                     sys: SystemSnapshot?, agentsBusy: Bool) {
        let x = Layout.systemX
        let y = Layout.systemCardY(2)
        let w = Layout.systemWidth
        let h = Layout.systemRowHeight
        let dividerX = x + 377

        Draw.panel(ctx, x: x, y: y, w: w, h: h, accent: Color.orange)
        Draw.text(ctx, "FANS", x: x + 14, y: y + 11,
                  font: Fonts.system(18, weight: .bold), color: Color.orange)
        Draw.line(
            ctx, from: CGPoint(x: dividerX, y: y + 15),
            to: CGPoint(x: dividerX, y: y + h - 15), color: Color.border)

        if let fans, fans.available {
            if fans.fans.isEmpty {
                Draw.text(ctx, "FANLESS", x: x + 14, y: y + 61,
                          font: Fonts.system(24, weight: .semibold), color: Color.textD)
                Draw.text(ctx, "Passive cooling", x: x + 14, y: y + 90,
                          font: Fonts.system(12), color: Color.textL)
            } else {
                let shown = fans.displayReadings()
                let overflow = fans.overflowCount()
                if overflow > 0 {
                    Draw.text(ctx, "+\(overflow)",
                              x: dividerX - 38, y: y + 15,
                              font: Fonts.system(11, weight: .bold), color: Color.textL)
                }
                for (index, fan) in shown.enumerated() {
                    let rowY = y + 42 + index * 31
                    let name = truncate(
                        fan.name, font: Fonts.system(12, weight: .medium), maxW: 72)
                    Draw.text(ctx, name, x: x + 14, y: rowY,
                              font: Fonts.system(12, weight: .medium), color: Color.textS)
                    Draw.text(ctx, String(format: "%.0f", fan.currentRPM),
                              x: x + 91, y: rowY,
                              font: Fonts.mono(12), color: Color.textW)
                    Draw.text(ctx, "RPM", x: x + 131, y: rowY + 1,
                              font: Fonts.system(9, weight: .medium), color: Color.textL)
                    if let percent = fan.percentOfMax {
                        Draw.bar(
                            ctx, x: x + 164, y: rowY + 4,
                            w: dividerX - (x + 164) - 16, h: 8,
                            percent: percent, color: Color.forPercent(percent))
                    }
                }
            }
        } else {
            Draw.text(ctx, "N/A", x: x + 14, y: y + 61,
                      font: Fonts.system(24, weight: .semibold), color: Color.textD)
            Draw.text(ctx, "AppleSMC unavailable", x: x + 14, y: y + 90,
                      font: Fonts.system(12), color: Color.textL)
        }

        let statusX = dividerX + 15
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "yyyy-MM-dd  EEE"
        Draw.text(ctx, formatter.string(from: Date()), x: statusX, y: y + 13,
                  font: Fonts.system(13, weight: .semibold), color: Color.textS)
        formatter.dateFormat = "HH:mm:ss"
        Draw.text(ctx, formatter.string(from: Date()), x: statusX, y: y + 35,
                  font: Fonts.system(33, weight: .medium), color: Color.textW)

        if let sys {
            let hours = sys.uptimeSeconds / 3600
            let minutes = (sys.uptimeSeconds % 3600) / 60
            let uptime = hours >= 24 ? "\(hours / 24)d \(hours % 24)h" : "\(hours)h \(minutes)m"
            Draw.text(ctx, "UP \(uptime)", x: statusX, y: y + 91,
                      font: Fonts.system(11, weight: .medium), color: Color.textL)
            Draw.text(ctx, "\(sys.processCount) PROCS", x: statusX, y: y + 110,
                      font: Fonts.system(11, weight: .medium), color: Color.textL)
        }

        let t = Date().timeIntervalSince1970
        drawBongoCat(
            ctx, cx: x + w - 43, baseY: y + h - 12,
            tapping: agentsBusy, phase: Int(t * 5) % 2 == 0, scale: 0.42)
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

    private func renderAgents(_ ctx: CGContext, agents: AgentsSnapshot) {
        let x = Layout.agentsX
        let pw = Layout.agentsWidth
        let py = Layout.panelY
        let ph = Layout.panelHeight

        Draw.panel(ctx, x: x, y: py, w: pw, h: ph, accent: Color.purple)
        Draw.text(ctx, "AI AGENTS", x: x + 20, y: py + 14,
                  font: Fonts.system(24, weight: .bold), color: Color.purple)

        // Vertical divider between columns
        let midX = x + pw / 2
        Draw.line(ctx, from: CGPoint(x: midX, y: py + 52),
                  to: CGPoint(x: midX, y: py + ph - 14), color: Color.border)

        let colW = pw / 2 - 40
        renderAgentColumn(ctx, x: x + 22, w: colW, py: py,
                          name: "CLAUDE", accent: Color.claude, usage: agents.claude)
        renderAgentColumn(ctx, x: midX + 18, w: colW, py: py,
                          name: "CODEX", accent: Color.cyan, usage: agents.codex)
    }

    private func renderAgentColumn(_ ctx: CGContext, x: Int, w: Int, py: Int,
                                   name: String, accent: CGColor, usage: AgentUsage) {
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
                  font: Fonts.system(24, weight: .bold), color: accent)
        let active = (usage.secondsSinceActive ?? Int.max) < 90
        let agoStr: String
        if !usage.available {
            agoStr = "not found"
        } else if let s = usage.secondsSinceActive {
            agoStr = active ? "now"
                : (s < 3600 ? "\(s / 60)m ago"
                   : (s < 86400 ? "\(s / 3600)h ago" : "\(s / 86400)d ago"))
        } else {
            agoStr = "no session"
        }
        let agoFont = Fonts.system(17, weight: .medium)
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
                let badge = "步骤 \(cur)/\(total)"
                let bFont = Fonts.system(18, weight: .semibold)
                let bW = (badge as NSString).size(withAttributes: [.font: bFont]).width
                Draw.text(ctx, badge, x: Int(CGFloat(x + w) - bW), y: y + 4,
                          font: bFont, color: accent)
                projMaxW = CGFloat(w) - bW - 16
            }
            Draw.text(ctx, truncate(project, font: Fonts.system(26, weight: .semibold),
                                    maxW: projMaxW),
                      x: x, y: y, font: Fonts.system(26, weight: .semibold), color: Color.textW)
            y += 38
        }

        // Plan progress — compact segmented bar (the badge conveys N/M; no text line,
        // so the message below gets the room)
        if let cur = usage.stepCurrent, let total = usage.stepTotal, total > 0 {
            drawStepBar(ctx, x: x, y: y, w: w, current: cur, total: total, accent: accent)
            y += 20
        }

        // Latest message — what the agent last said (never the commands it ran).
        // Markdown tables/lists are laid out structurally; plain text just wraps.
        let actText = usage.activity ?? (usage.available ? "空闲" : "—")
        let msgBottom = py + ph - 140   // token divider sits here
        renderMessage(ctx, text: actText, x: x, y: y, w: w, bottom: msgBottom, accent: accent)

        // Token usage — large, anchored near the bottom of the column
        let tokY = py + ph - 126
        Draw.line(ctx, from: CGPoint(x: x, y: tokY - 12),
                  to: CGPoint(x: x + w, y: tokY - 12), color: Color.border)
        Draw.text(ctx, "今日 Token", x: x, y: tokY,
                  font: Fonts.system(19), color: Color.textL)
        Draw.text(ctx, formatTokensCN(usage.todayTotalTokens), x: x, y: tokY + 24,
                  font: Fonts.system(46, weight: .bold), color: Color.textW)

        // In / Out — right-aligned, level with the label + big number
        let ioFont = Fonts.system(20, weight: .medium)
        let ioRows: [(String, UInt64)] = [
            ("In", usage.todayInputTokens),
            ("Out", usage.todayOutputTokens),
        ]
        for (i, row) in ioRows.enumerated() {
            let ry = tokY + 6 + i * 30
            let valStr = formatTokensCN(row.1)
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
            Draw.text(ctx, String(format: "剩余额度 %.0f%%", remaining), x: x, y: qy,
                      font: Fonts.system(21, weight: .medium), color: qColor)
            if let resets = usage.quotaResetsAt {
                let secs = max(0, Int(resets.timeIntervalSinceNow))
                let resetStr = secs >= 86400 ? "\(secs / 86400)天后重置"
                    : (secs >= 3600 ? "\(secs / 3600)小时后重置" : "\(max(secs / 60, 1))分钟后重置")
                let rFont = Fonts.system(17)
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

    /// 中文数量格式："33.99万"、"1.02亿"。1万以下显示原始数字。
    private func formatTokensCN(_ n: UInt64) -> String {
        let v = Double(n)
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
        let proseFont = Fonts.system(19)
        let lineH = 26
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
