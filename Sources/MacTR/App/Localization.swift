// Localization.swift — runtime-selectable Simplified Chinese and English strings

import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// Language names are intentionally autonyms so the picker stays understandable
    /// even when the currently selected language is unfamiliar to the user.
    var displayName: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    func text(_ key: L10nKey) -> String {
        guard let pair = AppLocalization.strings[key] else {
            assertionFailure("Missing localization for \(key)")
            return String(describing: key)
        }
        return switch self {
        case .simplifiedChinese: pair.zhHans
        case .english: pair.english
        }
    }
}

enum L10nKey: CaseIterable, Sendable {
    // Settings tabs and language
    case general
    case display
    case customCard
    case device
    case about
    case language
    case interfaceLanguage
    case languageChangeHint

    // General settings
    case startupAndBackground
    case launchAtLogin
    case loginApprovalRequired
    case openSystemSettings
    case packagedAppOnly
    case backgroundMode
    case menuBar
    case backgroundBehaviorHint
    case autoShowPreview
    case dailySchedule
    case enableDailySchedule
    case atCloseTime
    case closeTime
    case resumeAutomatically
    case resumeTime
    case quitCannotResume
    case scheduleDisabledDescription
    case scheduleQuitDescription
    case schedulePauseDescription
    case scheduleActiveDescription
    case performance
    case mode
    case eco
    case balanced
    case smooth
    case ecoDetail
    case balancedDetail
    case smoothDetail
    case balancedHint

    // Display settings
    case displaySet
    case activeSet
    case systemMonitor
    case brightness
    case level
    case brightnessHint
    case rotation
    case rotate180
    case rotationHint
    case agentTokenUsage
    case countCachedTokens
    case countCachedTokensHint

    // Custom card settings
    case customScriptCard
    case showCustomScriptOutput
    case script
    case notSelected
    case choose
    case clearScript
    case cardName
    case runEvery
    case seconds
    case scriptIntervalHint
    case scriptFontSize
    case fontAutomatic
    case fontSmall
    case fontMedium
    case fontLarge
    case scriptFontSizeHint
    case testAndStatus
    case state
    case runNow
    case executionRules
    case shellExecutionRule
    case scriptSecurityRule
    case scriptDisabled
    case scriptChoose
    case scriptReady
    case scriptRunning
    case scriptSucceeded
    case scriptFailed
    case scriptTimedOut
    case scriptMissing
    case scriptInvalid
    case chooseScriptTitle

    // Device and About
    case output
    case resumeDisplayOutput
    case pauseDisplayOutput
    case connection
    case resolution
    case reconnect
    case statistics
    case framesSent
    case lastFrame
    case version
    case appDescription
    case builtWith
    case githubReleases

    // Schedule editor
    case closeAction
    case close
    case automaticResume
    case resume
    case scheduledResumeUnavailable

    // Menu and windows
    case previewWindow
    case enabled
    case editTimes
    case settings
    case viewLatestRelease
    case aboutMacTR
    case quitMacTR
    case scheduleNextOff
    case scheduleNextUnavailable
    case scheduleNextStart
    case scheduleNextQuit
    case scheduleNextPause
    case previewTitle
    case scheduleWindowTitle
    case settingsWindowTitle
    case loginAlertTitle
    case aboutBody
    case ok

    // Runtime state
    case stopped
    case connecting
    case resuming
    case disconnected
    case deviceNotFound
    case deviceBusy
    case errorPrefix
    case connected
    case handshakeFailed
    case active
    case sendError
    case unplugged
    case paused
    case pausedBySchedule

    // Dashboard
    case cpuTemperature
    case cpuLoadOneMinute
    case gpuRender
    case gpuTiler
    case gpuMemory
    case memory
    case memoryCritical
    case memoryPressure
    case memoryNormal
    case memoryBreakdown
    case network
    case thirtySeconds
    case download
    case upload
    case scriptStateOK
    case scriptStateRun
    case scriptStateError
    case scriptStateReady
    case scriptStateOff
    case scriptStateSetup
    case scriptOff
    case addScript
    case enableInSettings
    case customCardSettingsPath
    case runningEllipsis
    case noOutput
    case lastRun
    case fanless
    case fanUnavailable
    case uptimeSummary
    case aiAgents
    case notFound
    case now
    case minutesAgo
    case hoursAgo
    case daysAgo
    case noSession
    case step
    case idle
    case todayTokens
    case tokenInput
    case tokenOutput
    case quotaRemaining
    /// Shorter form used when a column shows more than one rate-limit window
    /// and each only gets half the width.
    case quotaRemainingCompact
    case resetDays
    case resetHours
    case resetMinutes
}

