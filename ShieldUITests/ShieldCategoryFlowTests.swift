import AppKit
import XCTest

// Source-only acceptance for categories and the recent-permanent correction.
// The visual fixture is a throwaway simulated backend in a temporary folder;
// these tests never use installed Shield RC or the system authority.
final class ShieldCategoryFlowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_UI_POLISH_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_VISUAL_SIZE"] = "standard"
        app.launchEnvironment["SHIELD_VISUAL_APPEARANCE"] = "light"
        app.launchEnvironment["SHIELD_UNCONFINED_TOOL_FIXTURE"] = "0"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        addTeardownBlock {
            if app.state != .notRunning { app.terminate() }
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "Shield window never appeared")
        app.activate()
        return app
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func element(prefix: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
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

    private func choose(_ item: String, in popUp: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(popUp.waitForExistence(timeout: 8), "Missing picker \(popUp)")
        popUp.click()
        let option = app.menuItems[item]
        XCTAssertTrue(option.waitForExistence(timeout: 5), "Missing menu option \(item)")
        option.click()
    }

    /// The user's real case: a Forever Lock In made by mistake with
    /// X/Reddit plus Tumblr. Correcting it keeps Tumblr permanent and moves
    /// only the removed sites onto a 24-hour release.
    func testCategoryCreateBlockAndCorrectRecentPermanent() {
        let app = launchFixture()

        // 1. A new category from Protection's New (+) menu.
        let add = element("addMenu", in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 12), "New (+) menu missing")
        add.click()
        // By identifier: the menu bar's File menu has its own "New Category…" (⌘N).
        let newCategory = element("addCategory", in: app)
        XCTAssertTrue(newCategory.waitForExistence(timeout: 5), "New Category… missing from the + menu")
        newCategory.click()
        let name = element("categoryName", in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.click()
        name.typeText("Games")
        element("categoryColor-purple", in: app).click()
        attachScreen("01-category-editor")
        element("saveCategory", in: app).click()
        XCTAssertTrue(waitGone(element("saveCategory", in: app)), "Category editor did not close")
        let games = element(prefix: "group-user-", in: app).firstMatch
        XCTAssertTrue(games.waitForExistence(timeout: 8), "The new category is not listed on Protection")
        attachScreen("02-protection-with-category")

        // 2. A Forever Lock In. Return adds the typed sites as rows; it never commits.
        element("moreMenu", in: app).click()
        let lockIn = element("lockInButton", in: app)
        XCTAssertTrue(lockIn.waitForExistence(timeout: 5), "Lock In missing from ⋯")
        lockIn.click()
        let domains = element("focusDomains", in: app)
        XCTAssertTrue(domains.waitForExistence(timeout: 8))
        domains.click()
        domains.typeText("x.com, reddit.com, tumblr.com\r")
        for site in ["x.com", "reddit.com", "tumblr.com"] {
            XCTAssertTrue(element("lockInItem-\(site)", in: app).waitForExistence(timeout: 5), "\(site) wasn't added as a row")
        }
        choose("Forever", in: element("focusDuration", in: app), app: app)
        let understand = element("confirmPermanentBlock", in: app)
        XCTAssertTrue(understand.waitForExistence(timeout: 5), "Forever needs an explicit acknowledgement")
        let create = element("commitFixtureFocus", in: app)
        XCTAssertFalse(create.isEnabled, "Forever must not be creatable before the acknowledgement")
        understand.click()
        attachScreen("03-permanent-lock-in")
        XCTAssertTrue(create.isEnabled)
        create.click()
        XCTAssertTrue(waitGone(create), "Lock In did not close after the fixture confirmed")

        // 3. A Lock In lands under Other; the recent permanent rule is correctable.
        let other = element("group-other", in: app)
        XCTAssertTrue(other.waitForExistence(timeout: 8), "Other is not listed on Protection")
        other.click()
        let correct = element(prefix: "correctPermanent-focus-", in: app).firstMatch
        XCTAssertTrue(correct.waitForExistence(timeout: 12),
                      "Correct This Permanent Block is missing. \(app.debugDescription)")
        let originalID = correct.identifier
        attachScreen("04-category-detail-before")
        correct.click()

        // 4. Remove X and Reddit, keep Tumblr.
        for site in ["x.com", "reddit.com"] {
            let box = element("removeSite-\(site)", in: app)
            XCTAssertTrue(box.waitForExistence(timeout: 8), "Missing checkbox for \(site)")
            box.click()
        }
        let confirm = element("confirmRemoveSites", in: app)
        XCTAssertEqual(confirm.label, "Remove 2 Websites")
        attachScreen("05-correction-sheet")
        confirm.click()
        XCTAssertTrue(waitGone(confirm), "Correction sheet did not close. \(app.debugDescription)")
        sleep(1)
        attachScreen("06-category-detail-after")

        // The original rule now shows a pending change instead of the button,
        // and a new permanent rule (Tumblr only) remains correctable.
        XCTAssertFalse(element(originalID, in: app).exists, "Original rule still offers a correction")
        let remaining = element(prefix: "correctPermanent-focus-", in: app)
        XCTAssertEqual(remaining.count, 1, "Expected exactly the kept Tumblr rule to stay permanent")
        let keptID = remaining.firstMatch.identifier.replacingOccurrences(of: "correctPermanent-", with: "")
        // Clicking a block's row shows its websites.
        element("ruleWebsites-\(keptID)", in: app).click()
        XCTAssertTrue(element("rowWebsites", in: app).waitForExistence(timeout: 5), "Row click must show its websites")
        let keptText = app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'tumblr.com' OR label CONTAINS 'tumblr.com'")).firstMatch
        XCTAssertTrue(keptText.waitForExistence(timeout: 5), "Kept rule should list tumblr.com")
        let keptValue = (keptText.value as? String ?? "") + keptText.label
        XCTAssertFalse(keptValue.contains("x.com") || keptValue.contains("reddit.com"),
                       "Kept permanent rule must not contain removed sites: \(keptValue)")
        attachScreen("07-kept-domains")

        // 5. The new category starts empty and offers New Block and New Daily
        // Schedule; its one menu also renames and recolours it.
        // Back to Protection the way a person does: the toolbar's Back button.
        let back = app.windows.firstMatch.toolbars.buttons.matching(NSPredicate(format:
            "label ==[c] 'Back' OR identifier ==[c] 'Back' OR identifier CONTAINS[c] 'back'")).firstMatch
        if back.waitForExistence(timeout: 5) && back.isHittable { back.click() } else { app.typeKey("[", modifierFlags: .command) }
        XCTAssertTrue(games.waitForExistence(timeout: 8), "Back didn't return to Protection")
        games.click()
        XCTAssertTrue(element("categoryAddWebsites", in: app).waitForExistence(timeout: 8),
                      "An empty category doesn't offer New Block")
        XCTAssertTrue(element("categoryAddSchedule", in: app).exists, "An empty category doesn't offer New Daily Schedule")
        let menu = element("categoryAddMenu", in: app)
        menu.click()
        for item in ["New Block…", "New Daily Schedule…"] {
            XCTAssertTrue(app.menuItems[item].waitForExistence(timeout: 5), "\(item) missing from the category + menu")
        }
        app.typeKey(.escape, modifierFlags: [])
        element("categoryMoreMenu", in: app).click()
        XCTAssertTrue(app.menuItems["Edit Category…"].waitForExistence(timeout: 5), "Edit Category… missing from ⋯")
        app.menuItems["Edit Category…"].click()
        let rename = element("categoryName", in: app)
        XCTAssertTrue(rename.waitForExistence(timeout: 8))
        rename.doubleClick()
        rename.typeKey("a", modifierFlags: .command)
        rename.typeText("Social extras")
        element("categoryColor-orange", in: app).click()
        element("saveCategory", in: app).click()
        XCTAssertTrue(waitGone(element("saveCategory", in: app)))
        let renamed = expectation(for: NSPredicate { _, _ in app.windows.firstMatch.title == "Social extras" },
                                  evaluatedWith: app)
        XCTAssertEqual(XCTWaiter.wait(for: [renamed], timeout: 8), .completed,
                       "Renamed category title not shown: \(app.windows.firstMatch.title)")
        attachScreen("08-renamed-category")
    }
}
