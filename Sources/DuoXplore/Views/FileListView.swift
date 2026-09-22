import SwiftUI
import AppKit

/// 文件列表 + 列排序 + 右键菜单 + 键盘导航
struct FileListView: View {
    @Binding var files: [FileItem]
    @Binding var sortOption: SortOption
    @Binding var sortDirection: SortDirection
    @Binding var selectedURLs: Set<URL>
    @Binding var clipboardURLs: [URL]
    @Binding var clipboardIsCut: Bool
    @Binding var currentURL: URL
    @Binding var showHiddenFiles: Bool
    let loadError: String?
    let isSearching: Bool
    let onNavigate: (URL) -> Void
    let fsService: FileSystemService
    @Binding var isRenaming: Bool
    @Binding var renameTarget: URL?
    @Binding var renameText: String
    let onRefresh: () -> Void

    @State private var isCreatingFolder = false
    @State private var newFolderText = "新建文件夹"
    @FocusState private var newFolderFieldFocused: Bool

    private var cutURLs: Set<URL> {
        clipboardIsCut ? Set(clipboardURLs) : []
    }

    var body: some View {
        VStack(spacing: 0) {
            // 新文件夹输入行（全局）
            if isCreatingFolder {
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                            .resizable().frame(width: 20, height: 16)
                            .foregroundColor(.accentColor)
                        TextField("新建文件夹名称", text: $newFolderText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .focused($newFolderFieldFocused)
                            .onSubmit { commitCreateFolder() }
                            .onExitCommand { isCreatingFolder = false }
                            .onAppear {
                                newFolderText = "新建文件夹"
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    newFolderFieldFocused = true
                                }
                            }
                    }
                    .frame(minWidth: 200, alignment: .leading)
                    .padding(.leading, 36)
                    Spacer()
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(Color.accentColor.opacity(0.08))
                Divider()
            }

            // 列标题
            HeaderRow(
                sortOption: $sortOption,
                sortDirection: $sortDirection
            )

            Divider()

            // 文件列表（空文件夹也保持表格挂载：接收拖放、安装键盘监听、复用空白区右键菜单）
            FileListTableView(
                files: sortedFiles,
                selectedURLs: $selectedURLs,
                cutURLs: cutURLs,
                renameTarget: renameTarget,
                currentURL: currentURL,
                fsService: fsService,
                onOpen: { file in
                    if file.isDirectory { onNavigate(file.url) }
                    else { fsService.openFile(file.url) }
                },
                onSelection: { urls in
                    selectedURLs = urls
                },
                onRenameEnd: { newName, canceled in
                    if canceled { cancelRename() } else {
                        renameText = newName
                        commitRename()
                    }
                },
                onRefresh: onRefresh,
                menuItems: menuItems
            )
            .onAppear { installKeyboardMonitor() }
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

    // MARK: - 排序

    private var sortedFiles: [FileItem] {
        let dirs = files.filter(\.isDirectory)
        let nonDirs = files.filter { !$0.isDirectory }
        let sortedDirs: [FileItem]
        let sortedFiles: [FileItem]

        switch sortOption {
        case .name:
            sortedDirs = dirs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            sortedFiles = nonDirs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            sortedDirs = dirs
            sortedFiles = nonDirs.sorted { ($0.size ?? 0) < ($1.size ?? 0) }
        case .kind:
            sortedDirs = dirs.sorted { $0.fileExtension.localizedStandardCompare($1.fileExtension) == .orderedAscending }
            sortedFiles = nonDirs.sorted { $0.fileExtension.localizedStandardCompare($1.fileExtension) == .orderedAscending }
        case .date:
            sortedDirs = dirs.sorted { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
            sortedFiles = nonDirs.sorted { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
        }

        let result = sortDirection == .ascending
            ? (sortedDirs + sortedFiles)
            : (Array(sortedDirs.reversed()) + Array(sortedFiles.reversed()))
        return result
    }

    // MARK: - 键盘事件监控

    @State private var keyboardInstalled = false

    private func handleKey(event: NSEvent) -> NSEvent? {
        // 焦点在任何文本输入框（路径编辑/搜索/重命名/新建文件夹）时，按键交给输入框原生处理；
        // 方向键与扩展选中全部交给 NSTableView 原生处理，这里只劫持退格/回车/F2
        if NSApp.keyWindow?.firstResponder is NSTextView { return event }
        guard !isRenaming, !isCreatingFolder,
              let window = NSApp.keyWindow,
              event.window == window else { return event }

        // 空文件夹也允许退格返回上级；根目录不能再向上（deletingLastPathComponent 会产生 /..）
        if event.keyCode == 51 {
            guard currentURL.path != "/" else { return nil }
            onNavigate(currentURL.deletingLastPathComponent())
            return nil
        }

        switch event.keyCode {
        case 36: // 回车打开
            if let url = selectedURLs.first,
               let file = files.first(where: { $0.url == url }) {
                if file.isDirectory { onNavigate(file.url) }
                else { fsService.openFile(file.url) }
            }
            return nil
        case 120: // F2 重命名
            if let url = selectedURLs.first, selectedURLs.count == 1 {
                startRename(url)
            }
            return nil
        default:
            return event
        }
    }

    func installKeyboardMonitor() {
        guard !keyboardInstalled else { return }
        keyboardInstalled = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handleKey)
    }

    // MARK: - 重命名

    /// 开始重命名（从右键菜单或键盘触发）
    func startRename(_ url: URL) {
        renameTarget = url
        renameText = url.lastPathComponent
        isRenaming = true
    }

    private func commitRename() {
        guard let target = renameTarget,
              !renameText.trimmingCharacters(in: .whitespaces).isEmpty,
              fsService.isValidFileName(renameText),
              renameText != target.lastPathComponent else {
            cancelRename()
            return
        }
        do {
            _ = try fsService.renameItem(at: target, to: renameText.trimmingCharacters(in: .whitespaces))
            onRefresh()
        } catch {
            print("重命名失败: \(error)")
        }
        cancelRename()
    }

    private func cancelRename() {
        isRenaming = false
        renameTarget = nil
        renameText = ""
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

    /// 右键菜单条目（file 为 nil 表示空白区域），由 NSTableView 构建 NSMenu
    private func menuItems(for file: FileItem?) -> [FileMenuItem] {
        guard let file else {
            return [
                FileMenuItem("新建文件夹") { startCreateFolder() },
                FileMenuItem("粘贴", enabled: !clipboardURLs.isEmpty) { pasteFromClipboard() },
                .divider,
                FileMenuItem(showHiddenFiles ? "不显示隐藏项目" : "显示隐藏项目") { showHiddenFiles.toggle() },
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
            FileMenuItem("重命名") { startRename(file.url) },
            .divider,
            FileMenuItem("在 Finder 中显示") { fsService.revealInFinder(file.url) },
        ]
        if file.isDirectory {
            items.append(FileMenuItem("在 Finder 中打开") { fsService.openInFinder(file.url) })
        }
        items += [
            .divider,
            FileMenuItem("复制路径") { fsService.copyPath(file.url) },
            .divider,
            FileMenuItem("移到废纸篓", keyEquivalent: String(UnicodeScalar(NSDeleteFunctionKey)!)) {
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
    let enabled: Bool
    let action: () -> Void

    init(_ title: String, keyEquivalent: String? = nil, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.keyEquivalent = keyEquivalent
        self.enabled = enabled
        self.action = action
    }

    static let divider = FileMenuItem("", enabled: true, action: {})
    var isDivider: Bool { title.isEmpty }
}

// MARK: - 原生文件列表（NSTableView：原生选中/多选/双击/行内重命名/右键菜单）

struct FileListTableView: NSViewRepresentable {
    let files: [FileItem]
    @Binding var selectedURLs: Set<URL>
    let cutURLs: Set<URL>
    let renameTarget: URL?
    let currentURL: URL
    let fsService: FileSystemService
    let onOpen: (FileItem) -> Void
    let onSelection: (Set<URL>) -> Void
    let onRenameEnd: (String, Bool) -> Void
    let onRefresh: () -> Void
    let menuItems: (FileItem?) -> [FileMenuItem]

    private static let nameCellID = NSUserInterfaceItemIdentifier("FileListNameCell")
    private static let textCellID = NSUserInterfaceItemIdentifier("FileListTextCell")

    func makeCoordinator() -> Coordinator {
        Coordinator(
            files: files,
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

        let key = files.map { $0.url.path }.joined(separator: "|")
        if key != coordinator.filesKey {
            coordinator.files = files
            coordinator.filesKey = key
            coordinator.table?.reloadData()
            // 空文件夹时隐藏行分隔线，占位符更干净
            coordinator.table?.gridStyleMask = files.isEmpty ? [] : .solidHorizontalGridLineMask
        }

        let cutKey = cutURLs.map(\.path).sorted().joined(separator: "|")
        if cutKey != coordinator.cutKey {
            coordinator.cutURLs = cutURLs
            coordinator.cutKey = cutKey
            coordinator.refreshCutAppearance()
        }

        coordinator.syncSelection(to: selectedURLs)
        coordinator.syncRename(renameTarget)
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSControlTextEditingDelegate {
        var files: [FileItem]
        var cutURLs: Set<URL>
        var currentURL: URL
        var fsService: FileSystemService
        var onOpen: (FileItem) -> Void
        var onSelection: (Set<URL>) -> Void
        var onRenameEnd: (String, Bool) -> Void
        var onRefresh: () -> Void
        var menuItems: (FileItem?) -> [FileMenuItem]
        weak var table: NSTableView?
        var filesKey = ""
        var cutKey = ""
        var renameRow: Int?
        var isSyncingSelection = false

        init(files: [FileItem], cutURLs: Set<URL>, currentURL: URL, fsService: FileSystemService,
             onOpen: @escaping (FileItem) -> Void, onSelection: @escaping (Set<URL>) -> Void,
             onRenameEnd: @escaping (String, Bool) -> Void, onRefresh: @escaping () -> Void,
             menuItems: @escaping (FileItem?) -> [FileMenuItem]) {
            self.files = files
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

        func numberOfRows(in tableView: NSTableView) -> Int {
            files.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row < files.count else { return nil }
            let file = files[row]

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
            return Set(table.selectedRowIndexes.compactMap { row in
                row < files.count ? files[row].url : nil
            })
        }

        func syncSelection(to urls: Set<URL>) {
            guard let table, currentSelection != urls else { return }
            let indexes = IndexSet(files.enumerated().compactMap {
                urls.contains($0.element.url) ? $0.offset : nil
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
            let row = sender.clickedRow
            guard row >= 0, row < files.count else { return }
            onOpen(files[row])
        }

        // MARK: 剪切态半透明

        func refreshCutAppearance() {
            guard let table else { return }
            for row in 0..<min(table.numberOfRows, files.count) {
                let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView
                cell?.alphaValue = cutURLs.contains(files[row].url) ? 0.45 : 1
            }
        }

        // MARK: 行内重命名（原生字段编辑器）

        func syncRename(_ target: URL?) {
            guard let table else { return }
            let row: Int? = target.flatMap { target in
                files.firstIndex { $0.url == target }
            }
            guard row != renameRow else { return }
            renameRow = row
            guard let row, row < table.numberOfRows else { return }
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            if let cell = table.rowView(atRow: row, makeIfNecessary: true)?.view(atColumn: 0)
                as? NSTableCellView {
                cell.textField?.isEditable = true
            }
            DispatchQueue.main.async { [weak table] in
                table?.editColumn(0, row: row, with: nil, select: true)
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            textField.isEditable = false
            renameRow = nil
            let movement = (obj.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:))
            onRenameEnd(textField.stringValue, movement == .cancel)
        }

        // MARK: 拖放

        // 拖出行：为行提供 URL writer 以发起拖拽；数据由 FileTable.beginDraggingSession 立即写入粘贴板
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            row >= 0 && row < files.count ? files[row].url as NSURL : nil
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
            if operation == .on, row >= 0, row < files.count,
               files[row].isDirectory, !urls.contains(files[row].url) {
                destination = files[row].url
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
            let specs = menuItems(row >= 0 && row < files.count ? files[row] : nil)
            let menu = NSMenu()
            for spec in specs {
                if spec.isDivider {
                    menu.addItem(.separator())
                } else {
                    let item = NSMenuItem(
                        title: spec.title,
                        action: #selector(menuItemClicked(_:)),
                        keyEquivalent: spec.keyEquivalent ?? ""
                    )
                    item.target = self
                    item.isEnabled = spec.enabled
                    item.representedObject = MenuActionBox(action: spec.action)
                    menu.addItem(item)
                }
            }
            return menu
        }

        @objc private func menuItemClicked(_ sender: NSMenuItem) {
            (sender.representedObject as? MenuActionBox)?.action()
        }
    }

    private final class MenuActionBox {
        let action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
    }

    /// 右键未选中行时先选中该行（Finder 行为）
    final class FileTable: NSTableView {
        var menuProvider: ((Int, NSEvent) -> NSMenu?)?

        override func menu(for event: NSEvent) -> NSMenu? {
            let point = convert(event.locationInWindow, from: nil)
            let row = row(at: point)
            if row >= 0, !selectedRowIndexes.contains(row) {
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
                .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
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
