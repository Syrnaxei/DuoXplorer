# Spec: FTP 客户端（连接远端服务器并双向管理文件）

日期：2026-10-10
状态：已对齐（grill-with-docs 共识确认，12 项决策）
术语：见 [CONTEXT.md](../../CONTEXT.md)
架构决策：见 [ADR-0001 用系统 libcurl 实现 FTP](../adr/0001-system-libcurl-for-ftp.md)

## 1. 问题陈述

DuoXplore 目前只能浏览本机文件系统。用户要访问远端 FTP 服务器时，必须切到 Finder（只读、体验差）或另装 Cyberduck/FileZilla，工作流被打断。

本次变更让远端 FTP 服务器成为侧边栏里的**一等位置**：连上之后，它和本地目录共用同一套列表视图、面包屑、分组、排序、多选、剪贴板与右键菜单。用户在远端目录里的操作心智模型与本地完全一致——这是"文件管理器"应有的形态，而不是一个独立的传输工具窗口。

## 2. 方案概述

- **协议栈用系统 libcurl**。每台 Mac 自带 curl 8.7.1（协议含 `ftp`/`ftps`），SDK 里就有 `curl.h`。新增一个 `Ccurl` SwiftPM target（C 垫片 + `link "curl"`），不进 `Package.resolved`、不需下载、不改 `package_app.sh` 的多架构构建。
- **C 垫片是必需的**，不是可选优化：`curl_easy_setopt` 是可变参数 C 函数，Swift **无法调用**（SDK 头文件里已显式标记 unavailable）。为每个用到的选项写一个非可变参数包装函数。
- **远端位置复用现有数据模型**。远端条目 URL 写成 `ftp://host:port/path`，目录补尾斜杠——实测 `URL.hasDirectoryPath` 对 ftp scheme 有效，因此 `FileItem` 两个构造器**零改动**即可承载远端条目。`URL.isFileURL == false` 成为本地/远端的天然分派判据。
- **导航**：`NavLocation` 新增 `case remote(RemoteLocation)`，携带 `serverID` + `url`（URL 本身不含账号信息）。
- **列表解析走纯函数接缝** `FTPListingParser`：MLSD 优先，失败回退 LIST（自写 Unix + MS-DOS 双格式解析器）。
- **UI 入口**：侧边栏新增「服务器」分区（现有 `NSOutlineView` 已支持可折叠分组头）；⌘K 打开「连接服务器」窗口负责新增/编辑/删除。
- **凭据**：密码进 Keychain（`Security.framework`，系统自带），服务器元数据走现有 `UserDefaults` + `@Published`/`didSet` 模式。
- 复用而非新建：列表、分组、排序、多选、剪贴板、右键菜单、面包屑、状态栏**全部复用现有实现**，只在调用点按 `isFileURL` 分派。

## 3. 实现设计

### 3.1 接缝划分（深模块思维）

| 接缝 | 类型 | 可测性 | 说明 |
|---|---|---|---|
| `FTPListingParser` | **纯函数** | 无网络可测 | **主接缝**。`parse(Data) throws -> [RemoteEntry]` |
| `FTPPathMapper` | 纯函数 | 无网络可测 | 远端路径 ↔ `ftp://` URL ↔ curl 参数 |
| `FTPStore` | Codable + UserDefaults | 可测 | 服务器条目增删改查与持久化 |
| `FTPSession` | 有状态，持 curl handle | 需真服务器 | 尽量薄，逻辑上推到纯函数接缝 |
| `RemoteFileService` | async 门面 | 需真服务器 | 方法名与 `FileSystemService` 对齐，便于调用点分派 |

设计原则：**把逻辑从有状态的 `FTPSession` 里挤出去，塞进纯函数接缝**。解析、路径映射、能力协商判定全部无副作用，可用 fixture 断言；`FTPSession` 只剩"设选项 → perform → 收字节"。

### 3.2 C 垫片（`Sources/Ccurl/`）

```
Sources/Ccurl/module.modulemap   module Ccurl { header "shim.h" ... }
Sources/Ccurl/shim.h             包装函数声明
Sources/Ccurl/shim.c             非可变参数包装实现
```

`Package.swift` 用 `.target`（不是 `.systemLibrary`，因为要编译 `shim.c`）：

```swift
.target(name: "Ccurl", path: "Sources/Ccurl",
        publicHeadersPath: ".",
        linkerSettings: [.linkedLibrary("curl")])
```

需要包装的选项（约 22 个）。命名统一 `ccurl_set_*`，返回 `CURLcode` 供调用方断言：

