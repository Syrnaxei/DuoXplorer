import XCTest
@testable import DuoXplore

final class GroupingServiceTests: XCTestCase {
    private func item(_ path: String, isDirectory: Bool = false, size: Int64? = nil,
                      mod: Date? = nil, created: Date? = nil, added: Date? = nil, used: Date? = nil,
                      tags: [String]? = nil) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/group-test/\(path)", isDirectory: isDirectory),
                 size: size, modificationDate: mod, createdDate: created,
                 addedDate: added, lastUsedDate: used, tags: tags)
    }

    // MARK: - 无

    func testNoneReturnsSingleFlatGroup() {
        let files = [item("b.txt"), item("a.txt")]
        let groups = GroupingService.group(files, by: .none, sortOption: .name, sortDirection: .ascending)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].items.map(\.name), ["a.txt", "b.txt"])
    }

    func testEmptyInputReturnsNoGroups() {
        XCTAssertTrue(GroupingService.group([], by: .kind, sortOption: .name, sortDirection: .ascending).isEmpty)
    }

    // MARK: - 名称

    func testNameGroupingByFirstCharacter() {
        let groups = GroupingService.group(
            [item("apple.txt"), item("Banana.txt"), item("苹果.txt"), item("2026.txt"), item(".hidden")],
            by: .name, sortOption: .name, sortDirection: .ascending)
        XCTAssertEqual(groups.map(\.title), ["#", "A", "B", "苹"])
        XCTAssertEqual(groups[1].items.map(\.name), ["apple.txt"])
    }

    // MARK: - 种类

    func testKindCategories() {
        let groups = GroupingService.group(
            [item("a.png"), item("b.mp3"), item("c.mp4"), item("d.zip"), item("e.txt"), item("f.xyz")],
            by: .kind, sortOption: .name, sortDirection: .ascending)
        // 组间按组名本地化排序：断言集合完整且两两符合 localizedStandardCompare 次序
        XCTAssertEqual(Set(groups.map(\.title)), Set(["其他", "图像", "归档", "文稿", "影片", "音频"]))
        XCTAssertEqual(groups.map(\.title), groups.map(\.title).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    }

    func testKindFolderBeforeApp() {
        let groups = GroupingService.group(
            [item("Tool.app", isDirectory: true), item("Folder", isDirectory: true)],
            by: .kind, sortOption: .name, sortDirection: .ascending)
        // 组间按组名（本地化）排序：「文件夹」排在「应用程序」前
        XCTAssertEqual(groups.map(\.title), ["文件夹", "应用程序"])
    }

    // MARK: - 应用程序

    func testApplicationTwoGroups() {
        let groups = GroupingService.group(
            [item("Tool.app", isDirectory: true), item("a.txt")],
            by: .application, sortOption: .name, sortDirection: .ascending)
        XCTAssertEqual(groups.map(\.title), ["应用程序", "其他"])
    }

    // MARK: - 日期分桶

    func testDateBucketsOrderedAndAssigned() throws {
        let ref = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12)))
        let cal = Calendar.current
        func ago(_ days: Int) -> Date { cal.date(byAdding: .day, value: -days, to: ref)! }
        let twoYearsAgo = cal.date(byAdding: .year, value: -2, to: ref)!

        let groups = GroupingService.group(
            [item("a", mod: ref),
             item("b", mod: ago(1)),
             item("c", mod: ago(3)),
             item("d", mod: ago(10)),
             item("e", mod: ago(60)),
             item("f", mod: twoYearsAgo),
             item("g")],
            by: .modified, sortOption: .name, sortDirection: .ascending, now: ref)

        XCTAssertEqual(groups.map(\.title), ["今天", "昨天", "前 7 天", "前 30 天", "今年", "更早", "无日期"])
        XCTAssertEqual(groups[0].items.map(\.name), ["a"])
        XCTAssertEqual(groups[6].items.map(\.name), ["g"])
    }

    func testDateDimensionsUseDifferentAttributes() {
        let ref = Date()
        let groups = GroupingService.group(
            [item("a", created: ref),
             item("b")],
            by: .created, sortOption: .name, sortDirection: .ascending, now: ref)
        XCTAssertEqual(groups.map(\.title), ["今天", "无日期"])
    }

    // MARK: - 大小分桶

    func testSizeBucketBoundaries() {
        let kb: Int64 = 1024, mb = 1024 * kb, gb = 1024 * mb
        let files: [(String, Int64?)] = [
            ("a", 5 * kb), ("b", 10 * kb), ("c", 100 * kb), ("d", mb),
            ("e", 10 * mb), ("f", 100 * mb), ("g", gb)
        ]
        let groups = GroupingService.group(
            files.map { item($0.0, size: $0.1) },
            by: .size, sortOption: .name, sortDirection: .ascending)

        XCTAssertEqual(groups.map(\.title), [
            "1 GB 以上", "100–1000 MB", "10–100 MB", "1–10 MB",
            "100 KB–1 MB", "10–100 KB", "小于 10 KB",
        ])
        XCTAssertEqual(groups.last?.items.map(\.name), ["a"])
    }

    func testSizeFolderAndUnknown() {
        let groups = GroupingService.group(
            [item("folder", isDirectory: true), item("no-size")],
            by: .size, sortOption: .name, sortDirection: .ascending)
        XCTAssertEqual(groups.map(\.title), ["文件夹", "未知大小"])
    }

    // MARK: - 标签

    func testTagGroupingUsesFinderTagOrder() {
        let groups = GroupingService.group(
            [item("a", tags: ["红色"]), item("b", tags: ["蓝色", "红色"]), item("c")],
            by: .tag, sortOption: .name, sortDirection: .ascending)
        XCTAssertEqual(groups.map(\.title), ["红色", "蓝色", "无标签"])
        // 多标签条目取存储序第一个标签
        XCTAssertEqual(groups[1].items.map(\.name), ["b"])
    }

    // MARK: - 组内排序

    func testInGroupSortRespectsOptionAndDirection() {
        let groups = GroupingService.group(
            [item("b.png", size: 1), item("a.png", size: 2)],
            by: .kind, sortOption: .size, sortDirection: .descending)
        XCTAssertEqual(groups[0].items.map(\.name), ["a.png", "b.png"])
    }

    func testInGroupSortKeepsFoldersFirst() {
        let groups = GroupingService.group(
            [item("z.txt"), item("a-folder", isDirectory: true)],
            by: .kind, sortOption: .name, sortDirection: .ascending)
        XCTAssertEqual(groups.count, 2) // 文件夹与文稿不在一组
        let dirGroup = groups.first { $0.title == "文件夹" }
        XCTAssertEqual(dirGroup?.items.map(\.name), ["a-folder"])
    }
}

