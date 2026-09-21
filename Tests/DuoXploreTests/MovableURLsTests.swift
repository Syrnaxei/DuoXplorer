import XCTest
@testable import DuoXplore

/// 拖放目标过滤逻辑（movableURLs）的自检
final class MovableURLsTests: XCTestCase {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testDroppingBackIntoOwnFolderIsNoOp() {
        XCTAssertTrue(movableURLs([url("/a/file.txt")], into: url("/a")).isEmpty)
    }

    func testKeepsItemsFromOtherFolders() {
        XCTAssertEqual(movableURLs([url("/b/file.txt")], into: url("/a")).map(\.path), ["/b/file.txt"])
    }

    func testFiltersFolderDroppedIntoOwnSubfolder() {
        XCTAssertTrue(movableURLs([url("/a")], into: url("/a/b/c")).isEmpty)
    }

    func testKeepsFolderIntoSibling() {
        XCTAssertEqual(movableURLs([url("/a/b")], into: url("/a/c")).map(\.path), ["/a/b"])
    }

    func testMixedSelectionKeepsOnlyForeignItems() {
        XCTAssertEqual(movableURLs([url("/a/x"), url("/b/y/z")], into: url("/a")).map(\.path), ["/b/y/z"])
    }
}
