import XCTest
@testable import CodexReset

final class EnglishLanguageTests: XCTestCase {
    func testBuiltInCopyAlwaysUsesEnglish() {
        XCTAssertEqual(L("用量已恢复", "Usage recovered"), "Usage recovered")
        XCTAssertEqual(L("继续失败", "Continue failed"), "Continue failed")
    }

    func testLegacyChineseDefaultCommandMigratesToEnglish() {
        XCTAssertEqual(englishContinueCommand(nil), "Continue")
        XCTAssertEqual(englishContinueCommand("继续"), "Continue")
        XCTAssertEqual(englishContinueCommand("Continue"), "Continue")
    }

    func testCustomCommandIsPreserved() {
        XCTAssertEqual(englishContinueCommand("Keep working on the task"), "Keep working on the task")
        XCTAssertEqual(englishContinueCommand(""), "")
    }
}