| 用途 | 选项 |
|---|---|
| 目标 | `CURLOPT_URL` |
| 认证 | `CURLOPT_USERPWD` |
| 超时 | `CURLOPT_CONNECTTIMEOUT`、`CURLOPT_LOW_SPEED_LIMIT`、`CURLOPT_LOW_SPEED_TIME` |
| 下行 | `CURLOPT_WRITEFUNCTION` + `CURLOPT_WRITEDATA` |
| 上行 | `CURLOPT_READFUNCTION` + `CURLOPT_READDATA` + `CURLOPT_INFILESIZE_LARGE` + `CURLOPT_UPLOAD` |
| 命令 | `CURLOPT_QUOTE`、`CURLOPT_POSTQUOTE`（`curl_slist`）、`CURLOPT_CUSTOMREQUEST`（MLSD） |
| 列表 | `CURLOPT_DIRLISTONLY` |
| 加密 | `CURLOPT_USE_SSL`、`CURLOPT_SSL_VERIFYPEER`、`CURLOPT_SSL_VERIFYHOST` |
| 模式 | `CURLOPT_FTPPORT`（`NULL` = 被动，`"-"` = 主动）、`CURLOPT_FTP_SKIP_PASV_IP`、`CURLOPT_FTP_CREATE_MISSING_DIRS` |
| 保活 | `CURLOPT_TCP_KEEPALIVE`、`CURLOPT_TCP_KEEPIDLE`、`CURLOPT_FORBID_REUSE` |
| 进度/取消 | `CURLOPT_XFERINFOFUNCTION` + `CURLOPT_XFERINFODATA` |
| 诊断 | `CURLOPT_ERRORBUFFER` |

直接暴露不需包装的：`curl_global_init`、`curl_easy_init/cleanup/perform/strerror`、`curl_slist_append/free`、`curl_version`。

> `curl_global_init` 必须在任何 easy handle 之前调用一次，放 `DuoXploreApp.init` 或 `FTPClient` 的 `static let shared` 惰性初始化里。它**非线程安全**，只能调一次。

### 3.3 并发模型（Swift 6 严格并发下的关键点）

`curl_easy_perform` **阻塞**，且 `UnsafeMutablePointer<CURL>` 不是 `Sendable`。

```
FTPSession: final class, @unchecked Sendable
  ├── 独占一个 CURL handle
  ├── 所有 curl 调用派发到自己的串行 DispatchQueue（handle 不跨线程共享）
  └── 对外 API 全部 async，用 withCheckedThrowingContinuation 桥接
```

- **进度回调**在 curl 的工作线程上触发，发布到 UI 必须 `MainActor.assumeIsolated` 之外的安全跳转：用 `Task { @MainActor in ... }` 并节流（≥100ms 一次），否则大文件传输会把主线程刷爆。
- **取消**：一个 `OSAllocatedUnfairLock<Bool>`（或 `Atomic`）标志位，`XFERINFOFUNCTION` 读到 true 就返回非 0，curl 以 `CURLE_ABORTED_BY_CALLBACK`(42) 结束。这是 libcurl 唯一的取消机制，不要试图从别的线程 `curl_easy_cleanup`。
- **一个服务器一个 session**，session 内串行。多服务器可并行（各自的队列）。

### 3.4 连接生命周期

常驻 handle，靠 libcurl 内置连接缓存复用 TCP/TLS。开 `CURLOPT_TCP_KEEPALIVE`（idle 60s / interval 30s）。

失败透明重连**一次**：

```
perform → 失败
  ├─ 错误码 ∈ 连接类 {6 COULDNT_RESOLVE_HOST, 7 COULDNT_CONNECT, 28 TIMEOUT,
  │                  52 GOT_NOTHING, 55 SEND_ERROR, 56 RECV_ERROR, 18 PARTIAL_FILE}
  │   → curl_easy_cleanup + 重建 handle + 重试一次
  └─ 其他错误码（21 QUOTE_ERROR、9 ACCESS_DENIED、55...）→ 直接抛给用户，不重试
```

`ponytail:` 重连只做一次、只认白名单错误码——不做指数退避、不做无限重试，避免在服务器真挂时卡住 UI。升级路径：若后续出现频繁半开连接，再加 `CURLOPT_FORBID_REUSE` 强制新建。

### 3.5 目录列表：MLSD 优先 + LIST 回退

```
listDirectory(path):
  1. 若本 session 未记录能力：试 MLSD
  2. MLSD 成功 → 缓存「支持 MLSD」，用 MLSD 解析
  3. MLSD 失败且错误码 ∈ {21 QUOTE_ERROR, 18 COULDNT_RETR_FILE, 501 语法} →
     缓存「不支持 MLSD」，改用 LIST
  4. 后续调用直接走缓存结论，不再试探
```

