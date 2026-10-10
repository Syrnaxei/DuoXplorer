# 用系统 libcurl + C 垫片实现 FTP，而不是手写协议或引远程包

状态：accepted（2026-10-10）

DuoXplore 要加 FTP 客户端，而 `AGENTS.md` 写着「零第三方依赖」。我们决定链接 macOS **自带**的 libcurl（curl 8.7.1，SDK 里就有 `curl.h`，`Package.swift` 加一个编译 ~200 行 C 垫片的 `.target` + `linkerSettings: [.linkedLibrary("curl")]`）。理由：那条铁律针对的是**远程 SwiftPM 包**（会进 `Package.resolved`、破坏离线构建、拖累多架构打包），而 libcurl 属于"平台已提供的能力"——正好是 AGENTS.md 依赖阶梯的第 4 级（原生平台特性）。协议健壮性由 curl 二十年打磨保证：被动/主动模式、EPSV、显式/隐式 TLS、超时、连接缓存全部现成。

## 备选方案

- **手写 FTP over `URLSessionStreamTask`**（真·零依赖，~600-900 行 Swift）：全可控，但 NAT 下的被动模式、EPSV 回退、`UTF8` 选项、MLSD/LIST 差异、REST 续传这些边界全要自己踩。健壮性风险最高，且 FTP 的错误只会在用户的某个特定服务器上暴露。
- **`URLSession` 原生 `ftp://` 支持**：系统只支持下载，无法列目录、上传、改名、删除。做不了文件管理器。
- **CFNetwork 的 `CFFTPCreateParsedResourceListing`**：符号仍在，但自 macOS 10.11 起 `CF_DEPRECATED`，随时可能移除；且只解析 Unix 格式 LIST，Windows 服务器全部失败。
- **远程 SwiftPM 包**：目前没有成熟的纯 Swift FTP 客户端库，大概率要拉 swift-nio 全家桶自己实现协议——依赖体量远大于收益，且真的违反铁律。

## 后果

- **`curl_easy_setopt` 是可变参数 C 函数，Swift 无法调用**（SDK 头文件已显式标记 unavailable）。所以 C 垫片不是可选优化，是硬性前提：每个用到的 `CURLOPT` 都要一个非可变参数包装函数，约 22 个。这是"纯 Swift 项目里为什么有 C 代码"的答案。
- `curl_easy_perform` **阻塞**，且 curl handle 非线程安全。`FTPSession` 必须独占一个串行队列并标 `@unchecked Sendable`，对外只暴露 async API。
- libcurl 的 easy handle **自带连接缓存**——只要 handle 活着就复用 TCP/TLS 连接，不需要自建连接池。
- 系统 curl **不含 `sftp`/`scp`**（未链接 libssh2）。SFTP 永久排除在本方案外，除非将来愿意捆绑 libssh2（那才是真正的第三方依赖）。
- 隐式 TLS 走 `ftps://` scheme，显式 TLS 走 `CURLOPT_USE_SSL`——两者都不需要额外依赖。
- `AGENTS.md` 的「Packages: none」需加注：仍无远程包，但链接系统 libcurl。
