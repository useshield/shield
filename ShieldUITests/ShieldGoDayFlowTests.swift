import XCTest

// Go There days end to end in the development build: simulated policy in
// a throwaway folder, one saved place (SHIELD_UI_TEST_PLACES=1), and a fixed
// "where you are now" instead of Core Location (SHIELD_UI_TEST_GO_START=1).
// Nothing is closed (app closing is off without SHIELD_PREVIEW_APP_BLOCKING)
// and installed Shield is never touched. Arriving is covered by GoDayTests.
final class ShieldGoDayFlowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func attachScreen(_ name: String) {
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = name
        screen.lifetime = .keepAlways
        add(screen)
    }

    private func waitGone(_ target: XCUIElement, timeout: TimeInterval = 12) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: target)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private func text(containing value: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)).firstMatch
    }

    private func launchShield() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_UI_POLISH_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_VISUAL_SIZE"] = "standard"
        app.launchEnvironment["SHIELD_UNCONFINED_TOOL_FIXTURE"] = "0"
        app.launchEnvironment["SHIELD_UI_TEST_PLACES"] = "1"
        app.launchEnvironment["SHIELD_UI_TEST_GO_START"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        addTeardownBlock { if app.state != .notRunning { app.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "Shield window never appeared")
        app.activate()
        return app
    }

    private func openGoThere(_ app: XCUIApplication) {
        let places = element("nav-places", in: app)
        XCTAssertTrue(places.waitForExistence(timeout: 10), "No Places in the sidebar")
        places.click()
        // Go There Today sits in Places' ⋯ menu.
        let more = element("placesMoreMenu", in: app)
        XCTAssertTrue(more.waitForExistence(timeout: 10), "No ⋯ menu on Places")
        more.click()
        let go = element("goThereTodayFromPlaces", in: app)
        XCTAssertTrue(go.waitForExistence(timeout: 10), "No Go There Today on Places. \(app.debugDescription)")
        go.click()
        XCTAssertTrue(element("confirmGoDay", in: app).waitForExistence(timeout: 10), "Go There Today did not open")
    }

    func testStartingAGoDayShowsTheBarAndUndoWorks() {
        let app = launchShield()
        openGoThere(app)
        XCTAssertTrue(text(containing: "web browsers won't open", in: app).exists, "The sheet must say what happens")
        let start = element("confirmGoDay", in: app)
        XCTAssertTrue(start.isEnabled, "One saved place is chosen for you and the start is known")
        attachScreen("01-go-there-sheet")
        start.click()
        // Starting for real asks first; practice doesn't.
        let really = element("confirmGoDayStart", in: app)
        XCTAssertTrue(really.waitForExistence(timeout: 10), "No are-you-sure before a Go day starts")
        XCTAssertTrue(text(containing: "can't be cancelled", in: app).exists, "The are-you-sure must say it can't be cancelled")
        attachScreen("01b-are-you-sure")
        really.click()
        XCTAssertTrue(waitGone(start), "The sheet did not close after the fixture confirmed")

        let status = element("goDayStatus", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 10), "No Go day line after starting")
        XCTAssertTrue(text(containing: "Blocking starts in", in: app).exists, "The undo countdown isn't shown")
        attachScreen("02-undo-countdown")
        let undo = element("undoGoDay", in: app)
        XCTAssertTrue(undo.exists)
        undo.click()
        XCTAssertTrue(waitGone(status), "Undo did not end the Go day")
        attachScreen("03-after-undo")
    }

    func testPracticeBlocksNothingAndEnds() {
        let app = launchShield()
        openGoThere(app)
        let practice = element("goDayPractice", in: app)
        XCTAssertTrue(practice.exists)
        XCTAssertTrue(practice.isEnabled)
        practice.click()
        XCTAssertTrue(waitGone(practice), "Try Without Blocking did not close the sheet")
        XCTAssertTrue(text(containing: "Practice (nothing blocked)", in: app).waitForExistence(timeout: 10),
                      "The practice line isn't shown")
        attachScreen("04-practice")
        let end = element("endGoDayPractice", in: app)
        XCTAssertTrue(end.exists)
        end.click()
        XCTAssertTrue(waitGone(element("goDayStatus", in: app)), "End Practice left the line up")
    }

    func testAPlaceCanBePinnedOnTheMap() {
        let app = launchShield()
        let places = element("nav-places", in: app)
        XCTAssertTrue(places.waitForExistence(timeout: 10))
        places.click()
        let onMap = element("addPlaceOnMap", in: app)
        XCTAssertTrue(onMap.waitForExistence(timeout: 10), "No Add on Map on Places")
        onMap.click()
        let map = element("placeMap", in: app)
        XCTAssertTrue(map.waitForExistence(timeout: 10), "The map picker did not open")
        let add = element("confirmMapPlace", in: app)
        XCTAssertFalse(add.isEnabled, "No pin yet")
        // Wait for the map to draw (named places appear) before clicking it: a
        // click on a still-loading map lands before its position is known.
        let drawn = map.descendants(matching: .any).matching(NSPredicate(format: "title != ''")).firstMatch
        XCTAssertTrue(drawn.waitForExistence(timeout: 15), "The map never finished loading")
        map.click()  // drops the pin where clicked
        let pin = map.descendants(matching: .any).matching(NSPredicate(format: "label == 'New place'")).firstMatch
        XCTAssertTrue(pin.waitForExistence(timeout: 5), "Clicking the map didn't drop a pin")
        let name = element("mapPlaceName", in: app)
        name.click()
        name.typeText("Cafe")
        XCTAssertTrue(add.isEnabled, "A pin and a name are enough")
        attachScreen("05-map-pin")
        add.click()
        XCTAssertTrue(waitGone(add), "The map picker did not close after the fixture confirmed")
        // A place row is one button ("Cafe, Location unknown"), not loose text.
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'place-' AND label BEGINSWITH 'Cafe'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The pinned place isn't listed")
        attachScreen("06-places-with-pin")
    }
}