// MARK: - 行模型映射

final class FileListRowTests: XCTestCase {
    private func item(_ name: String) -> FileItem {
        FileItem(url: URL(fileURLWithPath: "/tmp/row-test/\(name)"))
    }

    func testGroupedRowsInterleaveHeaders() {
        let groups = [
            FileGroup(title: "A", items: [item("a1"), item("a2")]),
            FileGroup(title: "B", items: [item("b1")]),
        ]
        let rows = FileListRow.rows(from: groups, grouped: true)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows[0], .header(title: "A", count: 2))
        XCTAssertEqual(rows[1].file?.name, "a1")
        XCTAssertEqual(rows[3], .header(title: "B", count: 1))
    }

    func testFlatRowsHaveNoHeaders() {
        let groups = [FileGroup(title: "", items: [item("a1"), item("a2")])]
        let rows = FileListRow.rows(from: groups, grouped: false)
        XCTAssertEqual(rows.compactMap(\.file).count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.file != nil })
    }

    func testRowsDifferOnGroupingAndSort() {
        let files = [item("a"), item("b")]
        let flat = FileListRow.rows(from: [FileGroup(title: "", items: files)], grouped: false)
        let grouped = FileListRow.rows(from: [FileGroup(title: "G", items: files)], grouped: true)
        // FileListTableView 直接用数组相等判断是否 reload
        XCTAssertNotEqual(flat, grouped)
        XCTAssertEqual(flat, flat)
    }
}

