import SwiftUI
import AppKit

/// 目录树侧边栏（原生 NSOutlineView，source list 样式）
struct SidebarTreeView: NSViewRepresentable {
    let roots: [TreeNode]
    let onSelect: (URL) -> Void

    private static let cellID = NSUserInterfaceItemIdentifier("SidebarTreeCell")

    func makeCoordinator() -> Coordinator {
        Coordinator(roots: roots, onSelect: onSelect)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 12
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
        // body 每次求值都会新建 TreeNode 根；按路径判断是否真的变化，避免频繁 reloadData 丢展开状态
        let key = roots.map(\.url.path).joined(separator: "|")
        guard key != coordinator.rootsKey else { return }
        coordinator.rootsKey = key
        coordinator.roots = roots
        coordinator.outlineView?.reloadData()
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var roots: [TreeNode]
        var onSelect: ((URL) -> Void)?
        var rootsKey: String
        weak var outlineView: NSOutlineView?

        init(roots: [TreeNode], onSelect: @escaping (URL) -> Void) {
            self.roots = roots
            self.onSelect = onSelect
            self.rootsKey = roots.map(\.url.path).joined(separator: "|")
        }

        // MARK: 数据源（子目录懒加载：未加载视为可展开，数量 0，展开后异步加载再刷新）

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil { return roots.count }
            return (item as? TreeNode)?.children?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? TreeNode else { return false }
            return node.isDirectory && (node.children == nil || !node.children!.isEmpty)
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil { return roots[index] }
            return (item as! TreeNode).children![index]
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? TreeNode else { return nil }
            let cell = outlineView.makeView(withIdentifier: SidebarTreeView.cellID, owner: nil) as? NSTableCellView
                ?? Self.makeCell()
            cell.textField?.stringValue = node.name
            cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.url.path)
            return cell
        }

        private static func makeCell() -> NSTableCellView {
            let cell = NSTableCellView()
            cell.identifier = cellID
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

        // MARK: 展开与选中

        func outlineViewItemWillExpand(_ notification: Notification) {
            guard let outline = notification.object as? NSOutlineView,
                  let node = notification.userInfo?["NSObject"] as? TreeNode,
                  node.children == nil else { return }
            Task { @MainActor in
                await node.loadChildren()
                outline.reloadItem(node, reloadChildren: true)
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline = notification.object as? NSOutlineView,
                  let node = outline.item(atRow: outline.selectedRow) as? TreeNode else { return }
            onSelect?(node.url)
        }
    }
}
