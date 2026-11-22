import XCTest

// Click-tests for the user's Nov 15 changes, checking the result each time,
// not just the click: Edit Place keeps its name, colour and icon (and the look
// survives a relaunch); dragging a collection reorders the sidebar too; the
// Appearance choice sticks. Simulated policy in a throwaway folder; installed
// Shield is never used. Anything a test changes in the development app's
// settings it puts back.
final class ShieldOwnerChangesFlowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchShield(size: String = "standard") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_UI_POLISH_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_VISUAL_SIZE"] = size
        app.launchEnvironment["SHIELD_UNCONFINED_TOOL_FIXTURE"] = "0"
        app.launchEnvironment["SHIELD_UI_TEST_PLACES"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        addTeardownBlock { if app.state != .notRunning { app.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "Shield window never appeared")
        app.activate()
        return app
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func elements(prefix: String, in app: XCUIApplication) -> [XCUIElement] {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .allElementsBoundByIndex
    }

    private func attachScreen(_ name: String) {
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = name
        screen.lifetime = .keepAlways
        add(screen)
    }

    private func waitGone(_ target: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: target)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private func waitForTitle(_ title: String, in app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = app.windows.firstMatch.title
            if current == title || current.hasPrefix(title + " –") { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    private func open(_ nav: String, in app: XCUIApplication) {
        let row = element(nav, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "No \(nav) in the sidebar")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    private func click(_ id: String, in app: XCUIApplication, timeout: TimeInterval = 8) {
        let target = element(id, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: timeout), "Missing \(id). \(app.debugDescription)")
        target.click()
    }

    // MARK: - Edit Place

    private func openLibraryPlace(_ app: XCUIApplication) {
        open("nav-places", in: app)
        click("place-test-library", in: app, timeout: 12)
        XCTAssertTrue(element("placeMoreMenu", in: app).waitForExistence(timeout: 10), "The place page did not open")
    }

    private func openEditPlace(_ app: XCUIApplication) {
        click("placeMoreMenu", in: app)
        let item = app.menuItems["Edit Place…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Edit Place… missing from the ⋯ menu")
        item.click()
        XCTAssertTrue(element("savePlaceEditor", in: app).waitForExistence(timeout: 8), "Edit Place did not open")
    }

    private func isSelected(_ id: String, in app: XCUIApplication) -> Bool {
        let target = element(id, in: app)
        return target.waitForExistence(timeout: 5) && target.isSelected
    }

    func testEditPlaceSavesNameColourAndIcon() {
        var app = launchShield()
        openLibraryPlace(app)
        openEditPlace(app)
        attachScreen("01-edit-place")
        // One sheet holds all three: name, colour and icon.
        XCTAssertTrue(element("placeEditorName", in: app).exists, "No name field")
        XCTAssertTrue(element("placeColor-red", in: app).exists, "No colours")
        XCTAssertTrue(element("symbol-books.vertical.fill", in: app).exists, "No icons")

        let name = element("placeEditorName", in: app)
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Study Hall")
        click("placeColor-red", in: app)
        click("symbol-books.vertical.fill", in: app)
        click("savePlaceEditor", in: app)
        XCTAssertTrue(waitGone(element("savePlaceEditor", in: app)), "Edit Place did not close after Save")

        // Consequence 1: the simulated service accepted the new name.
        XCTAssertTrue(waitForTitle("Study Hall", in: app), "The new name never showed: \(app.windows.firstMatch.title)")
        attachScreen("02-renamed")

        // Consequence 2: the look was stored, not just shown.
        openEditPlace(app)
        XCTAssertTrue(isSelected("placeColor-red", in: app), "Red was not kept")
        XCTAssertTrue(isSelected("symbol-books.vertical.fill", in: app), "The books icon was not kept")
        click("cancelPlaceEditor", in: app)

        // Consequence 3: the look survives quitting and reopening Shield.
        app.terminate()
        app = launchShield()
        openLibraryPlace(app)
        openEditPlace(app)
        XCTAssertTrue(isSelected("placeColor-red", in: app), "Red was lost after relaunch")
        XCTAssertTrue(isSelected("symbol-books.vertical.fill", in: app), "The icon was lost after relaunch")
        attachScreen("03-after-relaunch")

        // Put the development app's look back as it was.
        click("placeColor-purple", in: app)
        click("symbol-mappin.and.ellipse", in: app)
        click("savePlaceEditor", in: app)
        XCTAssertTrue(waitGone(element("savePlaceEditor", in: app)))
    }

    // MARK: - Collection order

    private func newCollection(_ title: String, in app: XCUIApplication) {
        click("downloadsMenu", in: app)
        let item = app.menuItems["New Collection…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "New Collection… missing")
        item.click()
        let name = element("collectionName", in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.click()
        name.typeText(title)
        click("saveCollection", in: app)
        XCTAssertTrue(waitGone(element("saveCollection", in: app)), "New Collection did not close")
    }

    /// Sidebar collection names, top to bottom.
    private func sidebarOrder(_ app: XCUIApplication) -> [String] {
        elements(prefix: "collection-", in: app)
            .filter { $0.frame.width > 0 }
            .sorted { $0.frame.minY < $1.frame.minY }
            .map(text)
    }

    /// A row's words: its own label or value, else its texts' (a sidebar
    /// Label row reports neither itself).
    private func text(_ row: XCUIElement) -> String {
        let own = [row.label, row.value as? String ?? ""].joined(separator: " ")
        if !own.trimmingCharacters(in: .whitespaces).isEmpty { return own }
        return row.staticTexts.allElementsBoundByIndex
            .map { "\($0.label) \($0.value as? String ?? "")" }.joined(separator: " ")
    }

    func testCollectionOrderFollowsTheSidebar() {
        let app = launchShield(size: "wide")
        open("nav-studylibrary", in: app)
        // Library shows its collection tiles only once it holds a video.
        click("addVideos", in: app)
        let links = element("youtubeLinkInput", in: app)
        XCTAssertTrue(links.waitForExistence(timeout: 5), "Add Videos did not open")
        links.click()
        links.typeText("https://youtu.be/abcdefghijk")
        click("queueYouTubeLinks", in: app)
        XCTAssertTrue(waitGone(links), "Add Videos did not close")
        newCollection("Alpha", in: app)
        open("nav-studylibrary", in: app)
        newCollection("Beta", in: app)
        open("nav-studylibrary", in: app)
        XCTAssertTrue(waitForTitle("Library", in: app))

        let before = sidebarOrder(app)
        guard let alphaAt = before.firstIndex(where: { $0.contains("Alpha") }),
              let betaAt = before.firstIndex(where: { $0.contains("Beta") }) else {
            return XCTFail("Both collections must be in the sidebar: \(before)")
        }
        XCTAssertLessThan(alphaAt, betaAt, "Newer collections are added below")

        // Drag Beta's tile onto Alpha's on the Library page.
        let tiles = elements(prefix: "homeCollection-", in: app)
        guard let alpha = tiles.first(where: { text($0).contains("Alpha") }),
              let beta = tiles.first(where: { text($0).contains("Beta") }) else {
            return XCTFail("Both collections must show on the Library page. \(app.debugDescription)")
        }
        attachScreen("01-before-drag")
        beta.press(forDuration: 0.4, thenDragTo: alpha)

        // Consequence: the stored order changed, so the sidebar shows it too.
        let deadline = Date().addingTimeInterval(5)
        var after = sidebarOrder(app)
        while Date() < deadline {
            after = sidebarOrder(app)
            if let a = after.firstIndex(where: { $0.contains("Alpha") }),
               let b = after.firstIndex(where: { $0.contains("Beta") }), b < a { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        attachScreen("02-after-drag")
        guard let a = after.firstIndex(where: { $0.contains("Alpha") }),
              let b = after.firstIndex(where: { $0.contains("Beta") }) else {
            return XCTFail("A collection vanished after the drag: \(after)")
        }
        XCTAssertLessThan(b, a, "The sidebar did not follow the drag: \(after)")
        XCTAssertEqual(after.count, before.count, "Dragging must not add or remove collections")
    }

    // MARK: - Appearance

    func testSettingsAppearanceSwitchesAndSticks() {
        var app = launchShield()
        open("nav-diagnostics", in: app)
        let picker = element("appearancePicker", in: app)
        XCTAssertTrue(picker.waitForExistence(timeout: 10), "No Appearance setting. \(app.debugDescription)")
        let original = picker.value as? String ?? "System"
        let target = original == "Light" ? "Dark" : "Light"

        picker.click()
        let choice = app.menuItems[target]
        XCTAssertTrue(choice.waitForExistence(timeout: 5), "\(target) missing from Appearance")
        choice.click()
        attachScreen("01-switched")

        // Consequence: the choice is stored and comes back after a relaunch.
        app.terminate()
        app = launchShield()
        open("nav-diagnostics", in: app)
        let again = element("appearancePicker", in: app)
        XCTAssertTrue(again.waitForExistence(timeout: 10))
        XCTAssertEqual(again.value as? String, target, "Appearance did not stick after relaunch")

        // Put it back.
        again.click()
        let back = app.menuItems[original]
        if back.waitForExistence(timeout: 5) { back.click() }
    }
}