enum AppLocalization {
    struct Pair: Sendable {
        let zhHans: String
        let english: String
    }

    nonisolated static let strings: [L10nKey: Pair] = [
        .general: Pair(zhHans: "通用", english: "General"),
        .display: Pair(zhHans: "显示", english: "Display"),
        .customCard: Pair(zhHans: "自定义卡片", english: "Custom Card"),
        .device: Pair(zhHans: "设备", english: "Device"),
        .about: Pair(zhHans: "关于", english: "About"),
        .language: Pair(zhHans: "语言", english: "Language"),
        .interfaceLanguage: Pair(zhHans: "界面语言", english: "Interface Language"),
        .languageChangeHint: Pair(
            zhHans: "切换后会立即更新菜单栏、设置窗口和 LCD 仪表盘。",
            english: "Changes apply immediately to the menu bar, Settings, and LCD dashboard."),

        .startupAndBackground: Pair(zhHans: "启动与后台运行", english: "Startup & Background"),
        .launchAtLogin: Pair(zhHans: "登录时自动启动", english: "Launch at Login"),
        .loginApprovalRequired: Pair(
            zhHans: "需要在“系统设置 → 通用 → 登录项”中批准。",
            english: "Approval is required in System Settings → General → Login Items."),
        .openSystemSettings: Pair(zhHans: "打开系统设置", english: "Open System Settings"),
        .packagedAppOnly: Pair(
            zhHans: "仅在运行打包后的 MacTR.app 时可用。",
            english: "Available when running the packaged MacTR.app."),
        .backgroundMode: Pair(zhHans: "后台运行方式", english: "Background mode"),
        .menuBar: Pair(zhHans: "菜单栏", english: "Menu bar"),
        .backgroundBehaviorHint: Pair(
            zhHans: "关闭设置或预览窗口后，MacTR 仍会在菜单栏中运行；如需彻底结束，请从菜单中选择“退出 MacTR”。",
            english: "Closing Settings or Preview keeps MacTR running in the menu bar. Choose “Quit MacTR” from the menu to stop it."),
        .autoShowPreview: Pair(
            zhHans: "LCD 断开时自动显示预览窗口",
            english: "Show Preview automatically when the LCD is disconnected"),
        .dailySchedule: Pair(zhHans: "每日计划", english: "Daily Schedule"),
        .enableDailySchedule: Pair(zhHans: "启用每日计划", english: "Enable daily schedule"),
        .atCloseTime: Pair(zhHans: "到达关闭时间时", english: "At close time"),
        .closeTime: Pair(zhHans: "关闭时间", english: "Close time"),
        .resumeAutomatically: Pair(zhHans: "自动恢复屏幕输出", english: "Resume output automatically"),
        .resumeTime: Pair(zhHans: "恢复时间", english: "Resume time"),
        .quitCannotResume: Pair(
            zhHans: "App 退出后无法自行定时启动。请手动重新打开 MacTR，或启用“登录时自动启动”。",
            english: "After quitting, the app cannot start itself later. Reopen MacTR manually or enable Launch at Login."),
        .scheduleDisabledDescription: Pair(
            zhHans: "每日计划当前未启用。",
            english: "The daily schedule is currently disabled."),
        .scheduleQuitDescription: Pair(
            zhHans: "MacTR 将在每天 %@ 自动退出。",
            english: "MacTR quits every day at %@."),
        .schedulePauseDescription: Pair(
            zhHans: "屏幕输出将在每天 %@ 暂停，之后需手动恢复。",
            english: "Display output pauses every day at %@ and resumes manually."),
        .scheduleActiveDescription: Pair(
            zhHans: "屏幕输出每天从 %@ 运行至 %@，支持跨午夜时段。",
            english: "Display output runs daily from %@ to %@. Overnight ranges are supported."),
        .performance: Pair(zhHans: "性能", english: "Performance"),
        .mode: Pair(zhHans: "运行模式", english: "Mode"),
        .eco: Pair(zhHans: "节能", english: "Eco"),
        .balanced: Pair(zhHans: "均衡", english: "Balanced"),
        .smooth: Pair(zhHans: "流畅", english: "Smooth"),
        .ecoDetail: Pair(
            zhHans: "CPU 占用最低；动画约 0.5–2 fps，指标刷新频率较低。",
            english: "Lowest CPU use; 0.5–2 fps with slower metric refresh."),
        .balancedDetail: Pair(
            zhHans: "适合长期运行；动画约 1–4 fps。",
            english: "Recommended for always-on use; 1–4 fps."),
        .smoothDetail: Pair(
            zhHans: "动画更流畅，约 2–10 fps，但会增加 CPU 占用。",
            english: "Smoother 2–10 fps animation with higher CPU use."),
        .balancedHint: Pair(
            zhHans: "均衡模式会降低动画与指标刷新频率，但不会省略任何仪表盘数据。",
            english: "Balanced lowers animation and metric cadence without removing any dashboard data."),

        .displaySet: Pair(zhHans: "显示内容", english: "Display Set"),
        .activeSet: Pair(zhHans: "当前内容", english: "Active Set"),
        .systemMonitor: Pair(zhHans: "系统监控", english: "System Monitor"),
        .brightness: Pair(zhHans: "亮度", english: "Brightness"),
        .level: Pair(zhHans: "级别", english: "Level"),
        .brightnessHint: Pair(zhHans: "1 为原始亮度，10 为最高亮度", english: "1 = original, 10 = maximum"),
        .rotation: Pair(zhHans: "旋转", english: "Rotation"),
        .rotate180: Pair(zhHans: "旋转 180°", english: "Rotate 180°"),
        .rotationHint: Pair(
            zhHans: "如果实体屏幕画面上下颠倒，请启用此选项。",
            english: "Enable if the physical display appears upside down."),
        .agentTokenUsage: Pair(zhHans: "Agent Token 用量", english: "Agent Token Usage"),
        .countCachedTokens: Pair(
            zhHans: "计入缓存读取的 Token",
            english: "Count cached-read tokens"),
        .countCachedTokensHint: Pair(
            zhHans: "开启时统计发给模型的全部输入，命中提示词缓存被重复读取的上下文也计算在内，"
                + "数字通常比 Claude Code / Codex 自己显示的大一个量级。"
                + "关闭后只统计当次新发送的内容（缓存写入仍计入）。",
            english: "On, this counts every input token sent to the model, including context "
                + "re-read from the prompt cache — usually an order of magnitude larger than "
                + "the figures Claude Code / Codex report. Off, only newly sent content counts "
                + "(cache writes still do)."),

        .customScriptCard: Pair(zhHans: "自定义脚本卡片", english: "Custom Script Card"),
        .showCustomScriptOutput: Pair(zhHans: "显示自定义脚本输出", english: "Show custom script output"),
        .script: Pair(zhHans: "脚本", english: "Script"),
        .notSelected: Pair(zhHans: "尚未选择", english: "Not selected"),
        .choose: Pair(zhHans: "选择…", english: "Choose…"),
        .clearScript: Pair(zhHans: "清除脚本", english: "Clear Script"),
        .cardName: Pair(zhHans: "卡片名称", english: "Card name"),
        .runEvery: Pair(zhHans: "执行间隔", english: "Run every"),
        .seconds: Pair(zhHans: "秒", english: "seconds"),
        .scriptIntervalHint: Pair(
            zhHans: "可设置为 5 秒至 24 小时。脚本不会重叠执行，超时后会自动终止。",
            english: "Allowed range: 5 seconds to 24 hours. Runs never overlap and time out automatically."),
        .scriptFontSize: Pair(zhHans: "正文字号", english: "Text size"),
        .fontAutomatic: Pair(zhHans: "自动", english: "Auto"),
        .fontSmall: Pair(zhHans: "小", english: "Small"),
        .fontMedium: Pair(zhHans: "中", english: "Medium"),
        .fontLarge: Pair(zhHans: "大", english: "Large"),
        .scriptFontSizeHint: Pair(
            zhHans: "自动模式会选择能完整显示内容的最大字号并垂直居中；长文本会逐级缩小，6 位验证码会使用大号居中排版。",
            english: "Auto chooses the largest size that fits and centers it vertically. Long text scales down; six-digit codes use a large centered layout."),
        .testAndStatus: Pair(zhHans: "测试与状态", english: "Test & Status"),
        .state: Pair(zhHans: "状态", english: "State"),
        .runNow: Pair(zhHans: "立即运行", english: "Run Now"),
        .executionRules: Pair(zhHans: "执行规则", english: "Execution Rules"),
        .shellExecutionRule: Pair(
            zhHans: "Shell 文件（.sh、.zsh 和 .command）使用系统自带的 /bin/zsh 运行。其他文件必须具有可执行权限并包含有效的 shebang。MacTR 只传递所选文件路径，不会解析或执行命令字符串。",
            english: "Shell files (.sh, .zsh and .command) run with the system /bin/zsh. Other files must be executable and include a valid shebang. MacTR passes the selected path directly and never evaluates a command string."),
        .scriptSecurityRule: Pair(
            zhHans: "脚本以当前用户身份运行，不会获得管理员权限。stdout 和 stderr 最多保留 8 KB，并会移除 ANSI 控制序列。",
            english: "The script runs as the current user without administrator privileges. stdout and stderr are capped at 8 KB; ANSI control sequences are removed."),
        .scriptDisabled: Pair(zhHans: "已停用", english: "Disabled"),
        .scriptChoose: Pair(zhHans: "请选择脚本", english: "Choose a script"),
        .scriptReady: Pair(zhHans: "就绪", english: "Ready"),
        .scriptRunning: Pair(zhHans: "正在运行", english: "Running"),
        .scriptSucceeded: Pair(zhHans: "上次运行成功", english: "Last run succeeded"),
        .scriptFailed: Pair(zhHans: "上次运行失败", english: "Last run failed"),
        .scriptTimedOut: Pair(zhHans: "运行超时", english: "Timed out"),
        .scriptMissing: Pair(zhHans: "找不到文件", english: "File not found"),
        .scriptInvalid: Pair(zhHans: "脚本无效", english: "Invalid script"),
        .chooseScriptTitle: Pair(
            zhHans: "为自定义卡片选择脚本",
            english: "Choose a Script for the Custom Card"),

        .output: Pair(zhHans: "屏幕输出", english: "Output"),
        .resumeDisplayOutput: Pair(zhHans: "恢复屏幕输出", english: "Resume Display Output"),
        .pauseDisplayOutput: Pair(zhHans: "暂停屏幕输出", english: "Pause Display Output"),
        .connection: Pair(zhHans: "设备连接", english: "Connection"),
        .resolution: Pair(zhHans: "分辨率", english: "Resolution"),
        .reconnect: Pair(zhHans: "重新连接", english: "Reconnect"),
        .statistics: Pair(zhHans: "运行统计", english: "Statistics"),
        .framesSent: Pair(zhHans: "已发送帧数", english: "Frames Sent"),
        .lastFrame: Pair(zhHans: "上一帧大小", english: "Last Frame"),
        .version: Pair(zhHans: "版本", english: "Version"),
        .appDescription: Pair(
            zhHans: "适用于利民 Trofeo Vision 9.16 LCD 的 AI 助手与系统监控工具",
            english: "AI agent and system monitor for the Thermalright Trofeo Vision 9.16 LCD"),
        .builtWith: Pair(zhHans: "使用 Swift 与 libusb 构建", english: "Built with Swift and libusb"),
        .githubReleases: Pair(zhHans: "GitHub 发布页面", english: "GitHub Releases"),

        .closeAction: Pair(zhHans: "关闭动作", english: "Close action"),
        .close: Pair(zhHans: "关闭", english: "Close"),
        .automaticResume: Pair(zhHans: "自动恢复", english: "Automatic resume"),
        .resume: Pair(zhHans: "恢复", english: "Resume"),
        .scheduledResumeUnavailable: Pair(
            zhHans: "退出 App 后无法执行定时恢复。",
            english: "Scheduled resume is unavailable after quitting the app."),

        .previewWindow: Pair(zhHans: "预览窗口", english: "Preview Window"),
        .enabled: Pair(zhHans: "启用", english: "Enabled"),
        .editTimes: Pair(zhHans: "编辑时间…", english: "Edit Times…"),
        .settings: Pair(zhHans: "设置…", english: "Settings…"),
        .viewLatestRelease: Pair(zhHans: "查看最新版本…", english: "View Latest Release…"),
        .aboutMacTR: Pair(zhHans: "关于 MacTR", english: "About MacTR"),
        .quitMacTR: Pair(zhHans: "退出 MacTR", english: "Quit MacTR"),
        .scheduleNextOff: Pair(zhHans: "已关闭", english: "Off"),
        .scheduleNextUnavailable: Pair(zhHans: "暂不可用", english: "Unavailable"),
        .scheduleNextStart: Pair(zhHans: "恢复", english: "Resume"),
        .scheduleNextQuit: Pair(zhHans: "退出", english: "Quit"),
        .scheduleNextPause: Pair(zhHans: "暂停", english: "Pause"),
        .previewTitle: Pair(zhHans: "MacTR — LCD 未连接，正在本机预览", english: "MacTR — LCD disconnected, showing local preview"),
        .scheduleWindowTitle: Pair(zhHans: "MacTR 每日计划", english: "MacTR Daily Schedule"),
        .settingsWindowTitle: Pair(zhHans: "MacTR 设置", english: "MacTR Settings"),
        .loginAlertTitle: Pair(zhHans: "登录时自动启动", english: "Launch at Login"),
        .aboutBody: Pair(
            zhHans: "版本 %@（构建 %@）\n\nMac + Thermalright\n利民 Trofeo Vision 9.16 LCD 的原生 macOS 驱动与系统监控工具。\n\n使用 Swift + libusb 构建\ngithub.com/luckykong/mac-thermalright-ai-monitor",
            english: "Version %@ (Build %@)\n\nMac + Thermalright\nNative macOS driver and system monitor for the Thermalright Trofeo Vision 9.16 LCD.\n\nBuilt with Swift + libusb\ngithub.com/luckykong/mac-thermalright-ai-monitor"),
        .ok: Pair(zhHans: "好", english: "OK"),

        .stopped: Pair(zhHans: "已停止", english: "Stopped"),
        .connecting: Pair(zhHans: "正在连接…", english: "Connecting…"),
        .resuming: Pair(zhHans: "正在恢复…", english: "Resuming…"),
        .disconnected: Pair(zhHans: "未连接", english: "Disconnected"),
        .deviceNotFound: Pair(zhHans: "未找到 LCD 设备", english: "Device not found"),
        .deviceBusy: Pair(zhHans: "设备正被占用（可能是 Chrome）", english: "Device busy (Chrome?)"),
        .errorPrefix: Pair(zhHans: "错误：%@", english: "Error: %@"),
        .connected: Pair(zhHans: "已连接（%@）", english: "Connected (%@)"),
        .handshakeFailed: Pair(zhHans: "设备握手失败", english: "Handshake failed"),
        .active: Pair(zhHans: "正在输出", english: "Active"),
        .sendError: Pair(zhHans: "连接已断开（发送失败）", english: "Disconnected (send error)"),
        .unplugged: Pair(zhHans: "连接已断开（设备已拔出）", english: "Disconnected (unplugged)"),
        .paused: Pair(zhHans: "已手动暂停", english: "Paused"),
        .pausedBySchedule: Pair(zhHans: "已按每日计划暂停", english: "Paused by daily schedule"),

        .cpuTemperature: Pair(zhHans: "温度", english: "TEMP"),
        .cpuLoadOneMinute: Pair(zhHans: "1 分钟负载", english: "LOAD 1M"),
        .gpuRender: Pair(zhHans: "渲染", english: "RENDER"),
        .gpuTiler: Pair(zhHans: "分块", english: "TILER"),
        .gpuMemory: Pair(zhHans: "显存", english: "MEM"),
        .memory: Pair(zhHans: "内存", english: "MEMORY"),
        .memoryCritical: Pair(zhHans: "严重", english: "CRITICAL"),
        .memoryPressure: Pair(zhHans: "有压力", english: "PRESSURE"),
        .memoryNormal: Pair(zhHans: "正常", english: "NORMAL"),
        .memoryBreakdown: Pair(
            zhHans: "活 %.1f  常 %.1f  压 %.1f  可 %.1f",
            english: "A %.1f  W %.1f  C %.1f  F %.1f"),
        .network: Pair(zhHans: "网络", english: "NETWORK"),
        .thirtySeconds: Pair(zhHans: "30 秒", english: "30 SEC"),
        .download: Pair(zhHans: "下载", english: "DOWN"),
        .upload: Pair(zhHans: "上传", english: "UP"),
        .scriptStateOK: Pair(zhHans: "成功", english: "OK"),
        .scriptStateRun: Pair(zhHans: "运行", english: "RUN"),
        .scriptStateError: Pair(zhHans: "错误", english: "ERROR"),
        .scriptStateReady: Pair(zhHans: "就绪", english: "READY"),
        .scriptStateOff: Pair(zhHans: "关闭", english: "OFF"),
        .scriptStateSetup: Pair(zhHans: "配置", english: "SETUP"),
        .scriptOff: Pair(zhHans: "脚本已关闭", english: "SCRIPT OFF"),
        .addScript: Pair(zhHans: "添加脚本", english: "ADD SCRIPT"),
        .enableInSettings: Pair(zhHans: "请在设置中启用", english: "Enable in Settings"),
        .customCardSettingsPath: Pair(zhHans: "设置 › 自定义卡片", english: "Settings › Custom Card"),
        .runningEllipsis: Pair(zhHans: "正在运行…", english: "Running…"),
        .noOutput: Pair(zhHans: "（暂无输出）", english: "(no output)"),
        .lastRun: Pair(zhHans: "上次 %@", english: "LAST %@"),
        .fanless: Pair(zhHans: "无风扇", english: "FANLESS"),
        .fanUnavailable: Pair(zhHans: "风扇 N/A", english: "FAN N/A"),
        .uptimeSummary: Pair(zhHans: "运行 %@ · %d 个进程", english: "UP %@ · %d PROCS"),
        .aiAgents: Pair(zhHans: "AI 助手", english: "AI AGENTS"),
        .notFound: Pair(zhHans: "未找到", english: "not found"),
        .now: Pair(zhHans: "刚刚", english: "now"),
        .minutesAgo: Pair(zhHans: "%d 分钟前", english: "%dm ago"),
        .hoursAgo: Pair(zhHans: "%d 小时前", english: "%dh ago"),
        .daysAgo: Pair(zhHans: "%d 天前", english: "%dd ago"),
        .noSession: Pair(zhHans: "暂无会话", english: "no session"),
        .step: Pair(zhHans: "步骤 %d/%d", english: "Step %d/%d"),
        .idle: Pair(zhHans: "空闲", english: "Idle"),
        .todayTokens: Pair(zhHans: "今日 Token", english: "Tokens Today"),
        .tokenInput: Pair(zhHans: "输入", english: "In"),
        .tokenOutput: Pair(zhHans: "输出", english: "Out"),
        .quotaRemaining: Pair(zhHans: "剩余额度 %.0f%%", english: "%.0f%% quota left"),
        .quotaRemainingCompact: Pair(zhHans: "剩余 %.0f%%", english: "%.0f%% left"),
        .resetDays: Pair(zhHans: "%d 天后重置", english: "resets in %dd"),
        .resetHours: Pair(zhHans: "%d 小时后重置", english: "resets in %dh"),
        .resetMinutes: Pair(zhHans: "%d 分钟后重置", english: "resets in %dm"),
    ]

