import Foundation
import Testing
@testable import MacTR

@Suite("Runtime localization")
struct LocalizationTests {
    @Test("Every localization key has both languages")
    func completeCatalog() {
        #expect(AppLocalization.strings.count == L10nKey.allCases.count)
        for key in L10nKey.allCases {
            let pair = AppLocalization.strings[key]
            #expect(pair != nil)
            #expect(!(pair?.zhHans.isEmpty ?? true))
            #expect(!(pair?.english.isEmpty ?? true))
        }
    }

    @Test("Simplified Chinese is the first-run default and language persists")
    @MainActor
    func defaultAndPersistence() throws {
        let suiteName = "com.beret21.MacTR.tests.localization"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AppPreferences(defaults: defaults)
        #expect(first.language == .simplifiedChinese)
        first.language = .english

        let restored = AppPreferences(defaults: defaults)
        #expect(restored.language == .english)
    }

    @Test("Runtime status messages preserve details")
    func statusMessages() {
        #expect(AppLocalization.localizedStatus(
            "Device not found",
            language: .simplifiedChinese) == "未找到 LCD 设备")
        #expect(AppLocalization.localizedStatus(
            "Connected (1920x480)",
            language: .simplifiedChinese) == "已连接（1920x480）")
        #expect(AppLocalization.localizedStatus(
            "Error: timeout",
            language: .english) == "Error: timeout")
    }
}
