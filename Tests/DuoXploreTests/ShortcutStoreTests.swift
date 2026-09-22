import XCTest
@testable import DuoXplore

/// 快捷键匹配与 UserDefaults 持久化的自检
@MainActor
final class ShortcutStoreTests: XCTestCase {
    private func makeStore() -> ShortcutStore {
        ShortcutStore(defaults: UserDefaults(suiteName: "ShortcutStoreTests")!)
    }

    func testPersistenceRoundTrip() {
        let suite = UserDefaults(suiteName: "ShortcutStoreTests")!
        suite.removePersistentDomain(forName: "ShortcutStoreTests")

        let store = makeStore()
        store.set(KeyCombo(keyCode: 15, modifiers: [.command], label: "P"), for: .renameItem)

        XCTAssertEqual(makeStore().combo(for: .renameItem), KeyCombo(keyCode: 15, modifiers: [.command], label: "P"))
        XCTAssertEqual(makeStore().combo(for: .navigateUp), ShortcutAction.navigateUp.defaultCombo)
    }

    func testResetRestoresDefault() {
        let suite = UserDefaults(suiteName: "ShortcutStoreTests")!
        suite.removePersistentDomain(forName: "ShortcutStoreTests")

        let store = makeStore()
        store.set(KeyCombo(keyCode: 15, modifiers: [], label: "p"), for: .openItem)
        store.reset(.openItem)

        XCTAssertEqual(store.combo(for: .openItem), ShortcutAction.openItem.defaultCombo)
    }

    func testIsMatchIgnoresNoiseModifierBits() {
        let combo = KeyCombo(keyCode: 120, modifiers: [], label: "F2")

        // 真实 F2 事件会带 .function 位
        XCTAssertTrue(ShortcutStore.isMatch(120, [.function], combo))
        XCTAssertTrue(ShortcutStore.isMatch(120, [], combo))
        XCTAssertFalse(ShortcutStore.isMatch(120, [.command], combo))
        XCTAssertFalse(ShortcutStore.isMatch(51, [], combo))
    }
}
