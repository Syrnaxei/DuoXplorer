import Foundation

/// 文件/文件夹的数据模型
struct FileItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modificationDate: Date?
    let fileExtension: String

    init(url: URL) {
        self.url = url
        self.name = url.lastPathComponent
        self.isDirectory = url.hasDirectoryPath

        let resourceValues = try? url.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .isDirectoryKey
        ])

        self.size = resourceValues?.fileSize.map(Int64.init)
        self.modificationDate = resourceValues?.contentModificationDate
        self.fileExtension = url.pathExtension
    }

    // DateFormatter/ByteCountFormatter 创建开销大，列表每行每帧都会调用，必须缓存复用；
    // 仅在主线程（视图渲染）使用
    @MainActor private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
    @MainActor private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    /// 格式化文件大小
    @MainActor var formattedSize: String {
        guard let size = size, !isDirectory else { return "--" }
        return Self.byteFormatter.string(fromByteCount: size)
    }

    /// 格式化修改日期
    @MainActor var formattedDate: String {
        guard let date = modificationDate else { return "--" }
        return Self.dateFormatter.string(from: date)
    }

    /// 文件类型描述
    var fileTypeDisplay: String {
        if isDirectory { return "文件夹" }
        if fileExtension.isEmpty { return "文件" }
        return fileExtension.uppercased() + " 文件"
    }

    /// Finder 文件类型标签 (UTI)
    var utiType: String {
        if isDirectory { return "public.folder" }
        return (try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier) ?? "public.data"
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url
    }
}
