import AppKit
import XCTest
@testable import CommanderUI

@MainActor
final class UpdateAvailableButtonTests: XCTestCase {
    private final class Target: NSObject {
        var clickCount = 0

        @objc func clicked(_ sender: Any?) {
            clickCount += 1
        }
    }

    func testPresentationAndTitlebarSpacing() throws {
        let view = UpdateAvailableButton(target: nil, action: nil)
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? NSButton }.first)

        XCTAssertEqual(button.title, "Update Available")
        XCTAssertNotNil(button.image)
        XCTAssertEqual(button.imagePosition, .imageLeading)
        XCTAssertFalse(button.isBordered)
        XCTAssertGreaterThan(view.frame.width, button.frame.width)
        XCTAssertEqual(view.frame.height, button.frame.height)
    }

    func testForwardsClickToTarget() throws {
        let target = Target()
        let view = UpdateAvailableButton(target: target, action: #selector(Target.clicked(_:)))
        let button = try XCTUnwrap(view.subviews.compactMap { $0 as? NSButton }.first)

        button.performClick(nil)

        XCTAssertEqual(target.clickCount, 1)
    }
}
