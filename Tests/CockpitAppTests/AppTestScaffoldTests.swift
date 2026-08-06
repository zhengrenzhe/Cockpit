import XCTest

final class AppTestScaffoldTests: XCTestCase {
    func testXCTestBundleLoadsTheCockpitHostApplication() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "dev.cockpit.Cockpit")
    }
}
