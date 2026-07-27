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
}
