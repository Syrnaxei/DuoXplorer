import SwiftUI

/// 目录树侧边栏
struct SidebarTreeView: View {
    let roots: [TreeNode]
    let onSelect: (URL) -> Void

    @State private var selectedURL: URL?

    var body: some View {
        List(roots) { node in
            SidebarTreeNodeRow(
                node: node,
                onSelect: { url in
                    selectedURL = url
                    onSelect(url)
                },
                selectedURL: selectedURL
            )
        }
        .listStyle(.sidebar)
    }
}

struct SidebarTreeNodeRow: View {
    @ObservedObject var node: TreeNode
    let onSelect: (URL) -> Void
    let selectedURL: URL?

    private var isSelected: Bool { node.url == selectedURL }

    /// 仿 Finder 的灰色选中高亮；用 listRowBackground 铺满整行：
    /// 左侧覆盖展开箭头，上下与相邻行相接
    private var rowHighlight: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.primary.opacity(isSelected ? 0.12 : 0))
    }

    var body: some View {
        Group {
            if node.children == nil && node.isDirectory {
                // 尚未加载子节点
                HStack {
                    Image(systemName: "folder")
                        .foregroundColor(.accentColor)
                    Text(node.name)
                        .font(.system(size: 13))
                    Spacer()

                    if node.isLoading {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(node.url) }
                .task {
                    await node.loadChildren()
                }
            } else if let children = node.children, !children.isEmpty {
                // 有子文件夹
                DisclosureGroup(
                    content: {
                        ForEach(children) { child in
                            SidebarTreeNodeRow(node: child, onSelect: onSelect, selectedURL: selectedURL)
                        }
                    },
                    label: {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundColor(.accentColor)
                            Text(node.name)
                                .font(.system(size: 13))
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(node.url) }
                    }
                )
            } else {
                // 空文件夹
                HStack {
                    Image(systemName: "folder")
                        .foregroundColor(.secondary)
                    Text(node.name)
                        .font(.system(size: 13))
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(node.url) }
            }
        }
        // 行内边距清零，让内容（含点击区）铺满整行，与 listRowBackground 高亮范围一致；
        // 原有边距用行内 padding(.horizontal, 10) 补偿
        .listRowInsets(EdgeInsets())
        .listRowBackground(rowHighlight)
    }
}
