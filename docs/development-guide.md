# DuoXplore 开发流程指南

面向本仓库的日常开发文档：环境准备 → 构建运行 → 代码结构 → 规范 → 提交 → 发布。

> 与 `AGENTS.md` 的关系：`AGENTS.md` 是 AI 协作约束 + 关键事实速查；本文是可执行的操作手册。两者冲突时以本文的实测结论为准。

---

## 1. 环境要求

| 项 | 要求 | 说明 |
|---|---|---|
| 操作系统 | macOS 14.0+ | 实测 macOS 15.7 可用；`LSMinimumSystemVersion` 为 14.0 |
| 语言 | Swift 6.0 工具链 | `swift-tools-version: 6.0`，实际 6.1.2 编译通过 |
| 依赖 | 无第三方包 | 仅 Foundation / AppKit / SwiftUI |
| 构建（单架构） | Command Line Tools 即可 | `xcode-select -p` 指向 `/Library/Developer/CommandLineTools` |
| 构建（多架构 / 打包 dmg） | 需要完整 Xcode | 见下方常见问题 |

```bash
git clone https://github.com/Syrnaxei/DuoXplorer.git
cd DuoXplorer
swift build --disable-sandbox      # 首次全量编译约 60s
```

---

## 2. 日常开发循环

```
改代码 → 增量构建（≈1s）→ 重启应用手工验证 → git commit
```

### 2.1 边开发边跑：三种方式

**A. 一条命令重建并重启（最常用）**

```bash
./build_and_run.sh
```

脚本做三件事：本机架构 Debug 构建 → `pkill -x DuoXplore` 关掉上一实例 → `open` 新二进制。改完代码敲一次，约 1–3 秒后应用带着新逻辑弹出。产物路径不硬编码，由 `swift build --disable-sandbox --show-bin-path` 推导，所以 Intel / Apple Silicon 通用。

**B. Xcode 里 ⌘R（需要断点 / 调试器时）**

```bash
open Package.swift          # 以 SwiftPM 工程打开，不要生成 .xcodeproj 提交回仓库
```

scheme 选 `DuoXplore`，⌘R 构建并运行，可下断点、看 LLDB 变量、启用 Main Thread Checker / Sanitizer。适合排查 `NSEvent` 键盘监听、`DispatchSource` watcher 这类时序问题。注意：SPM 可执行 target 的 SwiftUI Preview（⌥⌘↩）在这个工程里基本用不上，因为视图全靠顶层 `@State` + `@Binding` 注入（见 3.1），没有无参可预览的独立组件。

**C. 保存即重建（可选，需要 fswatch：`brew install fswatch`）**

```bash
fswatch -o Sources | while read; do ./build_and_run.sh; done
```

无热重载：Swift/SwiftUI 在命令行工具链下不支持把改动的视图注入运行中的进程，每次改动都必须重启应用。当前目录、选中的文件、滚动位置都不保留（应用本身也不落任何状态）。所以多数人用 A 的手动节奏即可，C 适合批量试错。

> Debug 产物是裸可执行文件，没有 `.app` 外壳：Dock 图标、应用名称不完整，但功能全部可用（代码里显式调了 `NSApp.setActivationPolicy(.regular)`）。要看真实图标/显示名，走 2.2。

### 2.2 打包为 `.app` / dmg

```bash
./package_app.sh
open build/DuoXplore.app      # 本地直接运行（Universal）
```

一次产出三个架构 + 三个 dmg，**全部落在 `build/`（已 gitignore，仓库根目录不再有产物）**。需要完整 Xcode，见第 7 节。

### 2.3 产物路径速查

| 构建命令 | 产物路径 |
|---|---|
| `swift build --disable-sandbox` | `.build/arm64-apple-macosx/debug/DuoXplore` |
| `swift build -c release --disable-sandbox --arch arm64` | `.build/arm64-apple-macosx/release/DuoXplore` |
| `swift build -c release --disable-sandbox --arch x86_64` | `.build/x86_64-apple-macosx/release/DuoXplore` |
| `swift build -c release --disable-sandbox --arch arm64 --arch x86_64` | `.build/apple/Products/Release/DuoXplore`（Universal） |
| `./package_app.sh` | `build/DuoXplore.app`、`build/DuoXplore_<版本>-{amd64,arm64,universal}.dmg` |

`.build/` 是 SPM 缓存 + 中间产物（已忽略，可随时 `rm -rf .build` 强制全量重编，约 60s）；`build/` 只放对外交付物，直接 `open` / 上传 Releases。两者都不进版本库。