**MLSD**：`CURLOPT_CUSTOMREQUEST = "MLSD"` + URL 指向目录（libcurl 仍会开数据连接）。响应格式 `facts; filename`，如：

```
type=file;size=1024;modify=20261010153000;unix.mode=0644  report.pdf
type=dir;modify=20260101000000  pub
type=cdir;modify=...  .
type=pdir;modify=...  ..
```

解析要点：facts 用 `;` 分隔且**值内不含分号**，但**文件名可含分号**——所以只 split 第一个空格前的部分；`type=cdir`/`pdir` 必须丢弃；`modify` 是 UTC 的 `YYYYMMDDHHMMSS`（可能带 `.sss` 小数），必须按 UTC 解析再转本地时区。

**LIST 回退**：自写解析器，两种格式。

Unix（`-rw-r--r--   1 owner group   1024 Oct 10 15:30 name`）：
- 首字符 `d` = 目录，`l` = 符号链接（取 `->` 后的目标名判定，或直接当文件）
- 字段 5 = size，字段 6-8 = 日期
- **日期歧义**（FTP 经典坑）：第 8 字段含 `:` 则是「月 日 时:分」且**年份未给**——按"若该日期在未来 6 个月内则取去年，否则取今年"推断；不含 `:` 则是「月 日 年」。
- 文件名从第 9 字段起，**可能含空格**，所以是 join 剩余全部字段而非取 index 8。

MS-DOS（`10-10-26  03:30PM       <DIR>          pub`）：
- 字段 3 是 `<DIR>` 或字节数
- 日期 `MM-DD-YY`，两位年份按 <70 → 20xx，≥70 → 19xx

无法解析的行**跳过并计数**，不整批失败——半损坏的列表好过空白列表。若跳过率 > 50%，向 UI 报错。

### 3.6 远端操作 → curl 命令映射

| 操作 | 实现 |
|---|---|
| 列目录 | MLSD / LIST（见 3.5） |
| 下载 | `RETR`，`CURLOPT_URL` 指向文件 + write callback 落盘 |
| 上传 | `STOR`，`CURLOPT_UPLOAD` + read callback 从本地文件读 |
| 删除文件 | `CURLOPT_QUOTE` = `["DELE /path/file"]` |
| 删除目录 | `CURLOPT_QUOTE` = `["RMD /path/dir"]`（非递归，非空会失败） |
| 新建目录 | `CURLOPT_QUOTE` = `["MKD /path/newdir"]` |
| 重命名/移动 | `CURLOPT_QUOTE` = `["RNFR /old", "RNTO /new"]`（顺序敏感，必须同一 slist） |
| 取大小 | `CURLOPT_QUOTE` = `["SIZE /path"]`（MLSD 已含时不必） |

`QUOTE` 命令用 `ftp://host/` 作 URL（不触发传输，只跑命令）。所有远端路径**必须是绝对路径**——libcurl 用 `CWD` 处理相对路径时会受上次工作目录影响，绝对路径消除这个隐式状态。

### 3.7 加密与证书豁免

⌘K 窗口一个「加密」下拉：

| 选项 | curl 配置 |
|---|---|
| 无（明文 FTP） | scheme `ftp://`，`USE_SSL = NONE` |
| 显式 TLS（AUTH TLS） | scheme `ftp://`，`USE_SSL = ALL`（控制+数据连接都加密） |
| 隐式 TLS（端口 990） | scheme `ftps://` |

证书默认严格校验（`VERIFYPEER=1`、`VERIFYHOST=2`）。校验失败（错误码 60 `SSL_CACERT` / 51 `PEER_FAILED_VERIFICATION`）时：

1. 弹出证书详情对话框（主机名、颁发者、有效期、指纹）
2. 用户选「仍要连接」→ 该 `serverID` 记入豁免名单（UserDefaults）
3. 重试时对该服务器 `VERIFYPEER=0`、`VERIFYHOST=0`
4. 侧边栏该服务器图标加一个警示角标，右键菜单可「撤销证书豁免」

豁免是**按服务器**的，不是全局开关——避免一次妥协削弱所有连接。

### 3.8 导航与状态接入

`MainContentView` 的真实状态是 `currentURL: URL` + `activeTag`（`NavLocation` 只是派生量）。接入方式：

```swift
struct RemoteLocation: Equatable, Hashable {
    let serverID: UUID
    let url: URL          // ftp://host:port/path，目录带尾斜杠
}

enum NavLocation: Equatable {
    case folder(URL)
    case tag(FinderTag)
    case remote(RemoteLocation)   // 新增
}
```

