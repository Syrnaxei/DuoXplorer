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

    /// 搜索时显示 Spotlight（或回退）结果，否则显示当前文件夹
    var displayedFiles: [FileItem] {
        searchText.isEmpty ? files : spotlight.items
    }

    /// 状态栏统计
    var selectedStats: (count: Int, size: Int64) {
        let selected = files.filter { selectedURLs.contains($0.url) }
        let totalSize: Int64 = selected.reduce(0) { $0 + ($1.size ?? 0) }
        return (selected.count, totalSize)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 面包屑地址栏
            BreadcrumbBar(currentURL: $currentURL, onNavigate: { url in
                navigationState.push(currentURL)
                currentURL = url
                loadFiles()
            })

            Divider()

            // 文件列表
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
                    loadError: loadError,
                    isSearching: !searchText.isEmpty,
                    onNavigate: { url in
                        navigationState.push(currentURL)
                        currentURL = url
                        loadFiles()
                    },
                    fsService: fsService,
                    isRenaming: $isRenaming,
                    renameTarget: $renameTarget,
                    renameText: $renameText,
                    onRefresh: { loadFiles() }
                )
            }

            Divider()

            // 状态栏
            statusBar
        }
        .onChange(of: showHiddenFiles) { loadFiles() }
        .onAppear { loadFiles() }
        .onChange(of: currentURL) { startWatcher() }
        .onChange(of: searchText) { text in
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
                    if let url = navigationState.goBack(from: currentURL) {
                        currentURL = url
                        loadFiles()
                    }
                }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(!navigationState.canGoBack())
                .help("后退")

                Button(action: {
                    if let url = navigationState.goForward(from: currentURL) {
                        currentURL = url
                        loadFiles()
                    }
                }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(!navigationState.canGoForward())
                .help("前进")

                Button(action: {
                    let parent = currentURL.deletingLastPathComponent()
                    navigationState.push(currentURL)
                    currentURL = parent
                    loadFiles()
                }) {
                    Image(systemName: "arrow.up")
                }
                .disabled(currentURL.path == "/")
                .help("向上一层")
            }
        }
    }

    private var statusBar: some View {
        HStack {
            if searchText.isEmpty {
                Text("\(files.count) 个项目")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                Text("\(displayedFiles.count) 个结果")
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
