import SwiftUI
import AppKit

/// 文件列表 + 列排序 + 右键菜单 + 键盘导航
struct FileListView: View {
    @Binding var files: [FileItem]
    @Binding var sortOption: SortOption
    @Binding var sortDirection: SortDirection
    @Binding var groupDimension: GroupDimension
    @Binding var selectedURLs: Set<URL>
    @Binding var clipboardURLs: [URL]
    @Binding var clipboardIsCut: Bool
    @Binding var currentURL: URL
    @Binding var showHiddenFiles: Bool
    @Binding var searchText: String
    let loadError: String?
    let isSearching: Bool
    let isTagFilterActive: Bool
    let onNavigate: (URL) -> Void
    let fsService: FileSystemService
    let onRefresh: () -> Void

    @State private var isCreatingFolder = false
    @State private var newFolderText = "新建文件夹"
    @FocusState private var newFolderFieldFocused: Bool
    /// 协调器重命名入口的引用容器（makeNSView 时注入）：键盘/菜单直接驱动 AppKit 编辑，
    /// 不经 SwiftUI 状态中转；用类实例而非 @State 闭包，避免在视图更新期间写状态
    @State private var renameHub = RenameHub()

    private var cutURLs: Set<URL> {
        clipboardIsCut ? Set(clipboardURLs) : []
    }