- `DuoXploreApp` 新增 `@State private var currentServerID: UUID?`。`currentURL` 仍是唯一的路径来源，`currentServerID != nil` ⟺ 远端模式。
- **判据统一用 `currentURL.isFileURL`**（实测 ftp URL 恒为 false），不要引入第二个布尔量——两个真相源迟早会不一致。
- 远端根 URL 必须写成 `ftp://host/`（带尾斜杠）。实测 `ftp://host`（无斜杠）的 `path` 是空串、`lastPathComponent` 也是空串，会让窗口标题和面包屑双双失效。
- `windowTitle` 在远端根目录时 `lastPathComponent` 为 `/`，需特判显示服务器名。

**已知坑（必须处理）**：

1. `MainContentView.startWatcher()`（:353-380）用 `open(currentURL.path, O_EVTONLY)`。远端 URL 的 `.path` 是 `/pub/dir` 这样的**本地合法路径**，若本机恰好存在同名目录，就会误监听本地目录并触发错误刷新。**必须在远端模式下直接 `return`**，不做监听。
2. `BreadcrumbBar.pathComponents`（:17-26）硬编码根节点 `"Macintosh HD"`（:24），且 `crumbClicked` 用 `URL(fileURLWithPath:)` 重建（:210）——远端路径点一下就**变成本地 URL**，直接跳到本机文件系统。必须让面包屑感知 scheme：根节点显示服务器名，重建 URL 时保留 scheme+host+port。
3. `BreadcrumbBar.commitEdit/commitOnBlur`（:78-110）用 `FileManager.fileExists` 验证路径，远端永远 false → 编辑态提交静默失败。远端模式下**禁用路径编辑**（点空白不进入编辑态），第一版不做远端路径直输。
4. `MainContentView.navigate(to:)` 与"向上一层"按钮：实测远端根 `ftp://host/` 调 `deletingLastPathComponent()` 得到 `ftp://host/../`（垃圾）。现有 `currentURL.path == "/"` 守卫（:114）**刚好挡住**这种情况，但依赖是隐式的——在该守卫处加注释说明它也承担远端根的职责，防止后人"优化"掉。
5. `SpotlightSearchService.search(text:in:)` 传 ftp URL 作搜索 scope 会让 `NSMetadataQuery` 失败。远端模式**不启动 Spotlight**，直接走已有的内存过滤回退闭包（`MainContentView.swift:83` 那个 `files.filter`）。

### 3.9 调用点分派

`fsService` 现有 22 处调用，去重后约 10 个不同操作。其中 5 个在远端**无意义**，而右键菜单本就是动态构建的（`FileListView.swift:323-355`），远端模式下直接不生成：

| 操作 | 远端行为 |
|---|---|
| `listDirectory` | → `RemoteFileService.listDirectory` |
| `pasteItems` | → 本地→远端上传 / 远端→本地下载 / 远端→远端 `RNFR`+`RNTO` |
| `moveToTrash` | → `DELE`/`RMD`（**远端无废纸篓**，确认弹窗文案必须改成"永久删除"） |
| `renameItem` | → `RNFR`+`RNTO` |
| `createFolder` | → `MKD` |
| `openFile` | → 下载到临时目录后用 `NSWorkspace.open` |
| `copyPath` | → 复制 `ftp://host/path` 字符串 |
| `isValidFileName` | 复用（纯字符串校验，与文件系统无关） |
| `openInTerminal` / `openInFinder` / `revealInFinder` / `writeTags` | **菜单不生成** |

分派点集中在两处：`DuoXploreApp` 的菜单命令（:92-99、:278-293）与 `FileListView` 的动作入口。每处一个 `if url.isFileURL { ... } else { ... }`，**不引入协议抽象**——`moveToTrash`/`pasteItems` 把 `NSAlert` 弹窗和逻辑揉在一起，套不进统一协议；且 FTP 必须 async 而本地是同步，协议会被迫全部 async 化，连累本地路径。

### 3.10 存储

```swift
struct FTPServer: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String          // 侧边栏显示名
    var host: String
    var port: Int             // 默认 21，隐式 TLS 默认 990
    var username: String      // 匿名时为空串，连接时发 "anonymous"
    var isAnonymous: Bool
    var encryption: Encryption   // none / explicitTLS / implicitTLS
    var initialPath: String      // 登录后 CWD 的起始目录，默认 "/"
    var useActiveMode: Bool      // 默认 false（被动）
    var trustInvalidCertificate: Bool
}
```

