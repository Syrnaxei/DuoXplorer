import SwiftUI
import AppKit

/// 侧边栏条目：常用位置 / 分组标题 / 颜色标签 / 所有标签
enum SidebarEntry {
    case folder(name: String, url: URL)
    case group(String)
    case tag(FinderTag)
    case allTags

    var isGroup: Bool {
        if case .group = self { return true }
        return false
    }
}

/// 侧边栏（原生 NSOutlineView，source list 样式）：常用位置 + Finder 颜色标签区
struct SidebarTagsView: NSViewRepresentable {
    let folders: [(name: String, url: URL)]
    let selectedTag: FinderTag?
    let allTagsMode: Bool
    let onSelect: (URL) -> Void
    let onTagSelect: (FinderTag) -> Void
    let onAllTags: () -> Void

    private static let folderCellID = NSUserInterfaceItemIdentifier("SidebarFolderCell")
    private static let groupCellID = NSUserInterfaceItemIdentifier("SidebarGroupCell")
    private static let tagCellID = NSUserInterfaceItemIdentifier("SidebarTagCell")
    private static let allTagsCellID = NSUserInterfaceItemIdentifier("SidebarAllTagsCell")

    func makeCoordinator() -> Coordinator {
        Coordinator(folders: folders, onSelect: onSelect, onTagSelect: onTagSelect, onAllTags: onAllTags)
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
        coordinator.onAllTags = onAllTags
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
        case .tag(let tag): matches = tag == selectedTag && !allTagsMode
        case .allTags: matches = allTagsMode
        case .folder, .group: return
        }
        if !matches { outline.deselectRow(row) }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var folders: [(name: String, url: URL)]
        var foldersKey: String
        var onSelect: ((URL) -> Void)?
        var onTagSelect: ((FinderTag) -> Void)?
        var onAllTags: (() -> Void)?
        weak var outlineView: NSOutlineView?

        init(folders: [(name: String, url: URL)], onSelect: @escaping (URL) -> Void,
             onTagSelect: @escaping (FinderTag) -> Void, onAllTags: @escaping () -> Void) {
            self.folders = folders
            self.foldersKey = folders.map(\.url.path).joined(separator: "|")
            self.onSelect = onSelect
            self.onTagSelect = onTagSelect
            self.onAllTags = onAllTags
        }

        private var entries: [SidebarEntry] {
            folders.map { SidebarEntry.folder(name: $0.name, url: $0.url) }
                + [.group("标签")]
                + FinderTag.all.map(SidebarEntry.tag)
                + [.allTags]
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
                    ?? TagCellView(showsRing: false)
                cell.identifier = SidebarTagsView.tagCellID
                cell.textField?.stringValue = tag.name
                cell.dot.color = tag.color
                return cell
            case .allTags:
                let cell = outlineView.makeView(withIdentifier: SidebarTagsView.allTagsCellID, owner: nil) as? TagCellView
                    ?? TagCellView(showsRing: true)
                cell.identifier = SidebarTagsView.allTagsCellID
                cell.textField?.stringValue = "所有标签..."
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
            case .allTags: onAllTags?()
            case .group: break
            }
        }
    }
}

// MARK: - 标签行单元格（彩色圆点 / 双圆环图标 + 名称）

final class TagCellView: NSTableCellView {
    let dot = TagDotView()
    let ring = TagRingView()

    init(showsRing: Bool) {
        super.init(frame: .zero)
        let icon: NSView = showsRing ? ring : dot
        icon.translatesAutoresizingMaskIntoConstraints = false
        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .systemFont(ofSize: 13)
        textField.lineBreakMode = .byTruncatingTail
        addSubview(icon)
        addSubview(textField)
        self.textField = textField
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: showsRing ? 0 : 3),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: showsRing ? 15 : 10),
            icon.heightAnchor.constraint(equalToConstant: 10),
            textField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
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

/// 「所有标签...」图标：两个相交的圆环（Finder 同款造型）
final class TagRingView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.setStroke()
        let r = bounds.height / 2 - 0.5
        let path = NSBezierPath()
        path.append(NSBezierPath(ovalIn: NSRect(x: 0.5, y: bounds.midY - r, width: r * 2, height: r * 2)))
        path.append(NSBezierPath(ovalIn: NSRect(x: bounds.width - r * 2 - 0.5, y: bounds.midY - r, width: r * 2, height: r * 2)))
        path.lineWidth = 1
        path.stroke()
    }
}
