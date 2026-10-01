import SwiftUI
import AppKit

/// 侧边栏条目：常用位置 / 分组标题 / 颜色标签
enum SidebarEntry {
    case folder(name: String, url: URL)
    case group(String)
    case tag(FinderTag)

    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }
}

/// 侧边栏（原生 NSOutlineView，source list 样式）：常用位置 + Finder 颜色标签区
struct SidebarTagsView: NSViewRepresentable {
    let folders: [(name: String, url: URL)]
    let selectedTag: FinderTag?
    let onSelect: (URL) -> Void
    let onTagSelect: (FinderTag) -> Void

    private static let folderCellID = NSUserInterfaceItemIdentifier("SidebarFolderCell")
    private static let groupCellID = NSUserInterfaceItemIdentifier("SidebarGroupCell")
    private static let tagCellID = NSUserInterfaceItemIdentifier("SidebarTagCell")

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
        coordinator.outlineView = outline
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelect = onSelect
        coordinator.onTagSelect = onTagSelect
        let key = folders.map(\.url.path).joined(separator: "|")
        if key != coordinator.foldersKey {
            coordinator.foldersKey = key
            coordinator.folders = folders
            coordinator.outlineView?.reloadData()
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
        case .folder, .group: return
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

        private var entries: [SidebarEntry] {
            folders.map { SidebarEntry.folder(name: $0.name, url: $0.url) }
                + [.group("标签")]
                + FinderTag.all.map(SidebarEntry.tag)
        }

        // MARK: 数据源

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            item == nil ? entries.count : 0
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            entries[index]
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
            case .group(let title):
                let cell = outlineView.makeView(withIdentifier: SidebarTagsView.groupCellID, owner: nil) as? NSTableCellView
                    ?? makeGroupCell()
                cell.textField?.stringValue = title
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
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
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
            case .tag(let tag): onTagSelect?(tag)
            case .group: break
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
