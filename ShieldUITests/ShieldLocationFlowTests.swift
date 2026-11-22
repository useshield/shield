import XCTest

// Place blocks end to end in the development build (simulated policy,
// one saved place seeded by SHIELD_UI_TEST_PLACES=1). Never starts a real
// location check that matters and never touches installed Shield.
final class ShieldLocationFlowTests: XCTestCase {
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

    private func launchShield() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_UI_POLISH_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_VISUAL_SIZE"] = "standard"
        app.launchEnvironment["SHIELD_UNCONFINED_TOOL_FIXTURE"] = "0"
        app.launchEnvironment["SHIELD_UI_TEST_PLACES"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        addTeardownBlock { if app.state != .notRunning { app.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "Shield window never appeared")
        app.activate()
        return app
    }

    /// Places → a place → blue + (New Block Here): New Block opens already set to
    /// that place, websites only, no category, and the lock lands under
    /// Location blocks and on the place's own page. (Lock In has no places.)
    func testABlockSetToAPlaceLandsInLocationBlocks() {
        let app = launchShield()
        let places = element("nav-places", in: app)
        XCTAssertTrue(places.waitForExistence(timeout: 15), "No Places in the sidebar")
        places.click()
        let saved = element("place-test-library", in: app)
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "The seeded place isn't listed")
        saved.click()
        // One item, so the place page's + opens New Block straight away.
        let lockHere = element("placeAddMenu", in: app)
        XCTAssertTrue(lockHere.waitForExistence(timeout: 10), "The place page did not open")
        lockHere.click()

        let sites = element("newBlockDomains", in: app)
        XCTAssertTrue(sites.waitForExistence(timeout: 10), "New Block did not open from the place page")
        sites.click()
        sites.typeText("tumblr.com")
        let place = element("blockWhere", in: app)
        XCTAssertTrue(place.waitForExistence(timeout: 5), "No Where picker with a saved place. \(app.debugDescription)")
        XCTAssertTrue("\(place.value ?? "") \(place.label)".contains("Library"),
                      "New Block from a place page must start at that place: \(place.value ?? place.label)")
        XCTAssertFalse(element("categoryPicker", in: app).exists, "A place block goes to Location blocks")
        attachScreen("01-new-block-only-at-library")

        let commit = element("commitNewBlock", in: app)
        XCTAssertTrue(commit.isEnabled, "A place block must be creatable")
        commit.click()
        XCTAssertTrue(waitGone(commit), "New Block did not close after the fixture confirmed")

        // The place's own page lists the lock.
        let listed = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'placeLock-'")).firstMatch
        XCTAssertTrue(listed.waitForExistence(timeout: 10), "The place page doesn't list its lock")
        // The row is a container: its name shows, clicking it shows its websites.
        let tumblr = listed.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'tumblr.com' OR value CONTAINS 'tumblr.com'")).firstMatch
        if !tumblr.waitForExistence(timeout: 2) { listed.buttons.firstMatch.click() }
        XCTAssertTrue(tumblr.waitForExistence(timeout: 5),
                      "The place page lists the wrong lock. \(listed.debugDescription)")
        attachScreen("02-place-page")

        let protection = element("nav-protection", in: app)
        XCTAssertTrue(protection.waitForExistence(timeout: 5), "No Protection in the sidebar")
        protection.click()
        let group = element("group-location", in: app)
        XCTAssertTrue(group.waitForExistence(timeout: 10), "No Location blocks category on Protection")
        attachScreen("03-protection-with-location-blocks")
        group.click()
        // One row: its site and where it applies ("tumblr.com, At Library · 1 website").
        let row = app.descendants(matching: .any).matching(NSPredicate(format:
            "identifier BEGINSWITH 'ruleWebsites-' AND label CONTAINS 'tumblr.com'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The place block isn't under Location blocks")
        XCTAssertTrue(row.label.localizedCaseInsensitiveContains("at Library"),
                      "The row doesn't say where it applies: \(row.label)")
        attachScreen("04-location-blocks-page")

        places.click()
        let counted = element("place-test-library", in: app)
        XCTAssertTrue(counted.waitForExistence(timeout: 10), "Places did not reopen")
        // Scoped to the row: a query over the whole window would walk the map's
        // accessibility tree and time out.
        let used = counted.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS '1 block' OR value CONTAINS '1 block'")).firstMatch
        XCTAssertTrue(counted.label.contains("1 block") || used.waitForExistence(timeout: 5),
                      "Places doesn't count the new block. Row: \(counted.label)")
        attachScreen("05-places-page")
    }
}