- 元数据数组 JSON 编码后存 `UserDefaults`，沿用 `AppSettingsModel` 的 `@Published` + `didSet` 模式（`SettingsWindow.swift:7-32`）。
- 密码存 Keychain：`kSecClassGenericPassword`，`kSecAttrService = "top.struct.duoxplore.ftp"`，`kSecAttrAccount = serverID.uuidString`。用 `kSecAttrAccessibleAfterFirstUnlock`。
- 匿名服务器不写 Keychain 条目。
- 删除服务器时**必须同时删 Keychain 条目**，否则残留孤儿密码。

> **未签名的后果**：本项目 `package_app.sh` 无 codesign 步骤，每次重新构建 cdhash 变化，Keychain 会弹一次"XXX 想要使用您钥匙串中的机密信息"。发布版 cdhash 稳定后不再弹。这是可接受的，但**必须在 README 里写明**，否则用户会以为是 bug。

### 3.11 传输进度

- 状态栏（`MainContentView.statusBar`，:314-335）右侧新增传输指示：文件名 + 百分比 + 取消按钮。
- 进度来自 `XFERINFOFUNCTION`（已下载的 dltotal/dlnow 或上传的 ultotal/ulnow），节流 ≥100ms 后跳主线程。
- 多文件传输串行执行（队列已在"明确不做"里排除），进度显示"第 i/N 个：文件名"。
- 取消单个传输 = 中止整个批次，并提示已完成的文件不会回滚。

### 3.12 拖拽

- **本地 → 远端**（拖入上传）：`FileListView` 已有 drop 目标处理（:913 附近），远端模式下把 `fsService.pasteItems` 换成 `RemoteFileService.upload`。
- **远端 → 本地**（拖出）：第一版**不做**。需要 `NSFilePromiseProvider`，其 promise 回调与 curl 异步传输的编排极易死锁，工作量约等于整个传输层重做。

## 4. 用户故事

### 连接与服务器管理

1. 按 ⌘K 打开「连接服务器」窗口，字段：名称、服务器地址、端口、加密（无/显式 TLS/隐式 TLS）、匿名开关、用户名、密码、初始目录、被动/主动模式。
2. 勾选「匿名」时用户名固定为 `anonymous`、密码框禁用并置灰。
3. 端口随加密方式联动默认值：无/显式 TLS → 21，隐式 TLS → 990；用户手动改过端口后不再联动。
4. 点「连接」：先建 session 并跑一次列目录作为连通性探测；成功则关闭窗口、侧边栏该服务器变为已连接态、主视图切到远端根目录。
5. 连接失败时在窗口内就地显示错误（不弹独立 alert），错误文案按 curl 错误码翻译成人话：无法解析主机名 / 连接被拒绝 / 认证失败 / TLS 握手失败 / 超时。
6. TLS 证书校验失败时弹出证书详情（主机名、颁发者、有效期、SHA-256 指纹），提供「取消」与「仍要连接」；选后者则记住该服务器的豁免并成功连接。
7. 已保存的服务器出现在侧边栏「服务器」分区，未连接显示灰色地球图标，已连接显示彩色图标 + 名称。
8. 单击侧边栏服务器条目：未连接则用保存的凭据静默连接（密码从 Keychain 取，不弹窗）；已连接则跳到其根目录。
9. 静默连接失败时弹一次认证/错误对话框，允许就地改密码重试。
10. 右键侧边栏服务器条目：连接 / 断开 / 编辑… / 复制地址 / 撤销证书豁免（仅豁免过的显示）/ 删除。
11. 删除服务器弹确认，确认后同时删除 UserDefaults 元数据与 Keychain 密码；若当前正浏览该服务器，主视图回退到本地个人目录。
12. 「服务器」分区可折叠，折叠状态与现有「常用位置」「置顶标签」分区一致地持久化。
13. 没有已保存服务器时，分区仍显示，但内容为空并给一行提示「⌘K 添加服务器」。

### 浏览

