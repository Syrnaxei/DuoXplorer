import SwiftUI
import AppKit

/// 面包屑地址栏（仿 Windows 资源管理器）
/// - 各级路径名可点击跳转到对应文件夹
/// - 点击空白处切换为可编辑路径（Enter 导航、~ 展开、Esc 取消）
/// 交互层用 AppKit 实现：SwiftUI 的 Button/onTapGesture 在横向滚动区内不触发（实测）
struct BreadcrumbBar: View {
    @Binding var currentURL: URL
    let onNavigate: (URL) -> Void

    @State private var isEditing = false
    @State private var editPath = ""
    @FocusState private var isFocused: Bool

    /// 纯字符串切分，避免 body 求值期间的 CFURL 调用（曾导致深层路径下主线程卡顿）
    private var pathComponents: [(name: String, path: String)] {
        var components: [(String, String)] = []
        var prefix = ""
        for part in currentURL.path.split(separator: "/") {
            prefix += "/" + part
            components.append((String(part), prefix))
        }
        components.insert(("Macintosh HD", "/"), at: 0)
        return components
    }

    var body: some View {
        ZStack {
            if isEditing {
                editField
            } else {
                let crumbs = pathComponents  // 每次 body 只计算一次
                BreadcrumbBarView(
                    pathComponents: crumbs,
                    onNavigate: onNavigate,
                    onBlankClick: { startEdit() }
                )
            }
        }
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: isFocused) { _, focused in
            // 失焦 = 提交跳转并回到面包屑态（Esc 走 onExitCommand 取消，不触发提交）
            guard !focused, isEditing else { return }
            commitOnBlur()
        }
    }

    // MARK: - 编辑模式

    private var editField: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            TextField("输入路径", text: $editPath)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onSubmit { commitEdit() }
                .onExitCommand { cancelEdit() }
                .onAppear {
                    editPath = currentURL.path
                    isFocused = true
                    // 自动全选文本，方便复制
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        guard isFocused, isEditing else { return }
                        NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                    }
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// 失焦提交：路径有效则跳转，无效（或为空）则直接退出编辑态
    private func commitOnBlur() {
        let raw = editPath.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { cancelEdit(); return }
        var path = (raw as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = currentURL.path + "/" + path
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            onNavigate(isDir.boolValue ? url : url.deletingLastPathComponent())
        }
        cancelEdit()
    }

    private func commitEdit() {
        let raw = editPath.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { cancelEdit(); return }
        // 支持 ~ 展开；相对路径相对当前目录解析；标准化掉 .. 等
        var path = (raw as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = currentURL.path + "/" + path
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            // 路径不存在：保持编辑态，用户可修正或 Esc 取消
            return
        }
        // 输入到具体文件时进入其所在目录
        onNavigate(isDir.boolValue ? url : url.deletingLastPathComponent())
        cancelEdit()
    }

    private func cancelEdit() {
        isEditing = false
        editPath = ""
    }

    private func startEdit() {
        editPath = currentURL.path
        isEditing = true
    }
}

// MARK: - AppKit 面包屑（路径段 = NSButton，空白区 = 容器 mouseDown）

private struct BreadcrumbBarView: NSViewRepresentable {
    let pathComponents: [(name: String, path: String)]
    let onNavigate: (URL) -> Void
    let onBlankClick: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let container = BreadcrumbContainer()
        container.onBlankClick = { context.coordinator.onBlankClick?() }

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        let scrollView = NSScrollView()
        scrollView.documentView = container
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor),
        ])
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onNavigate = onNavigate
        context.coordinator.onBlankClick = onBlankClick
        rebuildCrumbs(in: scrollView, coordinator: context.coordinator)
    }

    private func rebuildCrumbs(in scrollView: NSScrollView, coordinator: Coordinator) {
        guard let container = scrollView.documentView as? BreadcrumbContainer,
              let stack = container.subviews.compactMap({ $0 as? NSStackView }).first else { return }

        let key = pathComponents.map { $0.path }.joined(separator: "|")
        guard key != coordinator.lastPathKey else { return }
        coordinator.lastPathKey = key

        stack.arrangedSubviews.forEach { stack.removeView($0) }

        for (index, component) in pathComponents.enumerated() {
            if index > 0 {
                let chevron = NSTextField(labelWithString: "›")
                chevron.font = .systemFont(ofSize: 11)
                chevron.textColor = .secondaryLabelColor
                stack.addView(chevron, in: .leading)
            }

            let button = NSButton(
                title: component.name,
                target: coordinator,
                action: #selector(Coordinator.crumbClicked(_:))
            )
            button.isBordered = false
            button.font = .systemFont(ofSize: 13)
            button.identifier = NSUserInterfaceItemIdentifier(component.path)
            button.toolTip = component.path
            if index == pathComponents.count - 1 {
                button.wantsLayer = true
                button.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
                button.layer?.cornerRadius = 4
            }
            stack.addView(button, in: .leading)
        }
    }

    @MainActor final class Coordinator: NSObject {
        var onNavigate: ((URL) -> Void)?
        var onBlankClick: (() -> Void)?
        var lastPathKey = ""

        @objc func crumbClicked(_ sender: NSButton) {
            guard let path = sender.identifier?.rawValue else { return }
            onNavigate?(URL(fileURLWithPath: path))
        }
    }

    /// 点击非按钮区域（空白处）触发编辑模式
    final class BreadcrumbContainer: NSView {
        var onBlankClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            onBlankClick?()
        }

        override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
    }
}
