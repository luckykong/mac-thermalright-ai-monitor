// MonitorRenderer+SystemCards.swift — the six cards down the left of the
// panel: CPU, GPU, memory, network, the custom script card and the clock.

import AppKit
import CoreGraphics
import Foundation

extension MonitorRenderer {

    // MARK: - Compact System Cards

    func renderCPU(
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
            // Was 49 pt. The sprite is 170 px, so that much downscaling averaged
            // away the red cheeks and black outlines and left a pale yellow
            // blob — the artwork is full colour, it just had no room to show it.
            let size: CGFloat = 66
            var rect = CGRect(x: CGFloat(x + w - 82), y: CGFloat(y + 40),
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

    func renderGPU(
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
            let width = TextMetrics.width(of: value, font: font)
            Draw.text(ctx, value, x: Int(CGFloat(x + w - 14) - width), y: y + 108,
                      font: font, color: gpuTemp > 70 ? Color.red : Color.green)
        }
    }

    func renderMemory(
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

    func renderNetwork(
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
        let rangeWidth = TextMetrics.width(of: rangeLabel, font: rangeFont)
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
        let upWidth = TextMetrics.width(of: up, font: rateFont)
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

    func paddedNetworkHistory(
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

    func renderCustomScript(
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
        let stateWidth = TextMetrics.width(of: stateText, font: stateFont)
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

    func renderClockAndFan(
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
        let hmWidth = TextMetrics.width(of: hm, font: hmFont)
        let secondsWidth = TextMetrics.width(of: seconds, font: secondsFont)
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
            let labelWidth = TextMetrics.width(of: fanLabel, font: fanFont)
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

        // Was 0.54. The card has ~112 pt of clear space above the desk line and
        // is 190 pt wide, so the cat was using well under half of what it had.
        let catScale: CGFloat = 0.78
        drawBongoCat(
            ctx, cx: x + w / 2, baseY: y + h - 12,
            tapping: agentsBusy, phase: Int(t * 5) % 2 == 0, scale: catScale)
    }

    func drawFanRotor(
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

    func drawCompactGauge(_ ctx: CGContext, cx: Int, cy: Int,
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

    func drawLabeledMiniBar(_ ctx: CGContext, label: String, value: Double,
                                    x: Int, y: Int, w: Int, color: CGColor) {
        Draw.text(ctx, label, x: x, y: y,
                  font: Fonts.system(10, weight: .semibold), color: Color.textL)
        let valueText = String(format: "%.0f%%", value)
        let font = Fonts.system(10, weight: .semibold)
        let valueWidth = TextMetrics.width(of: valueText, font: font)
        Draw.text(ctx, valueText, x: Int(CGFloat(x + w) - valueWidth), y: y,
                  font: font, color: Color.textS)
        Draw.bar(ctx, x: x, y: y + 16, w: w, h: 6, percent: value, color: color)
    }

    func drawCoreStrip(_ ctx: CGContext, values: [Double], pCoreCount: Int,
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

    func drawStackedBar(_ ctx: CGContext, values: [Double], colors: [CGColor],
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
    func drawElectricity(_ ctx: CGContext, around rect: CGRect,
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

}
