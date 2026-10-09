import SwiftUI
import AppKit
import CoreServices

/// 侧边栏条目：分组头（可展开收起）/ 常用位置 / 置顶标签 / 颜色标签
enum SidebarEntry: Hashable {
    case favoritesGroup
    case pinnedGroup
    case tagsGroup
    case folder(name: String, url: URL)
    case showAllPinnedTag
    case tag(FinderTag)

    var isGroup: Bool { self == .favoritesGroup || self == .pinnedGroup || self == .tagsGroup }

    var groupTitle: String? {
        switch self {
        case .favoritesGroup: return "个人收藏"
        case .pinnedGroup: return "置顶标签"
        case .tagsGroup: return "标签"
        case .folder, .showAllPinnedTag, .tag: return nil
        }
    }

    /// 超过 limit 个时截断为前 limit 个 + 「展开标签」占位行
    static func pinnedChildren(_ folders: [SidebarEntry], limit: Int = 5) -> [SidebarEntry] {
        folders.count > limit ? Array(folders.prefix(limit)) + [.showAllPinnedTag] : folders
    }
}

/// 置顶标签下的文件夹列表（Spotlight 全局查询，同 Finder「此 Mac」scope）
@MainActor
final class PinnedTagQuery: ObservableObject {
    @Published private(set) var folders: [URL] = []

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []

    func update(tagName: String?) {
        tearDown()
        guard let tagName else {
            folders = []
            return
        }
        let q = NSMetadataQuery()
        q.predicate = FinderTag.predicate(for: tagName)
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .NSMetadataQueryDidStartGathering,
            .NSMetadataQueryDidUpdate,
            .NSMetadataQueryDidFinishGathering,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: q, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.collect() }
            }
        }
        query = q
        q.start()
    }

    // ponytail: 映射截断到前 500 个文件夹防止超大结果集卡 UI，与 SpotlightSearchService 同一上限
    private func collect() {
        guard let query else { return }
        folders = query.results.compactMap { item -> URL? in
            guard let item = item as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  (item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String])?
                      .contains("public.folder") == true else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        .prefix(500)
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func tearDown() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers = []
        query?.stop()
        query = nil
    }
}

/// 侧边栏（原生 NSOutlineView，source list 样式）：常用位置 + 置顶标签 + Finder 颜色标签区
struct SidebarTagsView: NSViewRepresentable {
    let folders: [(name: String, url: URL)]
    let pinnedTag: FinderTag?
    let pinnedFolders: [URL]
    let selectedTag: FinderTag?
    let onSelect: (URL) -> Void
    let onTagSelect: (FinderTag) -> Void

    private static let folderCellID = NSUserInterfaceItemIdentifier("SidebarFolderCell")
    private static let groupCellID = NSUserInterfaceItemIdentifier("SidebarGroupCell")
    private static let tagCellID = NSUserInterfaceItemIdentifier("SidebarTagCell")
    private static let showAllCellID = NSUserInterfaceItemIdentifier("SidebarShowAllCell")

    func makeCoordinator() -> Coordinator {
        Coordinator(folders: folders, onSelect: onSelect, onTagSelect: onTagSelect)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = true
        outline.indentationPerLevel = 0

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        let scrollView = NSScrollView()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let coordinator = context.coordinator
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.reloadData()
        outline.expandItem(SidebarEntry.favoritesGroup, expandChildren: false)
        outline.expandItem(SidebarEntry.tagsGroup, expandChildren: false)
        coordinator.outlineView = outline
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.onTagSelect = onTagSelect
        coordinator.pinnedTag = pinnedTag
        var needsReload = false
        let key = folders.map(\.url.path).joined(separator: "|")
        if key != coordinator.foldersKey {
            coordinator.foldersKey = key
            coordinator.folders = folders
            needsReload = true
        }
        let pinnedKey = pinnedTag?.name ?? ""
        if pinnedKey != coordinator.pinnedKey {
            coordinator.pinnedKey = pinnedKey
            needsReload = true
        }
        let pinnedFoldersKey = pinnedFolders.map(\.path).joined(separator: "|")
        if pinnedFoldersKey != coordinator.pinnedFoldersKey {
            coordinator.pinnedFoldersKey = pinnedFoldersKey
            coordinator.pinnedFolders = pinnedFolders
            needsReload = true
        }
        if needsReload {
            coordinator.outlineView?.reloadData()
        }
        if pinnedKey != context.coordinator.expandedPinnedKey {
            context.coordinator.expandedPinnedKey = pinnedKey
            // 新置顶标签出现时展开分区；已有分区的收起状态在后续 reload 中保留
            coordinator.outlineView?.expandItem(SidebarEntry.pinnedGroup, expandChildren: false)
        }
        syncSelection(coordinator.outlineView)
    }

