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

    @MainActor
    func testNativePlayerPresentation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--aural-ui-fixture"]
        app.launch()

        let songs = app.buttons["Songs"]
        XCTAssertTrue(songs.waitForExistence(timeout: 30))
        songs.tap()

        let row = app.buttons["track-1A2B3C4D-0001-4000-8000-000000000001"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()

        let open = app.buttons["open-player"]
        XCTAssertTrue(open.waitForExistence(timeout: 20), "The native mini-player must be accessible")
        capture(app, named: "Native Library and Mini Player")
        open.tap()

        let title = app.staticTexts["player-track-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, "Aural Test Track")

        let toggle = app.buttons["player-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.label, "Pause", "Selecting a track must start playback intent")
        toggle.tap()
        XCTAssertEqual(toggle.label, "Play")
        capture(app, named: "Native Now Playing")

        let close = app.buttons["close-player"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 15))
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
