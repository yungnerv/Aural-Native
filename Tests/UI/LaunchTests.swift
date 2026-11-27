import XCTest

final class LaunchTests: XCTestCase {
    @MainActor
    func testFreshLaunch() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["No music"].waitForExistence(timeout: 20),
                      "A fresh simulator should open the empty library without an error")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertFalse(app.buttons["open-player"].exists, "No player before selecting music")
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
        XCTAssertTrue(row.isHittable, "Track row must be tappable")
        // Exercise whitespace, not only the title/artwork. On iPad this is
        // precisely where a plain button with an unshaped Spacer can miss.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        let selection = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"), object: row
        )
        guard XCTWaiter.wait(for: [selection], timeout: 15) == .completed else {
            captureFailure(app, named: "Track Selection Failed")
            XCTFail("A tap in the trailing portion of the track row must select it")
            return
        }

        let open = app.buttons["open-player"]
        guard open.waitForExistence(timeout: 20) else {
            captureFailure(app, named: "Missing Mini Player")
            XCTFail("The native mini-player must be accessible on both iPhone and iPad")
            return
        }
        capture(app, named: "Native Library and Mini Player")
        XCTAssertEqual(app.buttons.matching(identifier: "open-player").count, 1,
                       "Only one active mini-player must be exposed")
        XCTAssertGreaterThanOrEqual(open.frame.width, 44)
        XCTAssertGreaterThanOrEqual(open.frame.height, 44)
        XCTAssertTrue(open.isHittable, "The mini-player must be onscreen and tappable")
        XCTAssertEqual(open.value as? String, "Aural Test Track, Fixture Artist")
        let miniToggle = app.buttons["mini-toggle"]
        XCTAssertTrue(miniToggle.exists && miniToggle.isHittable, "Mini-player transport must be available")
        XCTAssertEqual(miniToggle.label, "Pause")
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
        XCTAssertTrue(open.isHittable)
        XCTAssertEqual(miniToggle.label, "Play", "Paused state must be shared between both presentations")
        XCTAssertTrue(miniToggle.isHittable)
        miniToggle.tap()
        XCTAssertEqual(miniToggle.label, "Pause", "Mini-player must directly resume playback")
        miniToggle.tap()
        XCTAssertEqual(miniToggle.label, "Play", "Mini-player must directly pause playback")
        XCTAssertTrue(open.isHittable, "Transport must not obstruct the player button")
        open.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(toggle.label, "Play", "Reopened player must preserve the paused state")
        close.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 15))
        XCTAssertTrue(open.isHittable)
    }

    @MainActor
    private func captureFailure(_ app: XCUIApplication, named name: String) {
        capture(app, named: name)
        let diagnostic = XCTAttachment(string: app.debugDescription)
        diagnostic.name = "\(name) — accessibility hierarchy"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        print("UI failure hierarchy: \(app.debugDescription)")
        if app.alerts.firstMatch.exists {
            print("Visible application alert: \(app.alerts.firstMatch.debugDescription)")
        }
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
