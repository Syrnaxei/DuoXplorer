import Foundation
import UniformTypeIdentifiers

/// 分组维度（与 Finder「分组方式」菜单一致）
enum GroupDimension: String, CaseIterable, Identifiable {
    case none = "无"
    case name = "名称"
    case kind = "种类"
    case application = "应用程序"
    case lastOpened = "上次打开日期"
    case added = "添加日期"
    case modified = "修改日期"
    case created = "创建日期"
    case size = "大小"
    case tag = "标签"

    var id: String { rawValue }
}

/// 一个分组：标题行展示 title（含项目数由渲染层取 items.count）
struct FileGroup {
    let title: String
    let items: [FileItem]
}

/// 列表行模型：分组标题行或文件行
enum FileListRow: Equatable {
    case header(title: String, count: Int)
    case file(FileItem)

    var file: FileItem? {
        if case .file(let f) = self { return f }
        return nil
    }

    /// 分组时每组前插入标题行；平铺时只输出文件行
    static func rows(from groups: [FileGroup], grouped: Bool) -> [FileListRow] {
        guard grouped else { return groups.flatMap { $0.items.map(FileListRow.file) } }
        return groups.flatMap { group in
            [.header(title: group.title, count: group.items.count)] + group.items.map(FileListRow.file)
        }
    }

    /// 视图刷新差异键：标题行含组名与数量，文件行含路径（排序/分组变化会改变键 → 触发 reload）
    static func diffKey(_ rows: [FileListRow]) -> String {
        rows.map { row in
            switch row {
            case .header(let title, let count): return "H|\(title)|\(count)"
            case .file(let file): return file.url.path
            }
        }.joined(separator: "|")
    }
}

/// 纯函数分组逻辑：10 个维度的归类、分桶、组间与组内排序都在这里，不触碰 AppKit
enum GroupingService {
    static func group(_ files: [FileItem], by dimension: GroupDimension,
                      sortOption: SortOption, sortDirection: SortDirection,
                      now: Date = Date()) -> [FileGroup] {
        guard !files.isEmpty else { return [] }

        switch dimension {
        case .none:
            return [FileGroup(title: "", items: sort(files, sortOption: sortOption, sortDirection: sortDirection))]
        case .name:
            let keyed = files.map { (key: nameKey($0), item: $0) }
            return grouped(keyed, fixedOrder: nil, titleComparator: nameTitleOrder, sortOption: sortOption, sortDirection: sortDirection)
        case .kind:
            let keyed = files.map { (key: kindCategory($0), item: $0) }
            return grouped(keyed, fixedOrder: nil, sortOption: sortOption, sortDirection: sortDirection)
        case .application:
            let keyed = files.map { (key: $0.pathExtensionLowercased == "app" ? "应用程序" : "其他", item: $0) }
            return grouped(keyed, fixedOrder: ["应用程序", "其他"], sortOption: sortOption, sortDirection: sortDirection)
        case .lastOpened:
            // spec：缺失归「无日期」，不回退其他日期属性
            return dateGrouped(files, keyPath: \.lastUsedDate, sortOption: sortOption, sortDirection: sortDirection, now: now)
        case .added:
            return dateGrouped(files, keyPath: \.addedDate, sortOption: sortOption, sortDirection: sortDirection, now: now)
        case .modified:
            return dateGrouped(files, keyPath: \.modificationDate, sortOption: sortOption, sortDirection: sortDirection, now: now)
        case .created:
            return dateGrouped(files, keyPath: \.createdDate, sortOption: sortOption, sortDirection: sortDirection, now: now)
        case .size:
            let keyed = files.map { (key: sizeBucket($0), item: $0) }
            return grouped(keyed, fixedOrder: sizeOrder, sortOption: sortOption, sortDirection: sortDirection)
        case .tag:
            let keyed = files.map { (key: primaryTag($0), item: $0) }
            let known = FinderTag.all.map(\.name)
            let unknown = Set(keyed.map(\.key)).subtracting(known).subtracting(["无标签"]).sorted()
            return grouped(keyed, fixedOrder: known + unknown + ["无标签"], sortOption: sortOption, sortDirection: sortDirection)
        }
    }

    // MARK: - 组间组织

