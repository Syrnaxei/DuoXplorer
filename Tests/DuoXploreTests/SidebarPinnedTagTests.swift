import XCTest
@testable import DuoXplore

final class SidebarPinnedTagTests: XCTestCase {
    private func folder(_ name: String) -> SidebarEntry {
        .folder(name: name, url: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    private func folders(_ count: Int) -> [SidebarEntry] {
        (0..<count).map { folder("f\($0)") }
    }

    func testFewerThanLimitShowsAllWithoutTrailingRow() {
        let rows = folders(5)
        XCTAssertEqual(SidebarEntry.pinnedChildren(rows), rows)
    }

    func testMoreThanLimitTruncatesAndAppendsShowAll() {
        let rows = folders(6)
        let result = SidebarEntry.pinnedChildren(rows)
        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(Array(result.prefix(5)), Array(rows.prefix(5)))
        XCTAssertEqual(result.last, SidebarEntry.showAllPinnedTag)
    }

    func testShowAllRowIsSelectableButNotGroup() {
        XCTAssertFalse(SidebarEntry.showAllPinnedTag.isGroup)
        XCTAssertNil(SidebarEntry.showAllPinnedTag.groupTitle)
    }
}
