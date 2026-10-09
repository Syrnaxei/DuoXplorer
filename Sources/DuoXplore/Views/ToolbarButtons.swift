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

// MARK: - FileMenuItem → SwiftUI Menu 内容（工具栏标签/••• 按钮，与分组方式同款 hover）

/// 递归转换：勾选态用 Label(checkmark)，子菜单嵌套 Menu，键位映射 keyboardShortcut
@MainActor
struct ToolbarMenuItems: View {
    let specs: [FileMenuItem]

    var body: some View {
        ForEach(Array(specs.enumerated()), id: \.offset) { _, spec in
            if spec.isDivider {
                Divider()
            } else if !spec.subItems.isEmpty {
                Menu(spec.title) {
                    ToolbarMenuItems(specs: spec.subItems)
                }
            } else {
                let button = Button {
                    spec.action()
                } label: {
                    if spec.state == .on {
                        Label(spec.title, systemImage: "checkmark")
                    } else {
                        Text(spec.title)
                    }
                }
                .disabled(!spec.enabled)
                if let shortcut = Self.shortcut(of: spec) {
                    button.keyboardShortcut(shortcut)
                } else {
                    button
                }
            }
        }
    }

    private static func shortcut(of spec: FileMenuItem) -> KeyboardShortcut? {
        guard let key = spec.keyEquivalent, let ch = key.first else { return nil }
        var mods = EventModifiers()
        let mask = spec.keyEquivalentModifierMask
        if mask.contains(.command) { mods.insert(.command) }
        if mask.contains(.option) { mods.insert(.option) }
        if mask.contains(.control) { mods.insert(.control) }
        if mask.contains(.shift) { mods.insert(.shift) }
        return KeyboardShortcut(KeyEquivalent(ch), modifiers: mods)
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
