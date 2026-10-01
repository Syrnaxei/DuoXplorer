import Foundation

/// 历史条目：真实目录或颜色标签页（标签页视为一种「位置」参与前进/后退）
enum NavLocation: Equatable {
    case folder(URL)
    case tag(FinderTag)
}

/// 导航状态管理 — 前进/后退历史
@MainActor
final class NavigationState: ObservableObject {

    private var backStack: [NavLocation] = []
    private var forwardStack: [NavLocation] = []

    func push(_ location: NavLocation) {
        backStack.append(location)
        forwardStack.removeAll()
    }

    func goBack(from current: NavLocation) -> NavLocation? {
        guard !backStack.isEmpty else { return nil }
        forwardStack.append(current)
        return backStack.removeLast()
    }

    func goForward(from current: NavLocation) -> NavLocation? {
        guard !forwardStack.isEmpty else { return nil }
        backStack.append(current)
        return forwardStack.removeLast()
    }

    func canGoBack() -> Bool { !backStack.isEmpty }
    func canGoForward() -> Bool { !forwardStack.isEmpty }
}
