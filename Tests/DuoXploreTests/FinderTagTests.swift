import XCTest
@testable import DuoXplore

final class FinderTagTests: XCTestCase {
    func testSystemTagsAreUnique() {
        XCTAssertEqual(FinderTag.all.count, 7)
        XCTAssertEqual(Set(FinderTag.all.map(\.name)).count, 7)
    }

    func testTagPredicateTargetsUserTags() {
        let predicate = FinderTag.predicate(for: "红色")
        XCTAssertTrue(predicate.predicateFormat.contains("kMDItemUserTags"))
        XCTAssertTrue(predicate.predicateFormat.contains("红色"))
    }
}