    /// 按 key 归组；fixedOrder 为 nil 时组间按组名排序，否则按固定顺序（缺组跳过、多余 key 追加在固定序之后）
    private static func grouped(_ keyed: [(key: String, item: FileItem)], fixedOrder: [String]?,
                                titleComparator: ((String, String) -> Bool)? = nil,
                                sortOption: SortOption, sortDirection: SortDirection) -> [FileGroup] {
        let dict = Dictionary(grouping: keyed, by: \.key)
        var titles = Array(dict.keys)
        if let fixedOrder {
            let rank = Dictionary(uniqueKeysWithValues: fixedOrder.enumerated().map { ($1, $0) })
            let cutoff = fixedOrder.count
            titles.sort {
                let r1 = rank[$0] ?? cutoff, r2 = rank[$1] ?? cutoff
                return r1 == r2 ? $0.localizedStandardCompare($1) == .orderedAscending : r1 < r2
            }
        } else if let titleComparator {
            titles.sort(by: titleComparator)
        } else {
            titles.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return titles.map { title in
            FileGroup(title: title, items: sort(dict[title]!.map(\.item), sortOption: sortOption, sortDirection: sortDirection))
        }
    }

    // MARK: - 日期分桶

    private static let dateBuckets = ["今天", "昨天", "前 7 天", "前 30 天", "今年", "更早", "无日期"]

    private static func dateGrouped(_ files: [FileItem], keyPath: (FileItem) -> Date?,
                                    sortOption: SortOption, sortDirection: SortDirection, now: Date) -> [FileGroup] {
        let cal = Calendar.current
        let startOfNow = cal.startOfDay(for: now)
        func bucket(_ date: Date?) -> String {
            guard let date else { return "无日期" }
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: date), to: startOfNow).day ?? 0
            if days <= 0 { return "今天" }
            if days == 1 { return "昨天" }
            if days < 7 { return "前 7 天" }
            if days < 30 { return "前 30 天" }
            if cal.isDate(date, equalTo: now, toGranularity: .year) { return "今年" }
            return "更早"
        }
        let keyed = files.map { (key: bucket(keyPath($0)), item: $0) }
        return grouped(keyed, fixedOrder: dateBuckets, sortOption: sortOption, sortDirection: sortDirection)
    }

    // MARK: - 单维度归类

    private static func nameKey(_ item: FileItem) -> String {
        guard let first = item.name.first else { return "#" }
        return CharacterSet.letters.contains(first.unicodeScalars.first!) ? String(first).uppercased() : "#"
    }

    /// 「#」（非字母）在最前，拉丁字母按字母序，CJK 等按首字符码位排在其后——确定性排序，不依赖本地化规则
    private static func nameTitleOrder(_ a: String, _ b: String) -> Bool {
        if a == "#" { return b != "#" }
        if b == "#" { return false }
        return a.first!.unicodeScalars.first!.value < b.first!.unicodeScalars.first!.value
    }

    private static func kindCategory(_ item: FileItem) -> String {
        if item.pathExtensionLowercased == "app" { return "应用程序" }
        if item.isDirectory { return "文件夹" }
        // 按扩展名推导 UTI；探测到更具体的 typeIdentifier 且扩展名推导失败时回退到它
        let uti = UTType(filenameExtension: item.fileExtension) ?? UTType(item.utiType)
        guard let uti else { return "其他" }
        if uti.conforms(to: .image) { return "图像" }
        if uti.conforms(to: .audio) { return "音频" }
        if uti.conforms(to: .movie) { return "影片" }
        if uti.conforms(to: .archive) { return "归档" }
        if uti.conforms(to: .text) || uti.conforms(to: .pdf) || uti.conforms(to: .presentation)
            || uti.conforms(to: .spreadsheet) || uti.conforms(to: .compositeContent) { return "文稿" }
        return "其他"
    }

    private static let sizeOrder = ["文件夹", "1 GB 以上", "100–1000 MB", "10–100 MB", "1–10 MB", "100 KB–1 MB", "10–100 KB", "小于 10 KB", "未知大小"]

    private static func sizeBucket(_ item: FileItem) -> String {
        if item.isDirectory { return "文件夹" }
        guard let size = item.size else { return "未知大小" }
        let kb: Int64 = 1024, mb = 1024 * kb, gb = 1024 * mb
        switch size {
        case gb..<Int64.max: return "1 GB 以上"
        case 100 * mb..<gb: return "100–1000 MB"
        case 10 * mb..<100 * mb: return "10–100 MB"
        case mb..<10 * mb: return "1–10 MB"
        case 100 * kb..<mb: return "100 KB–1 MB"
        case 10 * kb..<100 * kb: return "10–100 KB"
        default: return "小于 10 KB"
        }
    }

    /// 多标签条目取存储序中的第一个标签（spec：按条目第一个标签归组）
    private static func primaryTag(_ item: FileItem) -> String {
        guard let tags = item.tags, !tags.isEmpty else { return "无标签" }
        return tags[0]
    }

    // MARK: - 组内排序（与列表平铺排序同语义：文件夹在前，按维度与方向）

    static func sort(_ items: [FileItem], sortOption: SortOption, sortDirection: SortDirection) -> [FileItem] {
        let dirs = items.filter(\.isDirectory)
        let nonDirs = items.filter { !$0.isDirectory }

        func sorted(_ list: [FileItem], by compare: @escaping (FileItem, FileItem) -> Bool) -> [FileItem] {
            let result = list.sorted(by: compare)
            return sortDirection == .ascending ? result : result.reversed()
        }

        switch sortOption {
        case .name:
            return sorted(dirs, by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
                + sorted(nonDirs, by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        case .size:
            return dirs + sorted(nonDirs, by: { ($0.size ?? 0) < ($1.size ?? 0) })
        case .kind:
            return sorted(dirs, by: { $0.fileExtension.localizedStandardCompare($1.fileExtension) == .orderedAscending })
                + sorted(nonDirs, by: { $0.fileExtension.localizedStandardCompare($1.fileExtension) == .orderedAscending })
        case .date:
            return sorted(dirs, by: { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) })
                + sorted(nonDirs, by: { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) })
        }
    }
}

private extension FileItem {
    var pathExtensionLowercased: String { fileExtension.lowercased() }
}
