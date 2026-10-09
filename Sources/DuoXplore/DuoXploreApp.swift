import SwiftUI
import AppKit

/// 关于窗口
struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 8)

            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 80, height: 80)

            Text("DuoXplore")
                .font(.system(size: 18, weight: .bold))

            Text("版本 \(AppVersion.marketing) (Build \(AppVersion.build))")
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Text("一个基于 SwiftUI 的 macOS 文件管理器，\n支持面包屑导航、树形侧边栏、多选和键盘操作。\n本项目是 cnwutianhao/finder-explorer 的分支。")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Text("需 macOS 14.0 或更高版本")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            HStack(spacing: 4) {
                Link("Syrnaxei",
                     destination: URL(string: "https://github.com/Syrnaxei")!)
                    .font(.system(size: 10))
                    .foregroundColor(.accentColor)
                Text("·")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Link("项目主页",
                     destination: URL(string: "https://github.com/Syrnaxei/DuoXplorer")!)
                    .font(.system(size: 10))
                    .foregroundColor(.accentColor)
            }

            Spacer().frame(height: 8)
        }
        .frame(width: 380, height: 340)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@main
struct DuoXploreApp: App {
    @StateObject private var navigationState = NavigationState()
    @StateObject private var appSettings = AppSettingsModel()
    @StateObject private var pinnedTagQuery = PinnedTagQuery()
    @State private var currentURL = URL(fileURLWithPath: "/Users/\(NSUserName())")
    @State private var files: [FileItem] = []
    @State private var sortOption: SortOption = .name
    @State private var sortDirection: SortDirection = .ascending
    @State private var selectedURLs: Set<URL> = []
    @State private var clipboardURLs: [URL] = []
    @State private var clipboardIsCut = false
    @State private var activeTag: FinderTag?

    private let fsService = FileSystemService()

    /// 当前位置：标签模式下视为标签页，否则是目录
    private var currentLocation: NavLocation {
        if let tag = activeTag { return .tag(tag) }
        return .folder(currentURL)
    }

    /// 应用历史条目（前进/后退）：恢复标签查询或加载目录；栈操作已由 goBack/goForward 完成，不再 push。
    /// 只改状态，目录内容由 MainContentView.onChange(of: currentURL) 统一加载
    private func applyLocation(_ location: NavLocation) {
        switch location {
        case .tag(let tag):
            activeTag = tag
        case .folder(let url):
            activeTag = nil
            currentURL = url
        }
    }

    /// 窗口标题：标签模式显示标签名，其余显示当前文件夹名
    private var windowTitle: String {
        activeTag?.name ?? currentURL.lastPathComponent
    }

    /// 粘贴：剪切则移动（执行后清空），复制则保留（可多次粘贴）；取消时保留剪贴板
    private func paste() {        guard !clipboardURLs.isEmpty else { return }
        let executed = fsService.pasteItems(clipboardURLs, to: currentURL, isCut: clipboardIsCut)
        if clipboardIsCut && executed {
            clipboardURLs = []
            clipboardIsCut = false
        }
        files = (try? fsService.listDirectory(at: currentURL, showHidden: appSettings.showHiddenFiles)) ?? []
    }

    @State private var aboutWindow: NSWindow?
    @State private var settingsWindowController: SettingsWindowController?

