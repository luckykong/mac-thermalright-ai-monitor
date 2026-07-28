// MonitorRenderer+Agents.swift — the AI agents panel: the two columns, their
// quota bars and step badges, and the markdown-aware message layout.

import AppKit
import CoreGraphics
import Foundation

extension MonitorRenderer {

    // MARK: - AI Agents Panel

    func renderAgents(
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

    func renderAgentColumn(_ ctx: CGContext, x: Int, w: Int, py: Int,
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
        let agoW = TextMetrics.width(of: agoStr, font: agoFont)
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
                let bW = TextMetrics.width(of: badge, font: bFont)
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
            let valW = TextMetrics.width(of: valStr, font: ioFont)
            Draw.text(ctx, valStr, x: Int(CGFloat(x + w) - valW), y: ry,
                      font: ioFont, color: Color.textS)
            let labelW = TextMetrics.width(of: row.0, font: ioFont)
            Draw.text(ctx, row.0, x: Int(CGFloat(x + w) - valW - labelW - 10), y: ry,
                      font: ioFont, color: Color.textL)
        }

        // Rate-limit windows. Codex reports one and it spans the column; Claude
        // has both a 5-hour and a 7-day window, which split the width. Side by
        // side rather than stacked because the bar already sits ~12 px above
        // the bottom of the panel — there is no room for a second row.
        let quotaWindows = usage.quotaWindows
        if !quotaWindows.isEmpty {
            let qy = tokY + 78
            let gap = 18
            let slotW = quotaWindows.count > 1
                ? (w - gap * (quotaWindows.count - 1)) / quotaWindows.count
                : w
            for (index, window) in quotaWindows.enumerated() {
                drawQuotaWindow(
                    ctx,
                    x: x + index * (slotW + gap),
                    y: qy,
                    w: slotW,
                    window: window,
                    compact: quotaWindows.count > 1,
                    language: language)
            }
        }
    }

    /// One rate-limit window: an optional window label, remaining percentage,
    /// a right-aligned reset countdown, and a remaining-capacity bar.
    ///
    /// `compact` shortens both texts for the split layout — at half width the
    /// full "剩余额度 78%" plus "3 小时后重置" needs 221 pt of a 236 pt slot.
    func drawQuotaWindow(
        _ ctx: CGContext,
        x: Int,
        y: Int,
        w: Int,
        window: QuotaWindow,
        compact: Bool,
        language: AppLanguage
    ) {
        let remaining = max(0, 100 - window.usedPercent)
        let color: CGColor = remaining > 50 ? Color.green
            : (remaining > 20 ? Color.orange : Color.red)

        var textX = x
        if !window.label.isEmpty {
            let labelFont = Fonts.system(15, weight: .semibold)
            Draw.text(ctx, window.label, x: textX, y: y + 3,
                      font: labelFont, color: Color.textD)
            textX += Int(TextMetrics.width(of: window.label, font: labelFont)) + 8
        }

        Draw.text(
            ctx,
            AppLocalization.format(
                compact ? .quotaRemainingCompact : .quotaRemaining,
                language: language,
                remaining),
            x: textX, y: y,
            font: Fonts.system(18, weight: .medium), color: color)

        if let resets = window.resetsAt {
            // One wording everywhere. The split layout used to fall back to a
            // bare "3h"/"4d", which read as Latin shorthand next to Codex's
            // Chinese countdown in the very same panel.
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
            let resetFont = Fonts.system(15)
            let resetW = TextMetrics.width(of: resetStr, font: resetFont)
            Draw.text(ctx, resetStr, x: Int(CGFloat(x + w) - resetW), y: y + 3,
                      font: resetFont, color: Color.textD)
        }

        Draw.bar(ctx, x: x, y: y + 28, w: w, h: 8,
                 percent: remaining, color: color)
    }

    /// Segmented plan-progress bar: completed steps solid, current bright, pending dim.
    func drawStepBar(_ ctx: CGContext, x: Int, y: Int, w: Int,
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
    func formatTokens(_ n: UInt64, language: AppLanguage) -> String {
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
    func renderMessage(_ ctx: CGContext, text: String, x: Int, y: Int, w: Int,
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

    func isTableLine(_ s: String) -> Bool {
        s.hasPrefix("|") && s.filter { $0 == "|" }.count >= 2
    }

    /// A markdown separator cell like `---`, `:--`, `--:`, `:-:`.
    func isSeparatorCell(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0 == "-" || $0 == ":" } && s.contains("-")
    }

    func stripMarkdown(_ s: String) -> String {
        s.replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "**", with: "")
    }

    /// Render markdown table rows as an aligned grid. Returns the new y below it.
    func renderTable(_ ctx: CGContext, rows rawRows: [String], x: Int, y: Int,
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
    func truncate(_ s: String, font: NSFont, maxW: CGFloat) -> String {
        if TextMetrics.width(of: s, font: font) <= maxW { return s }
        var t = s
        while !t.isEmpty {
            t.removeLast()
            if TextMetrics.width(of: t + "…", font: font) <= maxW {
                return t + "…"
            }
        }
        return "…"
    }

    /// Greedy character wrap (activity text may be CJK — no word boundaries).
    func wrap(_ s: String, font: NSFont, maxW: CGFloat, maxLines: Int) -> [String] {
        guard maxLines >= 1 else { return [] }
        var lines: [String] = []
        var current = ""
        for ch in s {
            let candidate = current + String(ch)
            if TextMetrics.width(of: candidate, font: font) > maxW {
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
