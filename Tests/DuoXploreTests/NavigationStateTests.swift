import XCTest
@testable import DuoXplore

@MainActor
final class NavigationStateTests: XCTestCase {

    func testBackForwardAcrossFoldersAndTags() {
        let state = NavigationState()
        let a = URL(fileURLWithPath: "/tmp/a")
        let b = URL(fileURLWithPath: "/tmp/b")
        let tag = FinderTag.all[0]

        // 模拟 a → b → 标签页：当前位置不入栈（与侧边栏/导航的 push 约定一致）
        state.push(.folder(a))
        state.push(.folder(b))

        // 后退：标签 → b → a
        XCTAssertEqual(state.goBack(from: .tag(tag)), .folder(b))
        XCTAssertEqual(state.goBack(from: .folder(b)), .folder(a))
        XCTAssertFalse(state.canGoBack())

        // 前进：a → b → 标签
        XCTAssertEqual(state.goForward(from: .folder(a)), .folder(b))
        XCTAssertEqual(state.goForward(from: .folder(b)), .tag(tag))
        XCTAssertFalse(state.canGoForward())

        // 新导航清空前进栈
        state.push(.folder(a))
        XCTAssertFalse(state.canGoForward())
    }
}