14. 连接后主视图显示远端根目录（或服务器配置的初始目录）列表，列与本地一致：名称、修改日期、大小、种类。
15. 远端目录条目的名称列显示真实文件图标（`NSWorkspace.icon(forFile:)` 对 ftp URL 无效，回退到按扩展名取 `NSWorkspace.icon(forFileType:)`），文件夹用系统文件夹图标。
16. 双击远端目录进入，面包屑更新为「服务器名 › pub › dir」。
17. 面包屑每一段可点击跳转到对应远端层级；根段显示服务器名而非「Macintosh HD」。
18. 远端模式下面包屑**不进入路径编辑态**（点空白无反应）。
19. 窗口标题在远端根目录显示服务器名，在子目录显示目录名。
20. 「向上一层」在远端根目录置灰；在子目录正常回上一层。
21. 前进/后退历史混合记录本地目录、颜色标签与远端位置，跨类型来回切换正常。
22. ⌘R（或菜单「刷新」）重新列当前远端目录；每次改动（上传/删除/重命名/新建）后自动重列。
23. 远端模式不启动目录监听，也不启动 Spotlight 查询。
24. 搜索框在远端模式下对**已加载的当前目录条目**做内存过滤（不递归、不联网）；清空即恢复。
25. 分组下拉在远端只显示可用维度：无 / 名称 / 种类 / 修改日期 / 创建日期 / 大小；「标签」「添加日期」「上次打开日期」「应用程序」不出现。
26. 列头排序在远端可用维度上正常工作（名称/种类/大小/修改日期）。
27. 「显示隐藏项目」（⇧⌘.）在远端生效：控制是否显示以 `.` 开头的条目（远端隐藏判定只看名字前缀，不看 mode 位）。
28. 状态栏显示「N 个项目」，远端与本地一致。

### 传输

29. 选中远端文件后菜单/⌘C 复制，切到本地目录 ⌘V → 下载到该本地目录；同名冲突时弹与本地一致的「替换 / 保留两者 / 跳过」对话框。
30. 选中本地文件 ⌘C，切到远端目录 ⌘V → 上传；同名冲突弹「替换 / 保留两者 / 跳过」；替换时先 `DELE` 再 `STOR`。
31. 远端目录内 ⌘C + ⌘V → 服务器内复制（`RNFR`+`RNTO` 到同目录新名，或先下载再上传，实现取简者并在代码里注明）。
32. 双击远端文件 → 下载到临时目录（`FileManager.temporaryDirectory` 下按 serverID 分子目录）并用默认应用打开；重复打开同一文件时若已缓存且大小/修改时间未变则直接用缓存。
33. 传输进行时状态栏右侧显示：文件名、百分比进度条、取消按钮。
34. 多文件传输串行执行，进度显示「第 i/N 个：文件名」。
35. 点取消立即中止当前传输与整个批次，已完成的部分不回滚，列表刷新以反映实际状态。
36. 传输过程中主界面保持可响应（可切换目录、可操作其他服务器）；切换目录不中止进行中的传输。
37. 本地文件拖入远端目录列表 → 上传，落点有高亮反馈，行为与 ⌘V 上传一致。
38. 上传/下载失败的单个文件不中止批次，失败项收集后在批次结束时一次性汇报（文件名 + 原因）。

### 远端改动

39. 远端空白区右键菜单：新建文件夹 / 粘贴 / 刷新 / 显示隐藏项目 / 分组方式子菜单。**不含**「在终端中打开」「在 Finder 中打开」。
40. 远端选中项右键菜单：打开 / 下载 / 复制 / 剪切 / 重命名 / 复制路径 / 删除。**不含**「在 Finder 中显示」「编辑标签」。
41. 新建文件夹：内联编辑框（复用现有 `FileListView` 重命名/新建的编辑态），提交后 `MKD` 并刷新；重名时显示服务器返回的错误。
42. 重命名：内联编辑框，提交后 `RNFR`+`RNTO`；文件名合法性校验复用 `isValidFileName`。
43. 删除：确认弹窗文案为「**永久删除**」（不是"移到废纸篓"），明确告知不可恢复；确认后 `DELE`（文件）/`RMD`（目录）。
44. 删除非空目录时服务器返回失败，弹窗显示「目录非空，无法删除」，不做递归删除。
45. 「复制路径」复制完整 `ftp://host:port/path` 字符串（不含用户名密码）。
46. 断开连接后，若当前正浏览该服务器的目录，主视图回退到本地个人目录并清空前进栈中的该服务器条目。

### 断开与异常

47. 网络中断时操作失败，显示可理解的错误并保留 session（下次操作触发透明重连）。
48. 空闲后被 NAT/防火墙掐断连接：下一次操作自动重连成功，用户无感知（最多看到一次略长的等待）。
49. 透明重连只尝试一次；仍失败则报错并提示「连接已断开，请重新连接」。
50. 服务器返回 550（权限拒绝）时显示「服务器拒绝该操作：权限不足」，不重试。
51. 应用退出时清理所有 curl handle 与临时下载目录中已完成打开的文件。

## 5. 已定决策