    private func showAboutWindow() {
        if let existing = aboutWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "关于 DuoXplore"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutView())
        window.setContentSize(NSSize(width: 380, height: 340))
        window.center()
        window.makeKeyAndOrderFront(nil)
        aboutWindow = window
    }

    private func showSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(appSettings: appSettings)
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 启动时主动触发系统对常用目录的文件访问授权（TCC），
    /// 避免首次进入「文档/桌面/下载」时才弹授权框打断操作
    private func requestFileAccessAtLaunch() {
        for name in ["Documents", "Desktop", "Downloads"] {
            _ = try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/\(name)")
        }
    }

    private func setAppIcon() {
        guard let bundleURL = Bundle.main.url(forResource: "DuoXplore_DuoXplore", withExtension: "bundle"),
              let bundle = Bundle(url: bundleURL) else {
            print("[DuoXplore] 未找到资源 bundle")
            return
        }
        guard let icnsURL = bundle.url(forResource: "AppIcon", withExtension: "icns") else {
            print("[DuoXplore] 未找到 AppIcon.icns")
            return
        }
        let icon = NSImage(contentsOf: icnsURL)
        NSApp.applicationIconImage = icon
        print("[DuoXplore] 图标已设置")
    }

    var body: some Scene {
        Window("DuoXplore", id: "main") {
            NavigationSplitView {
                SidebarTagsView(
                    folders: [
                        (name: "个人目录", url: URL(fileURLWithPath: "/Users/\(NSUserName())")),
                        (name: "应用程序", url: URL(fileURLWithPath: "/Applications")),
                        (name: "用户", url: URL(fileURLWithPath: "/Users")),
                        (name: "Macintosh HD", url: URL(fileURLWithPath: "/")),
                    ],
                    pinnedTag: FinderTag.all.first { $0.name == appSettings.pinnedTagName },
                    pinnedFolders: pinnedTagQuery.folders,
                    selectedTag: activeTag,
                    onSelect: { url in
                        navigationState.push(currentLocation)
                        activeTag = nil
                        currentURL = url
                        selectedURLs = []
                    },
                    onTagSelect: { tag in
                        navigationState.push(currentLocation)
                        selectedURLs = []
                        activeTag = tag
                    }
                )
                .frame(minWidth: 200)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            } detail: {
                MainContentView(
                    currentURL: $currentURL,
                    files: $files,
                    sortOption: $sortOption,
                    sortDirection: $sortDirection,
                    selectedURLs: $selectedURLs,
                    clipboardURLs: $clipboardURLs,
                    clipboardIsCut: $clipboardIsCut,
                    showHiddenFiles: $appSettings.showHiddenFiles,
                    activeTag: $activeTag,
                    navigationState: navigationState,
                    fsService: fsService
                )
            }
            .navigationSplitViewStyle(.balanced)
            .navigationTitle(windowTitle)
            .frame(minWidth: 800, minHeight: 500)
            .onAppear {
                setAppIcon()
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                requestFileAccessAtLaunch()
                pinnedTagQuery.update(tagName: appSettings.pinnedTagName)
                print("[DuoXplore] 窗口已显示")
            }
            .onChange(of: appSettings.pinnedTagName) { _, newValue in
                pinnedTagQuery.update(tagName: newValue)
            }
        }
        .defaultSize(width: 1100, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 DuoXplore") {
                    showAboutWindow()
                }
            }

            CommandGroup(after: .toolbar) {
                Button("后退") {
                    if let location = navigationState.goBack(from: currentLocation) {
                        applyLocation(location)
                    }
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!navigationState.canGoBack())

                Button("前进") {
                    if let location = navigationState.goForward(from: currentLocation) {
                        applyLocation(location)
                    }
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!navigationState.canGoForward())

                Button(appSettings.showHiddenFiles ? "隐藏隐藏项目" : "显示隐藏项目") {
                    appSettings.showHiddenFiles.toggle()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Button("搜索") { focusSearchField() }
                    .keyboardShortcut("f", modifiers: .command)
            }

            // replacing：去掉 SwiftUI 自动生成的系统剪切/复制/粘贴项，避免同名菜单项与 ⌘C 等键位冲突
            CommandGroup(replacing: .pasteboard) {
                Button("复制") {
                    clipboardURLs = Array(selectedURLs)
                    clipboardIsCut = false
                }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(selectedURLs.isEmpty)

                Button("剪切") {
                    clipboardURLs = Array(selectedURLs)
                    clipboardIsCut = true
                    selectedURLs = []
                }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(selectedURLs.isEmpty)

                Button("粘贴") {
                    paste()
                }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(clipboardURLs.isEmpty)

                Button("全选") {
                    NSApp.sendAction(Selector(("selectAll:")), to: nil, from: nil)
                }
                .keyboardShortcut("a", modifiers: .command)

                Divider()

                Button("复制路径") {
                    if let url = selectedURLs.first {
                        fsService.copyPath(url)
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(selectedURLs.count != 1)

                Divider()

                Button("移到废纸篓") {
                    let urls = selectedURLs.isEmpty ? [] : Array(selectedURLs)
                    fsService.moveToTrash(urls)
                    files = (try? fsService.listDirectory(at: currentURL, showHidden: appSettings.showHiddenFiles)) ?? []
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    showSettingsWindow()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    /// 把焦点交给工具栏搜索框（searchable 没有暴露聚焦 API，靠遍历 AppKit 视图层找 NSSearchField；
    /// 工具栏挂在 contentView 的父视图 themeFrame 下，扫描要从那里开始）
    private func focusSearchField() {
        guard let window = NSApp.keyWindow, let contentView = window.contentView else { return }
        let root = contentView.superview ?? contentView
        func find(in view: NSView) -> NSSearchField? {
            if let field = view as? NSSearchField { return field }
            for sub in view.subviews {
                if let field = find(in: sub) { return field }
            }
            return nil
        }
        if let field = find(in: root) {
            window.makeFirstResponder(field)
        }
    }
}