    nonisolated static func format(
        _ key: L10nKey,
        language: AppLanguage,
        _ arguments: CVarArg...
    ) -> String {
        String(format: language.text(key), arguments: arguments)
    }

    /// Engine messages stay semantic and language-neutral internally so state
    /// detection and logging remain stable. Translate only at the presentation edge.
    nonisolated static func localizedStatus(
        _ message: String,
        language: AppLanguage
    ) -> String {
        let exact: [String: L10nKey] = [
            "Stopped": .stopped,
            "Connecting...": .connecting,
            "Resuming...": .resuming,
            "Disconnected": .disconnected,
            "Device not found": .deviceNotFound,
            "Device busy (Chrome?)": .deviceBusy,
            "Handshake failed": .handshakeFailed,
            "Active": .active,
            "Disconnected (send error)": .sendError,
            "Disconnected (unplugged)": .unplugged,
            "Paused": .paused,
            "Paused by daily schedule": .pausedBySchedule,
        ]
        if let key = exact[message] {
            return language.text(key)
        }
        if message.hasPrefix("Connected ("), message.hasSuffix(")") {
            let detail = String(message.dropFirst("Connected (".count).dropLast())
            return format(.connected, language: language, detail)
        }
        if message.hasPrefix("Error: ") {
            return format(
                .errorPrefix,
                language: language,
                String(message.dropFirst("Error: ".count)))
        }
        return message
    }
}