### 2.4 手工回归清单

项目没有自动化测试，改动后按此清单点一遍（每条对应一个易碎路径）：

- [ ] 侧边栏常用位置点击后主区内容跟随；颜色标签点击后窗口标题显示标签名并列出 Spotlight 结果；点击常用位置或工具栏后退退出标签模式
- [ ] 地址栏点击变输入框 → 输入 `~/Downloads` → Enter 导航；Esc 取消
- [ ] 前进 / 后退 / 上一层 三个工具栏按钮，含边界（根目录 `/` 时「上一层」应置灰）
- [ ] 列头点击切换排序字段与方向
- [ ] 单选 / ⌘ 多选 / ⇧ 范围多选，状态栏计数与总大小
- [ ] ⌘C → 连续粘贴到两个目录；⌘X → 粘贴后剪贴板清空、半透明样式消失
- [ ] 同名冲突弹窗的三个分支：替换 / 保留两者（生成「xxx 副本」）/ 跳过
- [ ] ⌘⇧. 切换隐藏文件
- [ ] F2 内联重命名 + 非法文件名（含 `/ : * ? " < > |`）被拒绝
- [ ] 新建文件夹后自动选中
- [ ] 删除确认弹窗 → 移到废纸篓；取消时不删
- [ ] 在外部（Finder/终端）增删文件，列表自动刷新
- [ ] 「关于」窗口版本号与 `AppVersion.swift` 一致

---

## 3. 代码结构

```
Package.swift                    # SPM 可执行目标；资源只声明了 AppIcon.icns
build_and_run.sh                 # 本机架构 Debug 构建 + 重启应用
package_app.sh                   # 生成 Info.plist、组装 .app、打三个 dmg → build/
generate_icon.swift              # 用代码生成 AppIcon.icns
Sources/DuoXplore/
├── AppVersion.swift             # 版本号唯一真源（marketing + build）
├── DuoXploreApp.swift      # @main 入口：全局状态、菜单命令、关于窗口、图标注入
├── Models/
│   ├── FileItem.swift           # 文件模型（URL 派生属性、格式化展示）
│   ├── SortOptions.swift        # SortOption / SortDirection
│   └── FinderTag.swift          # Finder 系统颜色标签 + Spotlight 标签谓词
├── Services/
│   ├── FileSystemService.swift  # 全部文件操作：列目录/新建/重命名/粘贴/废纸篓/reveal/剪贴板路径
│   ├── SpotlightSearchService.swift # NSMetadataQuery：目录内搜索 / 标签全局检索
│   └── NavigationState.swift    # 前进/后退双栈
└── Views/
    ├── MainContentView.swift    # 组合面包屑 + 搜索 + 列表 + 状态栏；持有目录 watcher 与标签模式
    ├── BreadcrumbBar.swift      # 可编辑地址栏
    ├── FileListView.swift       # 表格 + 右键菜单 + 内联重命名 + NSEvent 键盘监听（最大文件）
    └── SidebarTagsView.swift    # 侧边栏常用位置 + 颜色标签（NSOutlineView source list）
```

### 3.1 状态流向（改 UI 前必读）

单一 `Window` 场景，**没有全局 store**。所有应用级状态是 `DuoXploreApp` 的 `@State`，通过 `@Binding` 逐层下传；`MainContentView` 再传给 `FileListView`：

```
DuoXploreApp (@State currentURL/files/selectedURLs/clipboard…/showHiddenFiles/activeTag/allTagsMode)
   ├─ SidebarTagsView      —— 回调 onSelect / onTagSelect：改导航或标签状态，主区随之切换
   └─ MainContentView      —— 持有 watcher / 搜索词 / 重命名与新建的局部 @State
        ├─ BreadcrumbBar   —— onNavigate 回调
        └─ FileListView    —— 排序、点击、键盘、右键菜单
```

新增一个跨视图状态：在 `DuoXploreApp` 加 `@State` → 加 `@Binding` → 菜单里用 `.commands` 注册快捷键。新增纯视图内状态：用 `@State`，不要污染顶层。

### 3.2 关键实现约定

