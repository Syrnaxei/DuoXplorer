import SwiftUI
import AppKit

// MARK: - 键位组合

struct KeyCombo: Equatable {
    var keyCode: UInt16
    /// 已去掉 numericPad/function/capsLock 等噪声位，只保留真实修饰键
    var modifiers: NSEvent.ModifierFlags
    var label: String

    /// 设置界面展示用（如 ⌘↑）
    var display: String { Self.modifierSymbols(modifiers) + label }

    static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    /// 事件是否命中组合键（修饰键按去噪后的独立位掩码精确比较）
    func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        self.keyCode == keyCode
            && flags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock]) == modifiers
    }

    func matches(_ event: NSEvent) -> Bool {
        matches(keyCode: event.keyCode, flags: event.modifierFlags)
    }
}

// MARK: - 表格键盘动作（Finder 惯用键位，暂不支持自定义）

enum ShortcutAction: String, CaseIterable {
    case navigateUp, openItem, renameItem

    var displayName: String {
        switch self {
        case .navigateUp: return "返回上级目录"
        case .openItem: return "打开选中项"
        case .renameItem: return "重命名"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .navigateUp: return KeyCombo(keyCode: 126, modifiers: [.command], label: "↑")  // ⌘↑
        case .openItem: return KeyCombo(keyCode: 36, modifiers: [.command], label: "↩")     // ⌘↩
        case .renameItem: return KeyCombo(keyCode: 36, modifiers: [], label: "↩")           // Return
        }
    }
}

// MARK: - 设置界面（只读列出全部快捷键；键位与 DuoXploreApp 菜单定义需人工保持同步）

struct ShortcutSettingsView: View {
    /// (名称, 键位)；表格动作的键位取自 ShortcutAction，其余为菜单固定键位
    private let groups: [(name: String, items: [(name: String, keys: String)])] = [
        ("导航与查看", [
            ("返回上级目录", ShortcutAction.navigateUp.defaultCombo.display),
            ("打开选中项", ShortcutAction.openItem.defaultCombo.display),
            ("搜索", "⌘F"),
            ("显示/隐藏隐藏项目", "⇧⌘."),
            ("全选", "⌘A"),
        ]),
        ("文件操作", [
            ("复制", "⌘C"),
            ("剪切", "⌘X"),
            ("粘贴", "⌘V"),
            ("重命名", ShortcutAction.renameItem.defaultCombo.display),
            ("移到废纸篓", "⌘⌫"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups, id: \.name) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.name)
                        .font(.headline)
                    ForEach(group.items, id: \.name) { item in
                        HStack {
                            Text(item.name)
                            Spacer()
                            KeyCap(item.keys)
                        }
                    }
                }
            }
            Text("快捷键与 Finder 保持一致，暂不支持自定义。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 320)
    }
}

/// 键帽样式的小标签
private struct KeyCap: View {
    let keys: String

    init(_ keys: String) { self.keys = keys }

    var body: some View {
        Text(keys)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(nsColor: .quaternaryLabelColor)))
    }
}
