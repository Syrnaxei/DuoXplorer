import AppKit
import SwiftUI

// MARK: - 共享设置模型（菜单、右键菜单与设置窗口共用）

@MainActor
final class AppSettingsModel: ObservableObject {
    @Published var showHiddenFiles = false
}

// MARK: - 原生 AppKit 设置窗口（仿访达设置：工具栏标签切换）

@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {

    enum Tab: CaseIterable {
        case general, tags, sidebar, shortcuts, advanced

        var identifier: NSToolbarItem.Identifier { NSToolbarItem.Identifier("settings.\(self)") }

        var title: String {
            switch self {
            case .general: return "通用"
            case .tags: return "标签"
            case .sidebar: return "边栏"
            case .shortcuts: return "快捷键"
            case .advanced: return "高级"
            }
        }

        var symbolName: String {
            switch self {
            case .general: return "gearshape"
            case .tags: return "tag"
            case .sidebar: return "sidebar.left"
            case .shortcuts: return "keyboard"
            case .advanced: return "gearshape.2"
            }
        }
    }

    private let appSettings: AppSettingsModel
    private let container = NSView()
    private var showHiddenCheckbox: NSButton?

    init(appSettings: AppSettingsModel) {
        self.appSettings = appSettings
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DuoXplore 设置"
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.center()

        super.init(window: window)
        window.contentView = container

        let toolbar = NSToolbar(identifier: "DuoXploreSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        toolbar.selectedItemIdentifier = Tab.general.identifier
        select(.general)
    }

    required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        showHiddenCheckbox?.state = appSettings.showHiddenFiles ? .on : .off
    }

    // MARK: 标签切换

    private func select(_ tab: Tab) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let content: NSView
        var pinAllEdges = false
        switch tab {
        case .general, .tags, .sidebar:
            content = Self.placeholderView()
            pinAllEdges = true
        case .shortcuts:
            content = NSHostingView(rootView: ShortcutSettingsView())
        case .advanced:
            content = advancedView()
        }
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        var constraints = [
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
        ]
        if pinAllEdges {
            constraints += [
                content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    private static func placeholderView() -> NSView {
        let label = NSTextField(labelWithString: "暂无可配置项")
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 13)
        let view = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }

    private func advancedView() -> NSView {
        let checkbox = NSButton(checkboxWithTitle: "显示隐藏项目", target: self, action: #selector(toggleShowHidden(_:)))
        checkbox.state = appSettings.showHiddenFiles ? .on : .off
        showHiddenCheckbox = checkbox
        let stack = NSStackView(views: [checkbox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        return stack
    }

    @objc private func toggleShowHidden(_ sender: NSButton) {
        appSettings.showHiddenFiles = sender.state == .on
    }

    @objc private func tabSelected(_ sender: NSToolbarItem) {
        guard let tab = Tab.allCases.first(where: { $0.identifier == sender.itemIdentifier }) else { return }
        select(tab)
    }

    // MARK: NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Tab.allCases.map(\.identifier)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Tab.allCases.map(\.identifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Tab.allCases.map(\.identifier)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = Tab.allCases.first(where: { $0.identifier == id }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(tabSelected(_:))
        return item
    }
}