    var body: some View {
        VStack(spacing: 0) {
            // 列标题
            HeaderRow(
                sortOption: $sortOption,
                sortDirection: $sortDirection
            )

            Divider()

            // 新文件夹输入行：与表格首行同样的行高与缩进，视觉上就是列表的第一行
            if isCreatingFolder {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                        .resizable().scaledToFit()
                        .frame(width: 20, height: 20)
                        .foregroundColor(.accentColor)
                    TextField("新建文件夹名称", text: $newFolderText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($newFolderFieldFocused)
                        .onSubmit { commitCreateFolder() }
                        .onExitCommand { isCreatingFolder = false }
                        .onChange(of: newFolderFieldFocused) { focused in
                            // 点击别处使输入框失焦 = 取消新建；不复位会卡住 isCreatingFolder，令所有表格快捷键失效
                            if !focused, isCreatingFolder { isCreatingFolder = false }
                        }
                        .onAppear {
                            newFolderText = "新建文件夹"
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                newFolderFieldFocused = true
                            }
                        }
                    Spacer()
                }
                .padding(.leading, 8)
                .frame(height: 28)
                Divider()
            }

            // 文件列表（空文件夹也保持表格挂载：接收拖放、安装键盘监听、复用空白区右键菜单）
            FileListTableView(
                rows: displayRows,
                selectedURLs: $selectedURLs,
                cutURLs: cutURLs,
                currentURL: currentURL,
                fsService: fsService,
                onOpen: { file in
                    if file.isDirectory { onNavigate(file.url) }
                    else { fsService.openFile(file.url) }
                },
                onSelection: { urls in
                    selectedURLs = urls
                },
                onRenameEnd: { target, newName, canceled in
                    guard !canceled else { return }
                    commitRename(target: target, text: newName)
                },
                onRefresh: onRefresh,
                menuItems: menuItems,
                renameHub: renameHub
            )
            .onAppear {
                installKeyboardMonitor()
                registerMenuProvider?(menuItems)
            }
            .onDisappear { removeKeyboardMonitor() }
            .overlay {
                if files.isEmpty {
                    let (symbol, message): (String, String) = {
                        if let loadError { return ("exclamationmark.triangle", "无法读取此文件夹：\(loadError)") }
                        if isSearching { return ("magnifyingglass", "无搜索结果") }
                        return ("folder", "此文件夹为空")
                    }()
                    VStack(spacing: 10) {
                        Image(systemName: symbol)
                            .font(.system(size: 44, weight: .light))
                            .foregroundColor(.secondary.opacity(0.6))
                        Text(message)
                            .foregroundColor(.secondary)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - 排序与分组

    /// 搜索结果与标签模式不分组（Spotlight 结果属性不全），强制平铺
    private var effectiveDimension: GroupDimension {
        (isSearching || isTagFilterActive) ? .none : groupDimension
    }

    // ponytail: 每次 body 求值都全量重算分组+排序（O(n log n)）；万级条目若卡顿，
    // 再按 (files, effectiveDimension, sortOption, sortDirection) 做输入键缓存
    private var displayGroups: [FileGroup] {
        GroupingService.group(files, by: effectiveDimension, sortOption: sortOption, sortDirection: sortDirection)
    }

    private var displayRows: [FileListRow] {
        FileListRow.rows(from: displayGroups, grouped: effectiveDimension != .none)
    }

    // MARK: - 键盘事件监控

    @State private var keyboardMonitor: Any?

    private func handleKey(event: NSEvent) -> NSEvent? {
        guard let window = event.window else { return event }
        // 焦点在任何文本编辑器（重命名/搜索/新建文件夹/路径）时交给输入框处理，
        // 仅搜索框专属键位与会被菜单键位抢占的 ⌘C/⌘X/⌘V/⌘⌫ 等需这里接管（见 handleEditingKey）；
        // 方向键与扩展选中全部交给 NSTableView 原生处理，这里只劫持内置的表格动作
        if let editor = window.firstResponder as? NSTextView {
            return handleEditingKey(event: event, editor: editor, window: window)
        }
        // 表格动作只在主列表窗口生效：设置/关于等辅助窗口聚焦时（它们也是 mainWindow），
        // 不得在后台对主列表误触发重命名/新建文件夹等操作
        guard window === renameHub.listWindow?() else { return event }
        // 新建文件夹行刚出现、焦点尚未落进输入框的短暂窗口内不放行表格动作
        guard !isCreatingFolder else { return event }

        // 空文件夹也允许返回上级；根目录不能再向上（deletingLastPathComponent 会产生 /..）；
        // 标签模式下 currentURL 是进入标签前的残留目录，向上一层无意义
        if ShortcutAction.navigateUp.defaultCombo.matches(event) {
            guard !isTagFilterActive, currentURL.path != "/" else { return event }
            let previous = currentURL
            onNavigate(currentURL.deletingLastPathComponent())
            // Finder 行为：返回上级后选中刚离开的文件夹
            selectedURLs = [previous]
            return nil
        }

        if ShortcutAction.openItem.defaultCombo.matches(event) {
            // 无选中项时不吞按键，避免干扰侧边栏等视图的原生行为
            guard let url = selectedURLs.first,
                  let file = files.first(where: { $0.url == url }) else { return event }
            if file.isDirectory { onNavigate(file.url) }
            else { fsService.openFile(file.url) }
            return nil
        }
        if ShortcutAction.renameItem.defaultCombo.matches(event) {
            guard let url = selectedURLs.first, selectedURLs.count == 1 else { return event }
            renameHub.begin?(url)
            return nil
        }
        if ShortcutAction.newFolder.defaultCombo.matches(event) {
            startCreateFolder()
            return nil
        }
        return event
    }

    private func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handleKey)
    }

    private func removeKeyboardMonitor() {
        if let monitor = keyboardMonitor { NSEvent.removeMonitor(monitor) }
        keyboardMonitor = nil
    }

    /// 文本编辑器聚焦时的按键处理：
    /// 1. 搜索框专属：Esc 清空搜索并把焦点还给列表，↓ 跳进结果选中首项；
    /// 2. 任意编辑器（重命名/搜索/新建文件夹/路径）共同的问题：菜单栏 ⌘C/⌘X/⌘V 是带
    ///    显式 action 的文件操作，菜单键位匹配先于字段编辑器拿到按键（文本复制被抢成
    ///    复制文件），这里直接派发给编辑器并吞掉；⌘A/⌘⌫/⌘⌦ 同理——⌘⌫ 若不拦截会被
    ///    「移到废纸篓」菜单抢走，编辑到一半的文件直接进废纸篓；
    /// 其余按键（含 IME 组合中）全部交给输入框原生处理
    private func handleEditingKey(event: NSEvent, editor: NSTextView, window: NSWindow) -> NSEvent? {
        if editor.delegate is NSSearchField, !editor.hasMarkedText() {
            switch event.keyCode {
            case 53: // Esc
                searchText = ""
                makeFileTableFirstResponder(in: window)
                return nil
            case 125: // ↓
                if let first = files.first {
                    selectedURLs = [first.url]
                    makeFileTableFirstResponder(in: window)
                    return nil
                }
            default:
                break
            }
        }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        guard flags == .command, !editor.hasMarkedText() else { return event }
        switch event.charactersIgnoringModifiers {
        case "c": editor.copy(nil)
        case "x": editor.cut(nil)
        case "v": editor.paste(nil)
        case "a": editor.selectAll(nil)
        case "\u{7F}": editor.deleteToBeginningOfLine(nil)
        case "\u{F728}": editor.deleteToEndOfLine(nil)
        default: return event
        }
        return nil
    }

    private func makeFileTableFirstResponder(in window: NSWindow) {
        func find(_ view: NSView) -> NSTableView? {
            if view is NSTableView, view.accessibilityIdentifier() == "FileList" {
                return view as? NSTableView
            }
            for sub in view.subviews {
                if let table = find(sub) { return table }
            }
            return nil
        }
        if let contentView = window.contentView, let table = find(contentView) {
            window.makeFirstResponder(table)
        }
    }

    // MARK: - 重命名

    /// 提交重命名（编辑结束时由协调器回调）；失败弹窗报错并刷新，
    /// 刷新同时把输入框残留文本复位为磁盘真实名称
    private func commitRename(target: URL, text: String) {
        let newName = text.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty,
              fsService.isValidFileName(newName),
              newName != target.lastPathComponent else {
            if newName != target.lastPathComponent { onRefresh() }
            return
        }
        do {
            _ = try fsService.renameItem(at: target, to: newName)
        } catch {
            NSAlert(error: error as NSError).runModal()
        }
        onRefresh()
    }

    func startCreateFolder() {
        isCreatingFolder = true
        newFolderText = "新建文件夹"
    }

    private func commitCreateFolder() {
        guard !newFolderText.trimmingCharacters(in: .whitespaces).isEmpty,
              fsService.isValidFileName(newFolderText) else {
            isCreatingFolder = false
            return
        }
        do {
            _ = try fsService.createFolder(at: currentURL, name: newFolderText.trimmingCharacters(in: .whitespaces))
            onRefresh()
        } catch {
            print("创建文件夹失败: \(error)")
        }
        isCreatingFolder = false
    }

    // MARK: - 菜单（空白区域由 menuItems(for: nil) 提供，NSTableView menuProvider 构建）

    private func pasteFromClipboard() {
        guard !clipboardURLs.isEmpty else { return }
        let executed = fsService.pasteItems(clipboardURLs, to: currentURL, isCut: clipboardIsCut)
        if clipboardIsCut && executed {
            clipboardURLs = []
            clipboardIsCut = false
        }
        onRefresh()
    }

    /// 「分组方式」子菜单（空白区右键菜单与工具栏共用同一数据源）
    private var groupByMenuItem: FileMenuItem {
        FileMenuItem("分组方式", subItems: GroupDimension.allCases.map { dimension in
            FileMenuItem(dimension.rawValue, state: dimension == effectiveDimension ? .on : .off) {
                groupDimension = dimension
            }
        }) { }
    }

    /// 把菜单条目构建器登记给工具栏（••• 按钮与右键菜单同源）
    let registerMenuProvider: ((@escaping (FileItem?) -> [FileMenuItem]) -> Void)?

    /// 右键菜单条目（file 为 nil 表示空白区域），由 NSTableView 构建 NSMenu
    private func menuItems(for file: FileItem?) -> [FileMenuItem] {
        guard let file else {
            return [
                FileMenuItem("新建文件夹", keyEquivalent: "N", keyEquivalentModifierMask: [.command, .shift]) { startCreateFolder() },
                FileMenuItem("粘贴", enabled: !clipboardURLs.isEmpty) { pasteFromClipboard() },
                .divider,
                FileMenuItem("在终端中打开") { fsService.openInTerminal(currentURL) },
                FileMenuItem("在 Finder 中打开") { fsService.openInFinder(currentURL) },
                .divider,
                FileMenuItem(showHiddenFiles ? "不显示隐藏项目" : "显示隐藏项目") { showHiddenFiles.toggle() },
                groupByMenuItem,
            ]
        }
        var items: [FileMenuItem] = [
            FileMenuItem("打开") {
                if file.isDirectory { onNavigate(file.url) } else { fsService.openFile(file.url) }
            },
            .divider,
            FileMenuItem("复制") {
                clipboardURLs = selectedURLs.isEmpty ? [file.url] : Array(selectedURLs)
                clipboardIsCut = false
            },
            FileMenuItem("剪切") {
                clipboardURLs = selectedURLs.isEmpty ? [file.url] : Array(selectedURLs)
                clipboardIsCut = true
            },
            .divider,
            FileMenuItem("重命名") { renameHub.begin?(file.url) },
        ]
        if !file.isDirectory {
            items.append(FileMenuItem("在 Finder 中显示") { fsService.revealInFinder(file.url) })
        }
        items += [
            .divider,
            FileMenuItem("复制路径") { fsService.copyPath(file.url) },
            .divider,
            FileMenuItem("移到废纸篓", keyEquivalent: String(UnicodeScalar(0x232B)!), keyEquivalentModifierMask: .command) {
                let urls = selectedURLs.isEmpty ? [file.url] : Array(selectedURLs)
                fsService.moveToTrash(urls)
                onRefresh()
            },
        ]
        return items
    }
}

// MARK: - 菜单条目数据（title 为空表示分隔线）

@MainActor struct FileMenuItem {
    let title: String
    let keyEquivalent: String?
    let keyEquivalentModifierMask: NSEvent.ModifierFlags
    let enabled: Bool
    let state: NSControl.StateValue
    let color: NSColor?
    let subItems: [FileMenuItem]
    let action: () -> Void

    init(_ title: String, keyEquivalent: String? = nil, keyEquivalentModifierMask: NSEvent.ModifierFlags = [], enabled: Bool = true, state: NSControl.StateValue = .off, color: NSColor? = nil, subItems: [FileMenuItem] = [], action: @escaping () -> Void) {
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.keyEquivalentModifierMask = keyEquivalentModifierMask
        self.enabled = enabled
        self.state = state
        self.color = color
        self.subItems = subItems
        self.action = action
    }

    static let divider = FileMenuItem("", enabled: true, action: {})
    var isDivider: Bool { title.isEmpty }
}

// MARK: - 原生文件列表（NSTableView：原生选中/多选/双击/行内重命名/右键菜单）

/// 协调器注入的引用容器：makeNSView（视图更新期间）只写实例属性，
/// 不触碰 SwiftUI 状态机，父视图的键盘/菜单闭包经此直调协调器
@MainActor final class RenameHub {
    var begin: ((URL) -> Void)?
    /// 主列表所在窗口：表格快捷键只在它聚焦时生效，辅助窗口（设置/关于）聚焦时放行
    var listWindow: (() -> NSWindow?)?
}

struct FileListTableView: NSViewRepresentable {
    let rows: [FileListRow]
    @Binding var selectedURLs: Set<URL>
    let cutURLs: Set<URL>
    let currentURL: URL
    let fsService: FileSystemService
    let onOpen: (FileItem) -> Void
    let onSelection: (Set<URL>) -> Void
    let onRenameEnd: (URL, String, Bool) -> Void
    let onRefresh: () -> Void
    let menuItems: (FileItem?) -> [FileMenuItem]
    /// 协调器在 makeNSView 时把 beginRename 写入该容器，父视图的键盘/菜单直接调用
    let renameHub: RenameHub

    private static let nameCellID = NSUserInterfaceItemIdentifier("FileListNameCell")
    private static let textCellID = NSUserInterfaceItemIdentifier("FileListTextCell")
    private static let headerCellID = NSUserInterfaceItemIdentifier("FileListHeaderCell")

    func makeCoordinator() -> Coordinator {
        Coordinator(
            rows: rows,
            cutURLs: cutURLs,
            currentURL: currentURL,
            fsService: fsService,
            onOpen: onOpen,
            onSelection: onSelection,
            onRenameEnd: onRenameEnd,
            onRefresh: onRefresh,
            menuItems: menuItems
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTable()
        table.headerView = nil
        table.style = .fullWidth
        table.rowHeight = 28
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.registerForDraggedTypes([.fileURL])
        table.setAccessibilityIdentifier("FileList")

        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        name.width = 200
        name.resizingMask = .autoresizingMask
        let date = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        date.width = 155
        date.resizingMask = []
        let kind = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
        kind.width = 130
        kind.resizingMask = []
        let size = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        size.width = 100
        size.resizingMask = []
        table.addTableColumn(name)
        table.addTableColumn(date)
        table.addTableColumn(kind)
        table.addTableColumn(size)

        let coordinator = context.coordinator
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator
        table.target = coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        table.menuProvider = { [weak coordinator] row, _ in
            coordinator?.menu(forRow: row)
        }
        table.rowIsSelectable = { [weak coordinator] row in
            coordinator?.file(at: row) != nil
        }
        renameHub.begin = { [weak coordinator] url in
            coordinator?.beginRename(url)
        }
        renameHub.listWindow = { [weak coordinator] in
            coordinator?.table?.window
        }
        table.reloadData()

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onOpen = onOpen
        coordinator.onSelection = onSelection
        coordinator.onRenameEnd = onRenameEnd
        coordinator.onRefresh = onRefresh
        coordinator.menuItems = menuItems
        coordinator.currentURL = currentURL
        coordinator.fsService = fsService

        if rows != coordinator.rows {
            coordinator.rows = rows
            // 编辑中不重载：reloadData 会打断正在进行的重命名（半截文本被提交）；
            // rows 已更新为最新，编辑收尾时在 controlTextDidEndEditing 补载
            if coordinator.isEditingRename {
                coordinator.pendingReload = true
            } else {
                coordinator.reloadTable()
            }
        }

        if cutURLs != coordinator.cutURLs {
            coordinator.cutURLs = cutURLs
            coordinator.refreshCutAppearance()
        }

        coordinator.syncSelection(to: selectedURLs)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSControlTextEditingDelegate {
        var rows: [FileListRow]
        var cutURLs: Set<URL>
        var currentURL: URL
        var fsService: FileSystemService
        var onOpen: (FileItem) -> Void
        var onSelection: (Set<URL>) -> Void
        var onRenameEnd: (URL, String, Bool) -> Void
        var onRefresh: () -> Void
        var menuItems: (FileItem?) -> [FileMenuItem]
        weak var table: NSTableView?
        /// 当前编辑中的重命名目标，nil = 无会话。
        /// 重命名会话完全由本协调器持有并同步驱动，SwiftUI 侧不保存任何中间状态，
        /// 编辑收尾（controlTextDidEndEditing）时把捕获的目标回传给提交逻辑，
        /// 不依赖可能被后续操作覆盖的共享状态
        var editingURL: URL?
        /// 编辑期间被推迟的列表刷新，收尾后补载
        var pendingReload = false
        /// 兜底直编路径（editColumn 被拒时直接编辑 NSTextField）的当前目标
        var fallbackTextField: NSTextField?
        var isSyncingSelection = false

        var isEditingRename: Bool { editingURL != nil }

        init(rows: [FileListRow], cutURLs: Set<URL>, currentURL: URL, fsService: FileSystemService,
             onOpen: @escaping (FileItem) -> Void, onSelection: @escaping (Set<URL>) -> Void,
             onRenameEnd: @escaping (URL, String, Bool) -> Void, onRefresh: @escaping () -> Void,
             menuItems: @escaping (FileItem?) -> [FileMenuItem]) {
            self.rows = rows
            self.cutURLs = cutURLs
            self.currentURL = currentURL
            self.fsService = fsService
            self.onOpen = onOpen
            self.onSelection = onSelection
            self.onRenameEnd = onRenameEnd
            self.onRefresh = onRefresh
            self.menuItems = menuItems
        }

        // MARK: 数据源

        func file(at row: Int) -> FileItem? {
            row >= 0 && row < rows.count ? rows[row].file : nil
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            // 分组标题行不可选中
            row < rows.count && rows[row].file != nil
        }

        /// cmd+A / 范围选择等批量选中也要过滤标题行（shouldSelectRow 不覆盖 selectAll）
        func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
            IndexSet(proposedSelectionIndexes.filter { $0 < rows.count && rows[$0].file != nil })
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < rows.count else { return nil }

            if case .header(let title, let count) = rows[row] {
                let cell = tableView.makeView(withIdentifier: FileListTableView.headerCellID, owner: nil)
                    as? NSTableCellView ?? Self.makeHeaderCell()
                cell.textField?.stringValue = "\(title) · \(count) 项"
                return cell
            }
            guard let file = rows[row].file else { return nil }

            switch tableColumn?.identifier.rawValue {
            case "name":
                let cell = tableView.makeView(withIdentifier: FileListTableView.nameCellID, owner: nil)
                    as? NSTableCellView ?? Self.makeNameCell()
                cell.textField?.stringValue = file.name
                cell.imageView?.image = icon(for: file)
                cell.textField?.isEditable = false
                cell.alphaValue = cutURLs.contains(file.url) ? 0.45 : 1
                return cell
            case "date":
                let cell = tableView.makeView(withIdentifier: FileListTableView.textCellID, owner: nil)
                    as? NSTableCellView ?? Self.makeTextCell()
                cell.textField?.stringValue = file.formattedDate
                return cell
            case "kind":
                let cell = tableView.makeView(withIdentifier: FileListTableView.textCellID, owner: nil)
                    as? NSTableCellView ?? Self.makeTextCell()
                cell.textField?.stringValue = file.fileTypeDisplay
                return cell
            case "size":
                let cell = tableView.makeView(withIdentifier: FileListTableView.textCellID, owner: nil)
                    as? NSTableCellView ?? Self.makeTextCell()
                cell.textField?.stringValue = file.isDirectory ? "--" : file.formattedSize
                cell.textField?.alignment = .right
                return cell
            default:
                return nil
            }
        }

        private func icon(for file: FileItem) -> NSImage {
            let image = NSWorkspace.shared.icon(forFile: file.url.path)
            image.size = NSSize(width: 20, height: 20)
            return image
        }

        private static func makeNameCell() -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = nameCellID
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = .systemFont(ofSize: 13)
            textField.lineBreakMode = .byTruncatingTail
            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.imageView = imageView
            cell.textField = textField
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 20),
                imageView.heightAnchor.constraint(equalToConstant: 20),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            ])
            return cell
        }

