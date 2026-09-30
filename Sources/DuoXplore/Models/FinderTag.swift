import AppKit

/// Finder 系统颜色标签（固定 7 个，颜色取 Finder 默认标签近似色）
struct FinderTag: Equatable, Hashable {
    let name: String
    let color: NSColor

    static let all: [FinderTag] = [
        FinderTag(name: "红色", color: NSColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)),
        FinderTag(name: "橙色", color: NSColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1)),
        FinderTag(name: "黄色", color: NSColor(red: 1.0, green: 0.80, blue: 0.0, alpha: 1)),
        FinderTag(name: "绿色", color: NSColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)),
        FinderTag(name: "蓝色", color: NSColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 1)),
        FinderTag(name: "紫色", color: NSColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1)),
        FinderTag(name: "灰色", color: NSColor(red: 0.56, green: 0.56, blue: 0.58, alpha: 1)),
    ]

    /// Spotlight 按标签检索的谓词（Finder 同款字段）
    static func predicate(for name: String) -> NSPredicate {
        NSPredicate(format: "kMDItemUserTags == %@", name)
    }
}