- `@MainActor` 标注所有 `ObservableObject`（`SpotlightSearchService`、`NavigationState`），UI 更新不跨线程。
- 文件操作一律走 `FileSystemService`，不要在 View 里重复实现 CRUD / 废纸篓 / reveal / 复制路径。
- 目录监听复用 `MainContentView.startWatcher()` 的 `DispatchSource.makeFileSystemObjectSource` + `open(path, O_EVTONLY)` 模式；取消时 `close(fd)`。
- 图标：通用 UI 用 SF Symbols，真实文件图标用 `NSWorkspace.shared.icon(forFile:)`。
- `FileItem` 的 `Equatable` 只比 `url`，`id` 是每次构造的 `UUID` —— 依赖 URL 语义，不要用 `id` 做跨刷新匹配。
- 有意为之的简化（性能天花板、naive 启发式）用 `// ponytail: <ceiling> / <upgrade path>` 注释标出。

---

## 4. 版本号管理

`Sources/DuoXplore/AppVersion.swift` 是唯一真源：

```swift
enum AppVersion {
    static let marketing = "1.2.0"   // → CFBundleShortVersionString
    static let build = "5"           // → CFBundleVersion
}
```

发版时**只改这两行**：窗口标题、关于窗口、`Info.plist`（`package_app.sh` 用 grep 读取）、dmg 文件名都会同步。任何其他位置都不许硬编码版本号。

**这两个数字不会自动更新。** 仓库里没有 CI、没有构建期写版号的逻辑、也不用 `git describe` 推导 —— 迭代提交多少次，`marketing`/`build` 都停在原地，直到有人手动改。Release tag 同样要手动打，且必须与 `marketing` 一致。

约定：`marketing` 走 SemVer（新功能 / 破坏性变更递增 minor 或 major），`build` 是每次对外重打包 +1（对应 `CFBundleVersion`，同 `marketing` 下多次重传 dmg 时必须递增）。

想让 `build` 号自动化也有低成本做法（**目前未实现**，需要时再评估）：在 tag 推送后由 CI 用 `git rev-list --count HEAD` 写入 `CFBundleVersion`。但只要 `AppVersion.swift` 仍是 `marketing` 的真源，两个机制并存反而会制造不一致，所以维持手动单点修改是当前正确的选择。

---

## 5. 提交规范

```
<type>: <short description>

<optional body>
```

- `type` ∈ `feat` / `fix` / `refactor` / `docs` / `test` / `chore`（历史里也用过 `build:`，构建/打包类改动可用）。
- 不加 emoji，正文简洁专业。
- **提交信息用英文；README、Release Notes 等用户可见文案用中文。**
- 一次提交只做一件事；`docs:` 与功能改动分开。

推荐分支模型（当前仓库只有 `main`，无 CI、无 tag 保护）：

```bash
git checkout -b feat/<short-topic>     # 从 main 切出
# ...开发 + 2.4 手工回归...
git commit
git push -u origin feat/<short-topic>  # 提 PR，由维护者合并回 main
```

`.gitignore` 已忽略 `.build/`（SPM 缓存）、`build/`（全部打包产物）与 `.DS_Store`，所以 `git status` 干净即代表没误带产物。

---

## 6. 发布流程

1. 手动在 `AppVersion.swift` 递增 `marketing`（功能/破坏性变更）或 `build`（修复重打包）—— 见第 4 节，没有任何自动化会替你做这步。
2. 全量手工回归（2.4），并确认 `./package_app.sh` 跑通。
3. 提交版本号变更，合并到 `main`：`git commit -m "chore: bump version to 1.2.1"`。
4. 打 tag 并推送：

   ```bash
   git tag 1.2.1
   git push origin main 1.2.1
   ```

5. 创建 Release，上传 `build/` 下三个 dmg（`-amd64` / `-arm64` / `-universal`），Release Notes 用中文，并提示「不确定芯片选 universal」。

   ```bash
   gh release create 1.2.1 build/DuoXplore_1.2.1-*.dmg --title "1.2.1" --notes "<中文更新说明>"
   ```

6. 同步更新 `README.md` 的下载表格与版本号链接（表格里的直链含版本号，逐条替换）。

---

## 7. 常见问题

**`error: xcbuild executable at '.../xcbuild' does not exist or is not executable`**
出现于 `--arch arm64 --arch x86_64` 或 `./package_app.sh`。原因：多架构构建走 xcbuild，只装 Command Line Tools 时不存在。解决（需要管理员权限）：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

发完版如需回到 CLT 工具链：`sudo xcode-select -s /Library/Developer/CommandLineTools`。

**`zsh: permission denied: ./package_app.sh`**
两个 `.sh` 在早期提交里是 `100644`（无执行位），克隆下来直接 `./` 跑会被拒。现已改为 `100755`；若你的克隆仍报错：`chmod +x build_and_run.sh package_app.sh`，或临时用 `bash package_app.sh`。

