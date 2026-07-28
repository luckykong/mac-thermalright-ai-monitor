import Foundation
import Testing
@testable import MacTR

@Suite("Custom script adaptive typography")
struct CustomScriptTypographyTests {
    private let cardWidth: CGFloat = 252
    private let cardHeight = 207

    @Test("Short weather output grows and remains complete")
    func weatherCard() {
        let output = """
            广州 · 02:20
            未来两小时无降水
            当前 0 峰值 0
            2h累计 0 mm
            雨势············
            """
        let layout = CustomScriptTypography.layout(
            output: output,
            mode: .automatic,
            maxWidth: cardWidth,
            availableHeight: cardHeight)

        #expect(layout.fontSize >= 24)
        #expect(!layout.truncated)
        #expect(layout.lines.count == 5)
        #expect(layout.topInset > 0)
    }

    @Test("Six-digit codes become large and centered")
    func verificationCode() {
        let layout = CustomScriptTypography.layout(
            output: "582104",
            mode: .automatic,
            maxWidth: cardWidth,
            availableHeight: cardHeight)

        #expect(layout.fontSize >= 52)
        #expect(layout.lines == ["582104"])
        #expect(layout.centered)
        #expect(!layout.truncated)
    }

    @Test("Manual presets cap the preferred size")
    func manualModes() {
        let small = CustomScriptTypography.layout(
            output: "OK", mode: .small,
            maxWidth: cardWidth, availableHeight: cardHeight)
        let medium = CustomScriptTypography.layout(
            output: "OK", mode: .medium,
            maxWidth: cardWidth, availableHeight: cardHeight)
        let large = CustomScriptTypography.layout(
            output: "OK", mode: .large,
            maxWidth: cardWidth, availableHeight: cardHeight)

        #expect(small.fontSize == 16)
        #expect(medium.fontSize == 22)
        #expect(large.fontSize == 30)
    }

    @Test("Long output falls back and truncates inside the card")
    func longText() {
        let output = String(repeating: "很长的自定义脚本输出 ", count: 200)
        let layout = CustomScriptTypography.layout(
            output: output,
            mode: .automatic,
            maxWidth: cardWidth,
            availableHeight: cardHeight)

        #expect(layout.fontSize == CustomScriptTypography.minimumFontSize)
        #expect(layout.truncated)
        #expect(layout.lines.count * layout.lineHeight <= cardHeight)
        #expect(layout.lines.last?.hasSuffix("…") == true)
    }

    /// Laying this out walks up to fourteen font sizes measuring once per
    /// character, and it used to run on every frame even though the text behind
    /// it changes on a timer measured in minutes. Memoizing it must not change
    /// what comes back.
    @Test("Repeating a layout returns the same result from cache")
    func layoutIsMemoized() {
        let output = "广州 · 02:20\n未来两小时无降水\n当前 0 峰值 0"

        func run() -> CustomScriptTextLayout {
            CustomScriptTypography.layout(
                output: output, mode: .automatic,
                maxWidth: cardWidth, availableHeight: cardHeight)
        }

        #expect(run() == run())

        // A different width is a different question and must not reuse the
        // answer — the card is narrower in the split agent layout.
        let narrower = CustomScriptTypography.layout(
            output: output, mode: .automatic,
            maxWidth: cardWidth / 2, availableHeight: cardHeight)
        #expect(narrower.fontSize <= run().fontSize)

        // Same text, forced small, must not come back at the automatic size.
        let small = CustomScriptTypography.layout(
            output: output, mode: .small,
            maxWidth: cardWidth, availableHeight: cardHeight)
        #expect(small.fontSize <= 16)
    }
}

@Suite("Text measurement cache")
struct TextMetricsTests {
    @Test("A repeated measurement is served from the cache")
    func measurementIsMemoized() {
        let cache = MemoCache<String, Int>(capacity: 8)
        var computed = 0
        for _ in 0..<5 {
            _ = cache.value(for: "same") { computed += 1; return 42 }
        }
        #expect(computed == 1)
        #expect(cache.value(for: "same") { 0 } == 42)
    }

    /// The table clears rather than evicting one entry at a time, so the only
    /// guarantee is that it never grows past its capacity.
    @Test("The cache stays within its capacity")
    func capacityIsBounded() {
        let cache = MemoCache<Int, Int>(capacity: 4)
        for i in 0..<50 { _ = cache.value(for: i) { i } }
        #expect(cache.count <= 4)
    }

    @Test("Cached widths match a direct measurement")
    func widthsAreCorrect() {
        let font = Fonts.system(18, weight: .bold)
        let direct = ("剩余 94%" as NSString)
            .size(withAttributes: [.font: font]).width
        #expect(TextMetrics.width(of: "剩余 94%", font: font) == direct)
        // Second call comes from the cache and must still agree.
        #expect(TextMetrics.width(of: "剩余 94%", font: font) == direct)
    }
}
