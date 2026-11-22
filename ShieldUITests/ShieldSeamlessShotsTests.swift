import XCTest

// Operation Seamless before/after screenshots (development fixture only;
// never touches installed Shield). Tolerant on purpose: the same file runs
// against the old build, where New Block isn't in the Protection menu.
final class ShieldSeamlessShotsTests: XCTestCase {
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func attachScreen(_ name: String) {
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = name
        screen.lifetime = .keepAlways
        add(screen)
    }

    func testSeamlessScreens() {
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

        let menu = element("addMenu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 15), "No New menu on Protection")
        menu.click()
        sleep(1)
        attachScreen("1-protection-new-menu")
        let newBlock = app.menuItems["New Block…"]
        let hasNewBlock = newBlock.waitForExistence(timeout: 3)
        if hasNewBlock {
            newBlock.click()
            XCTAssertTrue(element("newBlockDomains", in: app).waitForExistence(timeout: 10),
                          "New Block didn't open from Protection")
            sleep(1)
            attachScreen("2-new-block-from-protection")
            app.typeKey(.escape, modifierFlags: [])
        } else {
            app.typeKey(.escape, modifierFlags: [])
        }

        let places = element("nav-places", in: app)
        XCTAssertTrue(places.waitForExistence(timeout: 10), "No Places in the sidebar")
        places.click()
        sleep(2)
        attachScreen("3-places")
        let protection = element("nav-protection", in: app)
        if protection.waitForExistence(timeout: 5) { protection.click(); sleep(1); attachScreen("4-protection") }
        // Recorded, not asserted: the old build has no New Block here.
        let note = XCTAttachment(string: "New Block in Protection menu: \(hasNewBlock)")
        note.lifetime = .keepAlways
        add(note)
    }
}
