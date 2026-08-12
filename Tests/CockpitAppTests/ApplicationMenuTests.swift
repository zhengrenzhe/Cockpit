import AppKit
import XCTest
@testable import Cockpit

@MainActor
final class ApplicationMenuTests: XCTestCase {
    func testCommandQRoutesToApplicationTerminate() throws {
        let application = NSApplication.shared
        let menu = makeCockpitMainMenu(
            application: application,
            applicationName: "Cockpit"
        )
        let applicationMenu = try XCTUnwrap(menu.items.first?.submenu)
        let quitItem = try XCTUnwrap(
            applicationMenu.items.first(where: { $0.keyEquivalent == "q" })
        )

        XCTAssertEqual(quitItem.action, #selector(NSApplication.terminate(_:)))
        XCTAssertTrue(quitItem.target === application)
        XCTAssertTrue(quitItem.keyEquivalentModifierMask.contains(.command))
    }
}