// MARK: - 行内重命名会话（真实 NSTableView + 字段编辑器）

@MainActor
final class RenameEditingTests: XCTestCase {
    private func fileRow(_ name: String) -> FileListRow {
        .file(FileItem(url: URL(fileURLWithPath: "/tmp/rename-test/\(name)"),
                       size: nil, modificationDate: nil))
    }

    /// 复刻 makeNSView 的最小装配：窗口 + FileTable + 协调器
    private func makeWindow(coordinator: FileListTableView.Coordinator) -> NSWindow {
        let table = FileListTableView.FileTable()
        table.rowHeight = 28
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.width = 200
        table.addTableColumn(column)
        coordinator.table = table
        table.dataSource = coordinator
        table.delegate = coordinator
        table.reloadData()

        let scrollView = NSScrollView()
        scrollView.documentView = table
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scrollView
        return window
    }

    private func keyDown(_ char: String, keyCode: UInt16, in window: NSWindow) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: char, charactersIgnoringModifiers: char,
            isARepeat: false, keyCode: keyCode)!
        window.sendEvent(event)
    }

    func testBeginRenameGivesFieldEditorFocusAndAcceptsTyping() {
        let coordinator = FileListTableView.Coordinator(
            rows: [fileRow("old.txt")],
            cutURLs: [],
            currentURL: URL(fileURLWithPath: "/tmp/rename-test"),
            fsService: FileSystemService(),
            onOpen: { _ in }, onSelection: { _ in },
            onRenameEnd: { _, _, _ in },
            onRefresh: {}, menuItems: { _ in [] })

        // xctest 进程拿不到 key 窗口，editColumn 必然被拒，正好全程走兜底直编路径
        let window = makeWindow(coordinator: coordinator)
        window.orderFrontRegardless()
        XCTAssertTrue(window.makeFirstResponder(coordinator.table) ?? false)

        coordinator.beginRename(URL(fileURLWithPath: "/tmp/rename-test/old.txt"))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        // 不变量：编辑会话开着（editColumn 或兜底直编）就必须持有键盘焦点，输入能落字；
        // 两种路径都开不成时必须干净复位：焦点回到表格、会话关闭，不留游离编辑器吞键盘
        let table = coordinator.table
        let editor = table?.currentEditor() ?? coordinator.fallbackTextField?.currentEditor()
        if let editor {
            XCTAssertTrue(window.firstResponder === editor)
            keyDown("a", keyCode: 0, in: window)
            XCTAssertEqual(editor.string, "a")
        } else {
            XCTAssertTrue(window.firstResponder === table, "编辑未开启时焦点必须回到表格，不能留在游离编辑器上")
            XCTAssertFalse(coordinator.isEditingRename)
        }
    }
}

// MARK: - 分组标题行选中过滤（NSTableView 数据源）

@MainActor
final class FileListHeaderSelectionTests: XCTestCase {
    private func fileRow(_ name: String) -> FileListRow {
        .file(FileItem(url: URL(fileURLWithPath: "/tmp/hdr-test/\(name)"),
                       size: nil, modificationDate: nil))
    }

    private var coordinator: FileListTableView.Coordinator {
        FileListTableView.Coordinator(
            rows: [.header(title: "A", count: 2), fileRow("a1"), fileRow("a2")],
            cutURLs: [],
            currentURL: URL(fileURLWithPath: "/tmp/hdr-test"),
            fsService: FileSystemService(),
            onOpen: { _ in }, onSelection: { _ in }, onRenameEnd: { _, _, _ in },
            onRefresh: {}, menuItems: { _ in [] })
    }

    func testKeyboardNavigationSkipsHeaderRow() {
        let c = coordinator
        XCTAssertFalse(c.tableView(NSTableView(), shouldSelectRow: 0))
        XCTAssertTrue(c.tableView(NSTableView(), shouldSelectRow: 1))
    }

    func testBatchSelectionFiltersHeaderRow() {
        let c = coordinator
        let result = c.tableView(NSTableView(), selectionIndexesForProposedSelection: IndexSet(integersIn: 0..<3))
        XCTAssertEqual(result, IndexSet(integersIn: 1..<3))
    }
}