**构建报 sandbox 相关错误 / 无法访问 `~/Documents`**
所有 `swift build` 都带 `--disable-sandbox`；本项目会读写用户真实文件系统，SPM 沙箱会拦。

**双击 dmg 里的 App 提示无法打开 / 未验证**
`package_app.sh` 不做签名与公证。本地自用：右键 → 打开，或 `xattr -dr com.apple.quarantine /Applications/DuoXplore.app`。对外分发需要补 codesign + notarytool。

**运行 Debug 二进制看不到窗口**
直接 `./build_and_run.sh`（它用 `--show-bin-path` 定位产物，不会搞错架构目录）。手动执行时注意 `arm64-apple-macosx` 与 `x86_64-apple-macosx` 要和 `uname -m` 对应。

**图标没生效**
Debug 裸二进制没有 bundle。图标来自 `package_app.sh` 组装的 `Contents/Resources/AppIcon.icns`，运行时再由 `setAppIcon()` 从 `DuoXplore_DuoXplore.bundle` 读取。

重新生成 `AppIcon.icns`（`generate_icon.swift` 只产出 iconset 里的 PNG，需 `iconutil` 转换；目录必须以 `.iconset` 结尾）：

```bash
rm -rf AppIcon.iconset
swift generate_icon.swift AppIcon.iconset
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset
```

---

## 8. 已装旧版本如何升级到新版本

没有内置自动更新（零第三方依赖 → 无 Sparkle 之类的更新框架），检查/下载/替换都得自己走一遍。好消息：这个应用**不保存任何用户状态** —— 源码里没有 `UserDefaults`、`@AppStorage`、`Application Support`、书签权限，所以覆盖安装没有数据迁移问题，也不会残留旧配置。

### 8.1 标准升级（覆盖安装，推荐）

1. 从 Releases 下载对应架构的新 dmg（不确定就选 `-universal`）。
2. 双击挂载，**先退出正在运行的旧版**（⌘Q，或右键 Dock 图标退出）。
3. 把 dmg 里的 `DuoXplore.app` 拖进 `Applications` 快捷方式，弹窗选 **「替换」**（复制和替换）。
4. 弹出旧 dmg，启动新版，用「关于 DuoXplore」窗口核对版本号。

版本号显示在关于窗口里（主窗口标题只显示应用名 `DuoXplore`，不显示版本），升级后打开「关于」即可确认生效。

### 8.2 提示「无法打开 / 已损坏」时

新下载的文件带 quarantine 属性，且本项目未做签名与公证：

```bash
# 关掉旧进程，替换后再执行
xattr -dr com.apple.quarantine /Applications/DuoXplore.app
open /Applications/DuoXplore.app
```

或右键图标 → 打开 → 再点「打开」。

### 8.3 命令行升级（开发者自用）

```bash
hdiutil attach build/DuoXplore_1.2.1-universal.dmg -nobrowse
pkill -x DuoXplore 2>/dev/null || true
rm -rf /Applications/DuoXplore.app
cp -R "/Volumes/DuoXplore/DuoXplore.app" /Applications/
hdiutil detach "/Volumes/DuoXplore"
open /Applications/DuoXplore.app
```

`/Volumes/DuoXplore` 是 dmg 的卷名（`hdiutil create -volname DuoXplore`）。删 `/Applications` 里旧副本时**务必确认路径就是 `/Applications/DuoXplore.app`**，不要写成 `/Applications/DuoXplore`（会误删整个应用的父级路径）。

### 8.4 别用 Debug 裸二进制「升级」

`.build/.../debug/DuoXplore` 没有 bundle，拖不进 `/Applications` 也不会覆盖已装的 `.app`；它只用于开发验证。要给用户/自己更新，必须走 `./package_app.sh` 产出的 dmg。

---

## 9. 测试现状与补测建议

当前 `Package.swift` 只有 `executableTarget`，**没有测试 target**，非平凡逻辑靠手工回归。

若要补测，最小改动：把可测逻辑保持在 `FileSystemService` / `Models`（这两个目录不依赖 `NSWindow`，`moveToTrash`、`pasteItems` 例外——它们弹 `NSAlert`），然后新增 `.testTarget` 与 `Tests/DuoXploreTests/`。优先覆盖：`isValidFileName`、`nextAvailableName` 的副本命名序列、`NavigationState` 的双栈行为（push 清空 forward、goBack/goForward 对称）、排序比较器。
