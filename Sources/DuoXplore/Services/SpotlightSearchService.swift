import CoreServices
import Foundation

/// Spotlight 搜索：递归搜索指定文件夹及其子文件夹（Finder 同款底层 NSMetadataQuery）；
/// Spotlight 不可用（索引关闭/网络盘/目录被排除）时回退到调用方提供的内存过滤
@MainActor
final class SpotlightSearchService: ObservableObject {
    @Published private(set) var items: [FileItem] = []
    @Published private(set) var usedFallback = false

    private static let resultLimit = 500
    private static let debounceInterval: TimeInterval = 0.2

    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    private var folder: URL?
    private var text = ""
    private var fallback: ((String) -> [FileItem])?

    func search(text: String, in folder: URL, fallback: @escaping (String) -> [FileItem]) {
        pending?.cancel()
        guard !text.isEmpty else {
            stop()
            return
        }
        self.folder = folder
        self.fallback = fallback
        let work = DispatchWorkItem { [weak self] in self?.startQuery(text: text) }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    func stop() {
        pending?.cancel()
        tearDownQuery()
        items = []
        usedFallback = false
    }

    private func startQuery(text: String) {
        tearDownQuery()
        guard let folder else { return }
        self.text = text

        let q = NSMetadataQuery()
        q.searchScopes = [folder.path]
        q.predicate = NSPredicate(format: "kMDItemFSName CONTAINS[cd] %@", text)

        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            .NSMetadataQueryDidStartGathering,
            .NSMetadataQueryDidUpdate,
            .NSMetadataQueryDidFinishGathering,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: q, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.collectResults(finished: name == .NSMetadataQueryDidFinishGathering)
                }
            }
        }
        query = q
        q.start()
    }

    private func collectResults(finished: Bool) {
        guard let query else { return }
        // ponytail: 映射截断到前 500 条，防止超大结果集在每次批量更新时全量映射卡 UI；升级路径是分批加载
        let found = query.results.prefix(Self.resultLimit).compactMap { item -> FileItem? in
            guard let item = item as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
            let isDirectory = (item.value(forAttribute: NSMetadataItemContentTypeTreeKey) as? [String])?
                .contains("public.folder") ?? false
            return FileItem(url: URL(fileURLWithPath: path, isDirectory: isDirectory))
        }

        if finished, found.isEmpty, !usedFallback, let folder,
           NSMetadataItem(url: folder) == nil {
            // 目录未被 Spotlight 索引：停掉查询，回退到内存过滤，保证顶层文件仍可搜到
            usedFallback = true
            tearDownQuery()
        }
        items = usedFallback ? (fallback?(text) ?? []) : found
    }

    private func tearDownQuery() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers = []
        query?.stop()
        query = nil
    }
}
