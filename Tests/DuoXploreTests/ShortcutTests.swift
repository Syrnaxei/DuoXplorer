import XCTest
@testable import DuoXplore

/// 快捷键匹配与默认键位的自检
final class ShortcutTests: XCTestCase {
    func testMatchesIgnoresNoiseModifierBits() {
        let combo = KeyCombo(keyCode: 31, modifiers: [.command], label: "O")

        // 真实按键事件会带 .function 位，需按去噪后掩码精确比较
        XCTAssertTrue(combo.matches(keyCode: 31, flags: [.command]))
        XCTAssertTrue(combo.matches(keyCode: 31, flags: [.command, .function]))
        XCTAssertFalse(combo.matches(keyCode: 31, flags: [.command, .shift]))
        XCTAssertFalse(combo.matches(keyCode: 51, flags: [.command]))
    }

    func testDefaultCombosAreFinderConventions() {
        XCTAssertEqual(ShortcutAction.navigateUp.defaultCombo.display, "⌘↑")
        XCTAssertEqual(ShortcutAction.openItem.defaultCombo.display, "⌘↩")
        XCTAssertEqual(ShortcutAction.openItem.defaultCombo, KeyCombo(keyCode: 36, modifiers: [.command], label: "↩"))
        XCTAssertEqual(ShortcutAction.renameItem.defaultCombo.display, "↩")
    }
}
