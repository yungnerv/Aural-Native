import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testFreshLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["No music"].waitForExistence(timeout: 20),
                      "A fresh simulator should open the empty library without an error")
        XCTAssertEqual(app.state, .runningForeground)
    }
}
