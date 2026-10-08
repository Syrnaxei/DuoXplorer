import SwiftUI
import AppKit

// MARK: - FileMenuItem → NSMenu 构建（右键菜单与工具栏菜单共用）

final class MenuActionBox {
    let action: () -> Void
    init(action: @escaping () -> Void) { self.action = action }
}

/// NSMenuItem 的 target 需要常驻对象；单例转发到 representedObject 里的闭包
@MainActor final class MenuActionRelay: NSObject {
    static let shared = MenuActionRelay()

    @objc func itemClicked(_ sender: NSMenuItem) {
        (sender.representedObject as? MenuActionBox)?.action()
    }
}

/// 递归构建 NSMenu（子菜单）；autoenablesItems 必须关掉，否则 enabled 状态不生效
@MainActor func makeNativeMenu(from specs: [FileMenuItem]) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for spec in specs {
        if spec.isDivider {
            menu.addItem(.separator())
        } else {
            let item = NSMenuItem(
                title: spec.title,
                action: #selector(MenuActionRelay.itemClicked(_:)),
                keyEquivalent: spec.keyEquivalent ?? ""
            )
            item.target = MenuActionRelay.shared
            item.isEnabled = spec.enabled
            item.state = spec.state
            item.keyEquivalentModifierMask = spec.keyEquivalentModifierMask
            if !spec.subItems.isEmpty {
                item.submenu = makeNativeMenu(from: spec.subItems)
            }
            item.representedObject = MenuActionBox(action: spec.action)
            menu.addItem(item)
        }
    }
    return menu
}

// MARK: - 工具栏弹出菜单按钮（••• / 编辑标签）

struct ToolbarMenuButton: NSViewRepresentable {
    let symbol: String
    let helpText: String
    let isEnabled: Bool
    let menuProvider: () -> [FileMenuItem]

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: Self.icon(symbol), target: context.coordinator, action: #selector(Coordinator.clicked))
        button.isBordered = false
        button.toolTip = helpText
        button.setAccessibilityIdentifier(helpText)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.isEnabled = isEnabled
        button.contentTintColor = isEnabled ? nil : .disabledControlTextColor
        context.coordinator.owner = self
    }

    private static func icon(_ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        return image.withSymbolConfiguration(config) ?? image
    }

    @MainActor final class Coordinator: NSObject {
        var owner: ToolbarMenuButton
        init(owner: ToolbarMenuButton) { self.owner = owner }

        @objc func clicked(_ sender: NSButton) {
            guard owner.isEnabled else { return }
            let menu = makeNativeMenu(from: owner.menuProvider())
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        }
    }
}

// MARK: - 工具栏分享按钮（NSSharingServicePicker）

struct ToolbarShareButton: NSViewRepresentable {
    let isEnabled: Bool
    let itemsProvider: () -> [Any]

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(image: Self.icon(), target: context.coordinator, action: #selector(Coordinator.clicked))
        button.isBordered = false
        button.toolTip = "分享"
        button.setAccessibilityIdentifier("分享")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.isEnabled = isEnabled
        button.contentTintColor = isEnabled ? nil : .disabledControlTextColor
        context.coordinator.owner = self
    }

    private static func icon() -> NSImage {
        let image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "分享") ?? NSImage()
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        return image.withSymbolConfiguration(config) ?? image
    }

    @MainActor final class Coordinator: NSObject {
        var owner: ToolbarShareButton
        init(owner: ToolbarShareButton) { self.owner = owner }

        @objc func clicked(_ sender: NSButton) {
            guard owner.isEnabled else { return }
            let items = owner.itemsProvider()
            guard !items.isEmpty else { return }
            NSSharingServicePicker(items: items).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }
}

// MARK: - 原生搜索框（NSSearchField：自带放大镜/清除按钮/聚焦环）

/// 展开时自动聚焦；Esc 触发 onCollapse。宽度由 SwiftUI 外层 frame 动画控制
struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let expanded: Bool
    let onCollapse: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "搜索"
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.textChanged)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text {
            field.stringValue = text
        }
        if expanded != context.coordinator.wasExpanded {
            context.coordinator.wasExpanded = expanded
            if expanded {
                DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        var wasExpanded = false

        init(_ parent: NativeSearchField) { self.parent = parent }

        @objc func textChanged(_ sender: NSSearchField) {
            parent.text = sender.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCollapse()
                return true
            }
            return false
        }
    }
}
