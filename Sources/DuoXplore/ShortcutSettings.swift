import SwiftUI
import AppKit

// MARK: - 键位组合

struct KeyCombo: Equatable {
    var keyCode: UInt16
    /// 已去掉 numericPad/function/capsLock 等噪声位，只保留真实修饰键
    var modifiers: NSEvent.ModifierFlags
    var label: String
}

enum ShortcutAction: String, CaseIterable, Identifiable {
    case navigateUp, openItem, renameItem
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .navigateUp: return "返回上级目录"
        case .openItem: return "打开选中项"
        case .renameItem: return "重命名"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .navigateUp: return KeyCombo(keyCode: 51, modifiers: [], label: "⌫")
        case .openItem: return KeyCombo(keyCode: 36, modifiers: [], label: "↩")
        case .renameItem: return KeyCombo(keyCode: 120, modifiers: [], label: "F2")
        }
    }
}

// MARK: - 快捷键存储（UserDefaults 持久化）

@MainActor final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    @Published private(set) var combos: [ShortcutAction: KeyCombo]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        combos = ShortcutStore.loadAll(defaults)
    }

    func combo(for action: ShortcutAction) -> KeyCombo {
        combos[action] ?? action.defaultCombo
    }

    func set(_ combo: KeyCombo, for action: ShortcutAction) {
        combos[action] = combo
        let prefix = "shortcut.\(action.rawValue)"
        defaults.set(Int(combo.keyCode), forKey: "\(prefix).keyCode")
        defaults.set(UInt(combo.modifiers.rawValue), forKey: "\(prefix).modifiers")
        defaults.set(combo.label, forKey: "\(prefix).label")
    }

    func reset(_ action: ShortcutAction) {
        set(action.defaultCombo, for: action)
    }

    /// 事件是否命中组合键（修饰键按去噪后的独立位掩码精确比较）
    static func isMatch(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, _ combo: KeyCombo) -> Bool {
        keyCode == combo.keyCode
            && flags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock]) == combo.modifiers
    }

    private let defaults: UserDefaults

    private static func loadAll(_ defaults: UserDefaults) -> [ShortcutAction: KeyCombo] {
        Dictionary(uniqueKeysWithValues: ShortcutAction.allCases.map { ($0, load($0, defaults)) })
    }

    private static func load(_ action: ShortcutAction, _ defaults: UserDefaults) -> KeyCombo {
        let prefix = "shortcut.\(action.rawValue)"
        guard defaults.object(forKey: "\(prefix).keyCode") != nil else { return action.defaultCombo }
        return KeyCombo(
            keyCode: UInt16(clamping: defaults.integer(forKey: "\(prefix).keyCode")),
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(defaults.integer(forKey: "\(prefix).modifiers"))),
            label: defaults.string(forKey: "\(prefix).label") ?? "?"
        )
    }
}

// MARK: - 录制控件（点击后监听下一次按键，Esc 取消）

final class ShortcutRecorderButton: NSButton {
    var combo: KeyCombo { didSet { if !isRecording { refreshTitle() } } }
    /// 传入 nil 表示取消
    var onCommit: ((KeyCombo?) -> Void)?

    private var isRecording = false
    private var monitor: Any?

    init(combo: KeyCombo) {
        self.combo = combo
        super.init(frame: NSRect(x: 0, y: 0, width: 110, height: 24))
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        guard !isRecording else { return }
        isRecording = true
        title = "按下组合键…"
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.stopRecording()
            if event.keyCode == 53 { // Esc 取消
                self.refreshTitle()
                self.onCommit?(nil)
                return nil
            }
            let combo = KeyCombo(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags
                    .intersection(.deviceIndependentFlagsMask)
                    .subtracting([.numericPad, .function, .capsLock]),
                label: Self.displayLabel(for: event)
            )
            self.refreshTitle()
            self.onCommit?(combo)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        self.monitor = nil
        isRecording = false
    }

    /// 录制中途点击别处/关闭设置窗口时，必须摘掉 monitor，否则它会吞掉全应用所有按键
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isRecording {
            stopRecording()
            refreshTitle()
        }
    }

    private func refreshTitle() {
        title = Self.modifierSymbols(combo.modifiers) + combo.label
    }

    private static func modifierSymbols(_ flags: NSEvent.ModifierFlags) -> String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s
    }

    private static func displayLabel(for event: NSEvent) -> String {
        // ponytail: 特殊键只覆盖常用键码，其余回落到字符表示；需要更全时换 UCKeyTranslate
        let special: [UInt16: String] = [
            51: "⌫", 117: "⌦", 36: "↩", 49: "␣", 48: "⇥",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        if let label = special[event.keyCode] { return label }
        return event.charactersIgnoringModifiers?.uppercased().isEmpty == false
            ? event.charactersIgnoringModifiers!.uppercased()
            : "?"
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let combo: KeyCombo
    let onCommit: (KeyCombo?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(combo: combo)
        button.onCommit = onCommit
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.combo = combo
        button.onCommit = onCommit
    }
}

// MARK: - 设置界面（⌘, / 工具栏齿轮进入）

struct ShortcutSettingsView: View {
    @ObservedObject private var store = ShortcutStore.shared

    var body: some View {
        VStack(spacing: 16) {
            Form {
                ForEach(ShortcutAction.allCases) { action in
                    HStack {
                        Text(action.displayName)
                        Spacer()
                        ShortcutRecorder(combo: store.combo(for: action)) { newCombo in
                            guard let newCombo else { return }
                            // 与其他动作冲突时静默拒绝（保持原键位）
                            guard !ShortcutAction.allCases.contains(where: {
                                $0 != action && store.combo(for: $0) == newCombo
                            }) else { return }
                            store.set(newCombo, for: action)
                        }
                        Button("重置") { store.reset(action) }
                            .disabled(store.combo(for: action) == action.defaultCombo)
                    }
                }
            }
            Text("点击按键框后按下新的组合键；Esc 取消。")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 380)
    }
}