        private static func makeHeaderCell() -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = headerCellID
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = .systemFont(ofSize: 11, weight: .semibold)
            textField.textColor = .secondaryLabelColor
            textField.lineBreakMode = .byTruncatingTail
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            ])
            return cell
        }

        private static func makeTextCell() -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = textCellID
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.font = .systemFont(ofSize: 12)
            textField.textColor = .secondaryLabelColor
            textField.lineBreakMode = .byTruncatingTail
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 12),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            ])
            return cell
        }

        // MARK: 选中同步

        private var currentSelection: Set<URL> {
            guard let table else { return [] }
            return Set(table.selectedRowIndexes.compactMap { file(at: $0)?.url })
        }

        func syncSelection(to urls: Set<URL>) {
            guard let table, currentSelection != urls else { return }
            let indexes = IndexSet(rows.indices.filter { offset in
                rows[offset].file.map { urls.contains($0.url) } == true
            })
            isSyncingSelection = true
            table.selectRowIndexes(indexes, byExtendingSelection: false)
            isSyncingSelection = false
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection else { return }
            onSelection(currentSelection)
        }

        // MARK: 双击打开

        @objc func doubleClicked(_ sender: NSTableView) {
            guard let file = file(at: sender.clickedRow) else { return }
            onOpen(file)
        }

        // MARK: 剪切态半透明

        func refreshCutAppearance() {
            guard let table else { return }
            for row in 0..<min(table.numberOfRows, rows.count) {
                guard let file = rows[row].file else { continue }
                let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView
                cell?.alphaValue = cutURLs.contains(file.url) ? 0.45 : 1
            }
        }

        // MARK: 行内重命名（原生字段编辑器，会话由协调器全权持有）

        /// 开始重命名：所有触发（键盘 Return / 右键菜单）统一入口。
        /// 菜单项 action 在菜单跟踪收尾期间同步执行，此时直接 editColumn 会被
        /// 残余鼠标事件/菜单拆卸打断；延后一轮主队列（跟踪结束、事件排空）再开编辑
        func beginRename(_ url: URL) {
            DispatchQueue.main.async { [weak self] in
                self?.beginEditSession(url)
            }
        }

        private func beginEditSession(_ url: URL) {
            guard let table else { return }
            if table.currentEditor() != nil || fallbackTextField != nil {
                if table.window?.firstResponder === table {
                    // 焦点已在表格却仍有会话挂着：非常态，放弃重试避免死循环
                    return
                }
                // 上一轮编辑还开着：先收尾（级联用各自捕获的目标提交/取消，互不干扰），
                // 再延后一轮重试，保证收尾触发的刷新先完成
                guard table.window?.makeFirstResponder(table) == true else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.beginEditSession(url)
                }
                return
            }
            guard rows.contains(where: { $0.file?.url == url }) else { return }
            // 编辑器要收到按键，窗口必须是 key：从后台/菜单收尾等边角触发时先把窗口拉正
            if let window = table.window, window !== NSApp.keyWindow {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            }
            // editColumn 的前提是表格自己先持有焦点：焦点在游离编辑器/侧边栏等其他 responder
            // 上时开编辑，会得到「输入框可见却收不到按键」的坏状态，先归位
            if table.window?.firstResponder !== table {
                table.window?.makeFirstResponder(table)
            }
            if let row = rows.firstIndex(where: { $0.file?.url == url }) {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                table.scrollRowToVisible(row)
            }
            // 关键时序：editColumn 不能与 selectRowIndexes 同一轮执行——表格要先完成
            // 选择的重绘，否则 editColumn 静默失败（实证：重构把两步并到同一轮后编辑器
            // 再没真正开起来；旧版可用正是靠 updateNSView 与 editColumn 之间隔了一轮主队列）
            DispatchQueue.main.async { [weak self, weak table] in
                self?.openEditor(for: url, table: table)
            }
        }

        private func openEditor(for url: URL, table: NSTableView?) {
            guard let table else { return }
            // 行号重算：延后期间可能发生 reloadData，coordinator.rows 已吸收最新内容
            guard let row = rows.firstIndex(where: { $0.file?.url == url }) else { return }
            guard let textField = (table.rowView(atRow: row, makeIfNecessary: true)?
                .view(atColumn: 0) as? NSTableCellView)?.textField else { return }
            // isEditable 在 reloadData 复用 cell 时会被 viewFor 重置，必须紧跟 editColumn 设置
            textField.isEditable = true
            editingURL = url
            table.editColumn(0, row: row, with: nil, select: true)
            if table.currentEditor() == nil {
                // 兜底：绕开表格编辑机制，直接把 NSTextField 设为 first responder——
                // 可编辑控件获得焦点即进入原生字段编辑（等效 Tab 聚焦输入框）；
                // 此路径不经表格发起，收尾靠通知而不是表格委托
                let took = table.window?.makeFirstResponder(textField) == true
                if took, textField.currentEditor() != nil {
                    fallbackTextField = textField
                    NotificationCenter.default.addObserver(
                        self, selector: #selector(fallbackEditEnded(_:)),
                        name: NSControl.textDidEndEditingNotification, object: textField)
                    return
                }
                editingURL = nil
                textField.isEditable = false
                table.window?.makeFirstResponder(table)
                return
            }
            let editor = table.currentEditor()
            if let editor, table.window?.firstResponder !== editor {
                // 实证过 editColumn 可留下「编辑器在、焦点却不在编辑器上」的坏状态（输入框
                // 可见却收不到任何按键）——焦点必须显式落在编辑器上
                table.window?.makeFirstResponder(editor)
                if table.currentEditor() == nil {
                    editingURL = nil
                    textField.isEditable = false
                }
            }
        }

        /// 兜底直编路径的收尾（ textField 直接编辑，不经表格委托）
        @objc private func fallbackEditEnded(_ note: Notification) {
            guard let textField = note.object as? NSTextField, textField === fallbackTextField else { return }
            NotificationCenter.default.removeObserver(
                self, name: NSControl.textDidEndEditingNotification, object: textField)
            fallbackTextField = nil
            finishEditing(textField, userInfo: note.userInfo)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            finishEditing(textField, userInfo: obj.userInfo)
        }

        private func finishEditing(_ textField: NSTextField, userInfo: [AnyHashable: Any]?) {
            textField.isEditable = false
            let target = editingURL
            editingURL = nil
            let movement = (userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
            if let target {
                onRenameEnd(target, textField.stringValue, movement == .cancel)
            }
            // 编辑期间推迟的列表刷新在此补上（rows 已是最新，加载即可见）
            if pendingReload {
                pendingReload = false
                reloadTable()
            }
        }

        func reloadTable() {
            guard let table else { return }
            table.reloadData()
            // 空文件夹时隐藏行分隔线，占位符更干净
            table.gridStyleMask = rows.isEmpty ? [] : .solidHorizontalGridLineMask
        }

        // MARK: 拖放

        // 拖出行：为行提供 URL writer 以发起拖拽；数据由 FileTable.beginDraggingSession 立即写入粘贴板
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            file(at: row).map { $0.url as NSURL }
        }

        private func draggedFileURLs(from info: NSDraggingInfo) -> [URL]? {
            info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL]
        }

        /// 拖放目标：目录行上悬停 = 拖入该文件夹，其余 = 拖入当前目录；
        /// 过滤无效项后为空（拖回原文件夹、拖进自己的子目录）时返回 nil = 无操作
        private func dropTarget(_ info: NSDraggingInfo, row: Int, operation: NSTableView.DropOperation) -> (urls: [URL], destination: URL, folderRow: Int?)? {
            guard let urls = draggedFileURLs(from: info), !urls.isEmpty else { return nil }
            let destination: URL
            let folderRow: Int?
            if operation == .on, let hovered = file(at: row),
               hovered.isDirectory, !urls.contains(hovered.url) {
                destination = hovered.url
                folderRow = row
            } else {
                destination = currentURL
                folderRow = nil
            }
            let movable = movableURLs(urls, into: destination)
            guard !movable.isEmpty else { return nil }
            return (movable, destination, folderRow)
        }

        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard let target = dropTarget(info, row: row, operation: operation) else { return [] }
            if let folderRow = target.folderRow {
                tableView.setDropRow(folderRow, dropOperation: .on)
            } else {
                tableView.setDropRow(-1, dropOperation: .on)
            }
            // 应用内拖动默认移动（⌥ 复制），外部（Finder）默认复制（⌥ 移动）
            let wanted: NSDragOperation = (info.draggingSource != nil) != NSEvent.modifierFlags.contains(.option) ? .move : .copy
            let result = wanted.intersection(info.draggingSourceOperationMask)
            return result.isEmpty ? info.draggingSourceOperationMask.intersection(.copy) : result
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard let target = dropTarget(info, row: row, operation: dropOperation) else { return false }
            let isMove = (info.draggingSource != nil) != NSEvent.modifierFlags.contains(.option)
            fsService.pasteItems(target.urls, to: target.destination, isCut: isMove)
            onRefresh()
            return true
        }

        // MARK: 右键菜单

        func menu(forRow row: Int) -> NSMenu? {
            // 标题行右键 = 空白区菜单
            makeNativeMenu(from: menuItems(file(at: row)))
        }
    }

    /// 右键未选中文件行时先选中该行（Finder 行为）；分组标题行不选中
    final class FileTable: NSTableView {
        var menuProvider: ((Int, NSEvent) -> NSMenu?)?
        var rowIsSelectable: ((Int) -> Bool)?

        override func menu(for event: NSEvent) -> NSMenu? {
            let point = convert(event.locationInWindow, from: nil)
            let row = row(at: point)
            if row >= 0, rowIsSelectable?(row) == true, !selectedRowIndexes.contains(row) {
                selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            return menuProvider?(row, event)
        }

        // NSTableView 内部发起的拖拽用懒加载 pasteboard writer，跨应用目标读不到数据；
        // 会话建立后立即把行 URL 实际写入会话粘贴板，并把会话来源换成表格自己以提供操作掩码
        override func beginDraggingSession(with items: [NSDraggingItem], event: NSEvent, source: NSDraggingSource) -> NSDraggingSession {
            let session = super.beginDraggingSession(with: items, event: event, source: self)
            let urls = items.compactMap { $0.item as? NSURL } as [URL]
            if !urls.isEmpty {
                session.draggingPasteboard.clearContents()
                session.draggingPasteboard.writeObjects(urls as [NSURL])
            }
            return session
        }

        override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            [.copy, .move]
        }
    }
}

