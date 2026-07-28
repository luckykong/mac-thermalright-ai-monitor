// MonitorRenderer+DemoData.swift — deterministic sample data for --demo,// --gif and the documentation screenshots. Kept apart from the live renderer
// so the hardcoded fixtures never sit in the way of reading it.

import AppKit
import CoreGraphics
import Foundation

extension MonitorRenderer {

    func documentationAgents(language: AppLanguage) -> AgentsSnapshot {
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
                quotaWindows: [
                    QuotaWindow(label: "5h", usedPercent: 22,
                                resetsAt: Date().addingTimeInterval(3 * 3600)),
                    QuotaWindow(label: "7d", usedPercent: 9,
                                resetsAt: Date().addingTimeInterval(4 * 86400)),
                ],
                needsAttention: false,
                isWorking: false),
            codex: AgentUsage(
                available: true,
                todayInputTokens: 12_600_000,
                todayOutputTokens: 284_000,
                secondsSinceActive: 4,
                project: "dashboard",
                activity: codexActivity,
                quotaWindows: [
                    QuotaWindow(label: "7d", usedPercent: 34,
                                resetsAt: Date().addingTimeInterval(6 * 86400)),
                ],
                needsAttention: false,
                isWorking: true,
                stepCurrent: 4,
                stepTotal: 6,
                stepText: codexStep))
    }

    func documentationScript() -> CustomScriptSnapshot {
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
    func demoData(
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
                               quotaWindows: [
                                   QuotaWindow(
                                       label: "5h", usedPercent: 41,
                                       resetsAt: Date().addingTimeInterval(2 * 3600)),
                                   QuotaWindow(
                                       label: "7d", usedPercent: 18,
                                       resetsAt: Date().addingTimeInterval(5 * 86400)),
                               ],
                               isWorking: true,
                               stepCurrent: 3, stepTotal: 4,
                               stepText: language == .simplifiedChinese
                                   ? "渲染 Claude 消息表格"
                                   : "Render the Claude message table"),
            codex: AgentUsage(available: true,
                              todayInputTokens: 60_100_000, todayOutputTokens: 375_000,
                              secondsSinceActive: 6, project: "web-service",
                              activity: codexActivity,
                              quotaWindows: [
                                  QuotaWindow(
                                      label: "7d", usedPercent: 57,
                                      resetsAt: Date().addingTimeInterval(3600 * 24 * 6)),
                              ],
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

}