- **客户端，不是服务端**。不做本机 FTP 服务器（macOS 系统设置的「文件共享」已提供，且监听端口 + 鉴权 + 被动端口池的安全面过大）。
- **传输层 = 系统 libcurl + 自写 C 垫片**。已实测：SwiftPM `.target` + `linkerSettings: [.linkedLibrary("curl")]` 编译链接通过。**不用**远程 SwiftPM 包，**不**手写 FTP 协议，**不**用 `URLSession` 的 `ftp://`（系统只支持下载，无法 LIST/上传/改名），**不**用已废弃的 `CFFTPCreateParsedResourceListing`（自 macOS 10.11 废弃，且只认 Unix 格式）。
- **范围 = 完整双向**：浏览 + 下载 + 上传 + 删除 + 新建文件夹 + 重命名。
- **入口 = 侧边栏「服务器」分区 + ⌘K 连接窗口**。
- **凭据 = 密码进 Keychain，元数据进 UserDefaults**。不做全明文，也不做"每次手输密码"。
- **数据模型 = 复用 `FileItem`**（用其不探测文件系统的显式构造器，`FileItem.swift:42`）+ **`NavLocation` 加 `case remote`**。不抽 `FileItemProtocol`——`FileListView.swift` 1014 行里几十处用法全要改，SwiftUI + existential 还有 Equatable/性能麻烦。
- **目录 URL 必须带尾斜杠**，靠 `URL.hasDirectoryPath` 让 `isDirectory` 正确（实测确认对 ftp scheme 有效）。
- **分派 = 调用点 `if url.isFileURL` + 远端隐藏无关菜单项**。不抽 `FileOperationProviding` 协议。
- **列表 = MLSD 优先 + LIST 回退**，自写解析器（Unix + MS-DOS）。不用 NLST（会丢掉大小/日期两列）。
- **加密 = 明文 + 显式 TLS + 隐式 TLS**，证书默认严格校验、失败可**按服务器**豁免。不做"全局不校验证书"。
- **连接 = 常驻 handle + 失败透明重连一次**。不做无状态每操作一连（FTPS 下 200-500ms 握手会让浏览卡顿），也不自建心跳保活状态机（libcurl 连接缓存 + `TCP_KEEPALIVE` 已覆盖大部分）。
- **传输交互 = 状态栏进度条 + 菜单/剪贴板 + 本地拖入上传**。
- **降级 = 分组排序按可用维度裁剪，搜索退为内存过滤，⌘R 手动刷新**。
- 传输**串行**，不做并发队列。

## 6. 明确不做

- **不做 FTP 服务端**（本机对外共享）。
- **不做 SFTP / SCP**。事实依据：系统 curl 8.7.1 的协议列表为 `dict file ftp ftps gopher gophers http https imap imaps ipfs ipns ldap ldaps mqtt pop3 pop3s rtsp smb smbs smtp smtps telnet tftp`——**不含 `sftp`/`scp`**（需 libssh2，苹果没链接进来）。要支持就得捆绑 libssh2，那才是真正的第三方依赖。
- **不做远端拖出**（`NSFilePromiseProvider`）。
- **不做传输队列面板 / 暂停继续 / REST 断点续传**。`CURLOPT_RESUME_FROM_LARGE` 的垫片包装可以顺手留着，但不接线。
- **不做远端递归删除**。
- **不做远端路径直接输入**（面包屑编辑态在远端禁用）。
- **不做远端颜色标签 / Spotlight 标签搜索 / 添加日期 / 上次打开日期 / 应用程序分组**——这些依赖本地 xattr 与 Spotlight 索引，远端根本不存在。
- **不做多窗口分别连不同服务器**、不做服务器间直接对传（FXP）。
- **不做代理配置**。FTP 被动模式天然与代理不友好，`CURLOPT_PROXY` 不接线。
- **不做 WebDAV / SMB / NFS** 等其他远端协议。

## 7. 测试决策

**主接缝：`FTPListingParser`（纯函数，无网络）**

一个断言式自检文件，用内联 fixture 字符串覆盖：

- MLSD：`type=file`/`type=dir` 正确映射 `isDirectory`；`size` 解析为 `Int64`；`modify=20261010153000` 按 **UTC** 解析；`type=cdir`/`pdir` 被丢弃；文件名含分号（`a;b.txt`）不被截断；文件名含空格保留完整。
- LIST Unix：普通文件、目录（`d` 开头）、符号链接（`l` 开头）；文件名含空格（`my report.pdf` 必须整体作为一个名字）；日期含 `:` 时的年份推断（未来 6 个月内 → 去年）；日期不含 `:` 时取显式年份。
- LIST MS-DOS：`<DIR>` 标记 → 目录；两位年份 26 → 2026、99 → 1999；12 小时制 `03:30PM` 正确转 15:30。
- 混合/损坏输入：无法解析的行被跳过而非抛错；全损坏输入抛错；跳过率 >50% 抛错。
- 格式自动识别：同一段数据分别按 MLSD 与 LIST 解析，结果一致。