/// 过滤无效拖放项：已在目标文件夹内的（拖回原文件夹 = 无操作）、
/// 目标文件夹在拖拽项内部的（会把文件夹拖进自己的子目录）
func movableURLs(_ urls: [URL], into destination: URL) -> [URL] {
    let destinationPath = destination.standardizedFileURL.path
    return urls.filter {
        $0.deletingLastPathComponent().standardizedFileURL.path != destinationPath
            && !destinationPath.hasPrefix($0.standardizedFileURL.path + "/")
    }
}

// MARK: - 列标题行

struct HeaderRow: View {
    @Binding var sortOption: SortOption
    @Binding var sortDirection: SortDirection

    var body: some View {
        HStack(spacing: 0) {
            HeaderCell(title: "名称", option: .name, sortOption: $sortOption, sortDirection: $sortDirection)
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            Divider().frame(height: 20)
            HeaderCell(title: "修改日期", option: .date, sortOption: $sortOption, sortDirection: $sortDirection)
                .frame(width: 155)
            Divider().frame(height: 20)
            HeaderCell(title: "类型", option: .kind, sortOption: $sortOption, sortDirection: $sortDirection)
                .frame(width: 130)
            Divider().frame(height: 20)
            HeaderCell(title: "大小", option: .size, sortOption: $sortOption, sortDirection: $sortDirection)
                .frame(width: 100)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct HeaderCell: View {
    let title: String
    let option: SortOption
    @Binding var sortOption: SortOption
    @Binding var sortDirection: SortDirection

    var body: some View {
        Button(action: {
            if sortOption == option { sortDirection.toggle() }
            else { sortOption = option; sortDirection = .ascending }
        }) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 12, weight: .bold)).foregroundColor(.primary)
                if sortOption == option {
                    Text(sortDirection.symbol).font(.system(size: 10)).foregroundColor(.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