    /// 外部状态（标签过滤退出/切换）与侧边栏选中行不同步时，清掉高亮
    private func syncSelection(_ outline: NSOutlineView?) {
        guard let outline else { return }
        let row = outline.selectedRow
        guard row >= 0, let entry = outline.item(atRow: row) as? SidebarEntry else { return }
        let matches: Bool
        switch entry {
        case .tag(let tag): matches = tag == selectedTag
        case .folder, .favoritesGroup, .pinnedGroup, .tagsGroup, .showAllPinnedTag: return
        }
        if !matches { outline.deselectRow(row) }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var folders: [(name: String, url: URL)]
        var foldersKey: String
        var onSelect: ((URL) -> Void)?
        var onTagSelect: ((FinderTag) -> Void)?
        weak var outlineView: NSOutlineView?

        init(folders: [(name: String, url: URL)], onSelect: @escaping (URL) -> Void,
             onTagSelect: @escaping (FinderTag) -> Void) {
            self.folders = folders
            self.foldersKey = folders.map(\.url.path).joined(separator: "|")
            self.onSelect = onSelect
            self.onTagSelect = onTagSelect
        }

        var pinnedTag: FinderTag?
        var pinnedKey = ""
        var pinnedFolders: [URL] = []
        var pinnedFoldersKey = ""
        var expandedPinnedKey: String?

        private var topEntries: [SidebarEntry] {
            pinnedTag == nil ? [.favoritesGroup, .tagsGroup] : [.favoritesGroup, .pinnedGroup, .tagsGroup]
        }

        private func children(of entry: SidebarEntry) -> [SidebarEntry] {
            switch entry {
            case .favoritesGroup: return folders.map { SidebarEntry.folder(name: $0.name, url: $0.url) }
            case .pinnedGroup:
                let rows = pinnedFolders.map { SidebarEntry.folder(name: $0.lastPathComponent, url: $0) }
                return SidebarEntry.pinnedChildren(rows)
            case .tagsGroup: return FinderTag.all.map(SidebarEntry.tag)
            case .folder, .showAllPinnedTag, .tag: return []
            }
        }

        // MARK: 数据源

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let entry = item as? SidebarEntry else { return topEntries.count }
            return children(of: entry).count
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? SidebarEntry)?.isGroup ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let entry = item as? SidebarEntry else { return topEntries[index] }
            return children(of: entry)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            (item as? SidebarEntry)?.isGroup ?? false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let entry = item as? SidebarEntry else { return true }
            return !entry.isGroup
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            (item as? SidebarEntry)?.isGroup == true ? 22 : 24
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let entry = item as? SidebarEntry else { return nil }
            switch entry {
            case .folder(let name, let url):
                let cell = outlineView.makeView(withIdentifier: SidebarTagsView.folderCellID, owner: nil) as? NSTableCellView
                    ?? makeFolderCell()
                cell.textField?.stringValue = name
                cell.imageView?.image = NSWorkspace.shared.icon(forFile: url.path)
                return cell
            case .favoritesGroup, .pinnedGroup, .tagsGroup:
                let cell = outlineView.makeView(withIdentifier: SidebarTagsView.groupCellID, owner: nil) as? NSTableCellView
                    ?? makeGroupCell()
                cell.textField?.stringValue = entry.groupTitle ?? ""
                return cell
            case .showAllPinnedTag:
                let cell = outlineView.makeView(withIdentifier: SidebarTagsView.showAllCellID, owner: nil) as? NSTableCellView
                    ?? makeShowAllCell()
                cell.textField?.stringValue = "展开标签"
                return cell
            case .tag(let tag):
                let cell = outlineView.makeView(withIdentifier: SidebarTagsView.tagCellID, owner: nil) as? TagCellView
                    ?? TagCellView()
                cell.identifier = SidebarTagsView.tagCellID
                cell.textField?.stringValue = tag.name
                cell.dot.color = tag.color
                return cell
            }
        }

        private func makeFolderCell() -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = SidebarTagsView.folderCellID
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            cell.addSubview(imageView)
            cell.addSubview(textField)
            cell.imageView = imageView
            cell.textField = textField
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 5),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            ])
            return cell
        }

        private func makeGroupCell() -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = SidebarTagsView.groupCellID
            let textField = NSTextField(labelWithString: "")
            textField.font = .systemFont(ofSize: 11, weight: .medium)
            textField.textColor = .secondaryLabelColor
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        private func makeShowAllCell() -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = SidebarTagsView.showAllCellID
            let textField = NSTextField(labelWithString: "")
            textField.font = .systemFont(ofSize: 13)
            textField.textColor = .secondaryLabelColor
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }

        // MARK: 选中

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline = notification.object as? NSOutlineView,
                  let entry = outline.item(atRow: outline.selectedRow) as? SidebarEntry else { return }
            switch entry {
            case .folder(_, let url): onSelect?(url)
            case .showAllPinnedTag:
                if let tag = pinnedTag { onTagSelect?(tag) }
            case .tag(let tag): onTagSelect?(tag)
            case .favoritesGroup, .pinnedGroup, .tagsGroup: break
            }
        }
    }
}

// MARK: - 标签行单元格（彩色圆点 + 名称）

final class TagCellView: NSTableCellView {
    let dot = TagDotView()

    init() {
        super.init(frame: .zero)
        dot.translatesAutoresizingMaskIntoConstraints = false
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .systemFont(ofSize: 13)
        textField.lineBreakMode = .byTruncatingTail
        addSubview(dot)
        addSubview(textField)
        self.textField = textField
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            textField.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class TagDotView: NSView {
    var color: NSColor = .clear { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}
