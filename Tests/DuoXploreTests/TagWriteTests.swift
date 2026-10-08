import XCTest
@testable import DuoXplore

final class TagWriteTests: XCTestCase {
    func testWriteAndReadBackTags() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tag-write-test-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }

        let fs = FileSystemService()
        XCTAssertTrue(fs.writeTags(["红色", "蓝色"], to: url))

        let item = FileItem(url: url)
        XCTAssertEqual(item.tags, ["红色", "蓝色"])

        // 覆盖写为空 = 清除全部标签
        XCTAssertTrue(fs.writeTags([], to: url))
        let cleared = FileItem(url: url)
        XCTAssertTrue(cleared.tags?.isEmpty ?? true)
    }
}
