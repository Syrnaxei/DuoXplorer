import XCTest
@testable import DuoXplore

@MainActor
final class AppSettingsModelTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "showHiddenFiles")
        UserDefaults.standard.removeObject(forKey: "pinnedTagName")
        super.tearDown()
    }

    func testSettingsPersistAcrossInstances() {
        let a = AppSettingsModel()
        a.showHiddenFiles = true
        a.pinnedTagName = "红色"

        let b = AppSettingsModel()
        XCTAssertTrue(b.showHiddenFiles)
        XCTAssertEqual(b.pinnedTagName, "红色")
    }

    func testClearingPinnedTagPersistsAsNil() {
        let a = AppSettingsModel()
        a.pinnedTagName = "红色"
        a.pinnedTagName = nil

        XCTAssertNil(AppSettingsModel().pinnedTagName)
    }
}
