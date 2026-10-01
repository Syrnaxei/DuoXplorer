import SwiftUI

/// 主内容视图 - 整合面包屑、搜索、文件列表、状态栏
struct MainContentView: View {
    @Binding var currentURL: URL
    @Binding var files: [FileItem]
    @Binding var sortOption: SortOption
    @Binding var sortDirection: SortDirection
    @Binding var selectedURLs: Set<URL>
    @Binding var clipboardURLs: [URL]
    @Binding var clipboardIsCut: Bool
    @Binding var showHiddenFiles: Bool
    @Binding var activeTag: FinderTag?
    let navigationState: NavigationState
    let fsService: FileSystemService

    @State private var isLoading = false
    @State private var searchText = ""
    @State private var isRenaming = false
    @State private var renameTarget: URL?
    @State private var renameText = ""
    @State private var loadError: String?
    @State private var watcherSource: DispatchSourceFileSystemObject?
    @StateObject private var spotlight = SpotlightSearchService()

    /// 标签模式下显示 Spotlight 标签结果
    private var tagActive: Bool { activeTag != nil }

    /// 搜索时显示 Spotlight（或回退）结果，否则显示当前文件夹
    var displayedFiles: [FileItem] {
        tagActive || !searchText.isEmpty ? spotlight.items : files
    }

    /// 状态栏统计
    var selectedStats: (count: Int, size: Int64) {
        let selected = displayedFiles.filter { selectedURLs.contains($0.url) }
        let totalSize: Int64 = selected.reduce(0) { $0 + ($1.size ?? 0) }
        return (selected.count, totalSize)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏：标签模式只看搜索结果，不显示面包屑
            if !tagActive {
                BreadcrumbBar(currentURL: $currentURL, onNavigate: { navigate(to: $0) })
                Divider()
            }

            fileList

            Divider()

            // 状态栏
            statusBar
        }
        .onChange(of: showHiddenFiles) { loadFiles() }
        .onAppear { loadFiles() }
        .onChange(of: currentURL) { startWatcher() }
        .onChange(of: activeTag) { tag in
            selectedURLs = []
            searchText = ""
            guard let tag else {
                spotlight.stop()
                return
            }
            spotlight.searchTag(tag)
        }
        .onChange(of: searchText) { text in
            guard !tagActive else { return }
            selectedURLs = []
            guard !text.isEmpty else {
                spotlight.stop()
                return
            }
            spotlight.search(text: text, in: currentURL) { t in
                files.filter { $0.name.localizedCaseInsensitiveContains(t) }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: {
                    if let location = navigationState.goBack(from: currentLocation) {
                        apply(location)
                    }
                }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!navigationState.canGoBack())
                .help("后退")

                Button(action: {
                    if let location = navigationState.goForward(from: currentLocation) {
                        apply(location)
                    }
                }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!navigationState.canGoForward())
                .help("前进")

                Button(action: {
                    navigate(to: currentURL.deletingLastPathComponent())
                }) {
                    Image(systemName: "arrow.up")
                }
                // 标签模式下 currentURL 是进入标签前的残留目录，向上一层无意义
                .disabled(tagActive || currentURL.path == "/")
                .help("向上一层")
            }
        }
    }

    @ViewBuilder private var fileList: some View {
        if isLoading {
            Spacer()
            ProgressView("正在加载...")
            Spacer()
        } else {
            FileListView(
                files: Binding(get: { displayedFiles }, set: { files = $0 }),
                sortOption: $sortOption,
                sortDirection: $sortDirection,
                selectedURLs: $selectedURLs,
                clipboardURLs: $clipboardURLs,
                clipboardIsCut: $clipboardIsCut,
                currentURL: $currentURL,
                showHiddenFiles: $showHiddenFiles,
                searchText: $searchText,
                loadError: loadError,
                isSearching: tagActive || !searchText.isEmpty,
                isTagFilterActive: tagActive,
                onNavigate: { navigate(to: $0) },
                fsService: fsService,
                isRenaming: $isRenaming,
                renameTarget: $renameTarget,
                renameText: $renameText,
                onRefresh: { refresh() }
            )
        }
    }

    /// 当前位置：标签模式下视为标签页，否则是目录
    private var currentLocation: NavLocation {
        if let tag = activeTag { return .tag(tag) }
        return .folder(currentURL)
    }

    /// 应用历史条目（前进/后退）：恢复标签查询或加载目录；栈操作已由 goBack/goForward 完成，不再 push
    private func apply(_ location: NavLocation) {
        switch location {
        case .tag(let tag):
            activeTag = tag
        case .folder(let url):
            activeTag = nil
            currentURL = url
            loadFiles()
        }
    }

    /// 目录间导航：退出标签模式并加载目标文件夹
    private func navigate(to url: URL) {
        navigationState.push(currentLocation)
        activeTag = nil
        currentURL = url
        loadFiles()
    }

    /// 标签模式下文件变动（删除/粘贴/拖放）后刷新标签结果，否则刷新目录列表
    private func refresh() {
        if let tag = activeTag {
            spotlight.searchTag(tag)
        } else {
            loadFiles()
        }
    }

    private var statusBar: some View {
        HStack {
            if tagActive || !searchText.isEmpty {
                Text("\(displayedFiles.count) 个结果")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                Text("\(files.count) 个项目")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            if selectedStats.count > 0 {
                Text("  |  已选 \(selectedStats.count) 个")
                    .font(.system(size: 11))
                    .foregroundColor(.accentColor)

                if selectedStats.size > 0 {
                    Text(ByteCountFormatter().string(fromByteCount: selectedStats.size))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func loadFiles() {
        isLoading = true
        do {
            files = try fsService.listDirectory(at: currentURL, showHidden: showHiddenFiles)
            loadError = nil
        } catch {
            files = []
            loadError = error.localizedDescription
        }
        selectedURLs = []
        searchText = ""
        isLoading = false
        startWatcher()
    }

    /// 监视当前目录变化，外部文件新增/删除时自动刷新列表
    private func startWatcher() {
        watcherSource?.cancel()
        watcherSource = nil

        let fd = open(currentURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .link],
            queue: .main
        )
        source.setEventHandler { [self] in
            do {
                let updated = try fsService.listDirectory(at: currentURL, showHidden: showHiddenFiles)
                if updated.map(\.url) != files.map(\.url) {
                    withAnimation(.easeInOut(duration: 0.1)) {
                        files = updated
                    }
                }
            } catch {
                // 目录可能已被删除，忽略
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcherSource = source
    }
}
