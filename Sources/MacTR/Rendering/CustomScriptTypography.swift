// CustomScriptTypography.swift — adaptive text layout for the custom card

import AppKit
import Foundation

struct CustomScriptTextLayout: Equatable {
    let fontSize: CGFloat
    let lineHeight: Int
    let lines: [String]
    let topInset: Int
    let centered: Bool
    let truncated: Bool
}

enum CustomScriptTypography {
    static let minimumFontSize: CGFloat = 15

    private struct WrappedText {
        let lines: [String]
        let truncated: Bool
    }

    private struct LayoutKey: Hashable {
        let output: String
        let mode: CustomScriptFontMode
        let maxWidth: CGFloat
        let availableHeight: Int
    }

    /// This is the renderer's most expensive call by a wide margin: it walks up
    /// to fourteen candidate font sizes and, for each, measures once per
    /// character of the output. It is also the most repetitive — the card's text
    /// comes from a script that runs on an interval measured in minutes, while
    /// this ran on every frame.
    ///
    /// Small on purpose. The key includes the output text, so a card whose
    /// script emits a clock would otherwise grow an entry per tick; a handful of
    /// entries covers the real cases (current text, plus the card geometry
    /// changing when the layout does).
    private static let layouts = MemoCache<LayoutKey, CustomScriptTextLayout>(
        capacity: 32)

    static func layout(
        output: String,
        mode: CustomScriptFontMode,
        maxWidth: CGFloat,
        availableHeight: Int
    ) -> CustomScriptTextLayout {
        layouts.value(
            for: LayoutKey(
                output: output, mode: mode,
                maxWidth: maxWidth, availableHeight: availableHeight)
        ) {
            computeLayout(
                output: output, mode: mode,
                maxWidth: maxWidth, availableHeight: availableHeight)
        }
    }

    private static func computeLayout(
        output: String,
        mode: CustomScriptFontMode,
        maxWidth: CGFloat,
        availableHeight: Int
    ) -> CustomScriptTextLayout {
        let normalized = output
            .replacingOccurrences(of: "\t", with: "    ")
            .trimmingCharacters(in: .newlines)
        let value = normalized.isEmpty ? "(no output)" : normalized
        let isSixDigitCode =
            value.range(of: #"^[0-9]{6}$"#, options: .regularExpression) != nil
        let candidates = fontCandidates(mode: mode, isSixDigitCode: isSixDigitCode)

        for size in candidates {
            let font = Fonts.mono(size)
            let lineHeight = lineHeight(for: font)
            let maxLines = max(availableHeight / lineHeight, 1)
            let wrapped = wrap(
                value,
                font: font,
                maxWidth: maxWidth,
                maxLines: maxLines)
            guard !wrapped.truncated else { continue }
            return makeLayout(
                size: size,
                lineHeight: lineHeight,
                lines: wrapped.lines,
                availableHeight: availableHeight,
                centered: isSixDigitCode || wrapped.lines.count == 1,
                truncated: false)
        }

        let fallbackSize = candidates.last ?? minimumFontSize
        let fallbackFont = Fonts.mono(fallbackSize)
        let fallbackLineHeight = lineHeight(for: fallbackFont)
        let fallbackMaxLines = max(availableHeight / fallbackLineHeight, 1)
        let fallback = wrap(
            value,
            font: fallbackFont,
            maxWidth: maxWidth,
            maxLines: fallbackMaxLines)
        return makeLayout(
            size: fallbackSize,
            lineHeight: fallbackLineHeight,
            lines: fallback.lines,
            availableHeight: availableHeight,
            centered: isSixDigitCode || fallback.lines.count == 1,
            truncated: fallback.truncated)
    }

    private static func fontCandidates(
        mode: CustomScriptFontMode,
        isSixDigitCode: Bool
    ) -> [CGFloat] {
        switch mode {
        case .automatic:
            return isSixDigitCode
                ? [60, 56, 52, 48, 44, 40, 36, 32, 28, 24, 20, 18, 16, 15]
                : [48, 44, 40, 36, 32, 30, 28, 26, 24, 22, 20, 18, 16, 15]
        case .small:
            return [16, 15]
        case .medium:
            return [22, 20, 18, 16, 15]
        case .large:
            return [30, 28, 26, 24, 22, 20, 18, 16, 15]
        }
    }

    private static func lineHeight(for font: NSFont) -> Int {
        Int(ceil(font.ascender - font.descender + font.leading)) + 3
    }

    private static func makeLayout(
        size: CGFloat,
        lineHeight: Int,
        lines: [String],
        availableHeight: Int,
        centered: Bool,
        truncated: Bool
    ) -> CustomScriptTextLayout {
        let safeLines = lines.isEmpty ? [""] : lines
        let contentHeight = safeLines.count * lineHeight
        return CustomScriptTextLayout(
            fontSize: size,
            lineHeight: lineHeight,
            lines: safeLines,
            topInset: max((availableHeight - contentHeight) / 2, 0),
            centered: centered,
            truncated: truncated)
    }

    private static func wrap(
        _ value: String,
        font: NSFont,
        maxWidth: CGFloat,
        maxLines: Int
    ) -> WrappedText {
        let characters = Array(value)
        var lines: [String] = []
        var current = ""
        var truncated = false

        func appendLine(_ line: String) -> Bool {
            guard lines.count < maxLines else { return false }
            lines.append(line)
            return true
        }

        for character in characters {
            if character == "\n" {
                if !appendLine(current) {
                    truncated = true
                    break
                }
                current = ""
                continue
            }

            let candidate = current + String(character)
            if width(of: candidate, font: font) <= maxWidth {
                current = candidate
                continue
            }

            if current.isEmpty {
                if !appendLine(ellipsize(
                    String(character), font: font, maxWidth: maxWidth))
                {
                    truncated = true
                    break
                }
            } else {
                if !appendLine(current) {
                    truncated = true
                    break
                }
                current = String(character)
            }
        }

        if !truncated, !current.isEmpty {
            if !appendLine(current) {
                truncated = true
            }
        }

        if truncated {
            if lines.isEmpty {
                lines = ["…"]
            } else {
                lines[lines.count - 1] = ellipsize(
                    lines[lines.count - 1] + "…",
                    font: font,
                    maxWidth: maxWidth)
            }
        }
        return WrappedText(lines: lines, truncated: truncated)
    }

    private static func ellipsize(
        _ value: String,
        font: NSFont,
        maxWidth: CGFloat
    ) -> String {
        if width(of: value, font: font) <= maxWidth { return value }
        var result = value
        while !result.isEmpty {
            result.removeLast()
            let candidate = result + "…"
            if width(of: candidate, font: font) <= maxWidth {
                return candidate
            }
        }
        return "…"
    }

    /// Still measured per character, but each distinct prefix is now measured
    /// once for the lifetime of the process rather than once per frame.
    private static func width(of value: String, font: NSFont) -> CGFloat {
        TextMetrics.width(of: value, font: font)
    }
}