**次接缝：`FTPPathMapper`（纯函数）**

- 远端路径 → `ftp://` URL：目录补尾斜杠、文件不补；空格与中文正确百分号编码（用 `appendingPathComponent`，不用字符串拼接）。
- `ftp://` URL → 远端绝对路径：始终绝对、始终以 `/` 开头。
- 根路径 `/` 的往返一致性。
- `deletingLastPathComponent()` 在远端根的行为断言（记录 `ftp://host/../` 这个已知陷阱，确保调用方守卫存在）。

**第三接缝：`FTPStore`**

- Codable 往返；UserDefaults 读写；删除服务器时 Keychain 条目一并清除（用 mock/临时 service name 验证）。

**集成验证（需真服务器，由用户手动执行）**

交付时给出：
1. 起本地测试服务器的命令（`docker run -d -p 21:21 -p 21000-21100:21000-21100 -e USERS="test|test" delfer/alpine-ftp-server`，或 `brew install pure-ftpd`）
2. `./build_and_run.sh`
3. 逐条验证清单，覆盖用户故事 1-51 中的关键路径，每条写清预期现象
4. 预期日志（连接、MLSD/LIST 能力协商结论、重连触发）

`ponytail` 规则：纯函数接缝留一个可运行 check，不引测试框架、不加 fixture 文件（fixture 内联在自检文件里）。UI 层由用户手动验证。

## 8. 补充说明

### 8.1 参考项目的取舍来源

- **lftp**：MLSD 优先、LIST 回退的策略；LIST 日期年份推断规则；被动模式为默认。
- **FileZilla**：证书不受信任时按站点记住豁免；明文密码存储是它的**已知弱点**，本项目改用 Keychain 正是为了避开这一点。
- **Cyberduck**：连接失败就地显示错误而非独立弹窗；传输进度内嵌主窗口而非浮动窗。
- **curl 官方文档**：`CURLOPT_QUOTE` 跑 `MKD`/`RNFR`/`RNTO`/`DELE`；`CURLOPT_CUSTOMREQUEST` 跑 MLSD；`XFERINFOFUNCTION` 返回非 0 是唯一取消手段。

### 8.2 需要在实现时同步修正的文档

- `AGENTS.md` 第 30 行「no user state (no `UserDefaults` / Application Support)」**已经过时**——`AppSettingsModel` 早已在用 UserDefaults（`SettingsWindow.swift:13-31`）。本次变更引入 Keychain 后更需修正。
- `AGENTS.md`「Packages: none (zero third-party deps...)」需加注：仍无远程 SwiftPM 包，但链接系统 libcurl。
- `README.md` 需新增 FTP 功能说明与**未签名导致的 Keychain 弹窗**提示。
- `AboutView`（`DuoXploreApp.swift:21`）的功能描述文案提到"树形侧边栏"，而侧边栏树早已被移除——顺手修正。

### 8.3 版本号

`Sources/DuoXplore/AppVersion.swift` 是唯一真相源。当前 1.3.9 (15)。FTP 是新增功能而非补丁，建议 → **1.4.0 (16)**。手动改，与 release tag 同步。

### 8.4 工作量粗估

| 模块 | 规模 |
|---|---|
| `Ccurl` C 垫片 | ~200 行 C |
| `FTPListingParser` | ~250 行 Swift（含两种 LIST 格式） |
| `FTPPathMapper` | ~60 行 |
| `FTPSession` + `FTPClient` | ~300 行 |
| `RemoteFileService` | ~200 行 |
| `FTPStore` + Keychain | ~150 行 |
| ⌘K 连接窗口 | ~250 行（AppKit，仿现有 `SettingsWindowController`） |
| 侧边栏服务器分区 | ~120 行（改 `SidebarTagsView`） |
| 现有文件接入改造 | ~200 行分散改动（`MainContentView`、`BreadcrumbBar`、`FileListView`、`DuoXploreApp`） |
| 自检文件 | ~200 行 |
| **合计** | **~1900 行 + 200 行 C** |

对现有 3560 行的代码库，这是约 55% 的增量——是本仓库迄今最大的一次功能变更，建议按 `to-tickets` 拆成垂直切片分阶段落地，第一片做到"能连上 + 能列目录"即可验证整条 libcurl 集成路径。
