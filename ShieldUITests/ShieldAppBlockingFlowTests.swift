import AppKit
import XCTest

// App blocking end to end in the development build: choose an app in New
// Block through the real Open panel, create the block in the simulated
// policy, then open that app and see it closed. Uses the opt-in preview
// enforcer (SHIELD_PREVIEW_APP_BLOCKING=1), which acts only on this user's
// apps; installed Shield and its service are never involved.
final class ShieldAppBlockingFlowTests: XCTestCase {
    private let chessPath = "/System/Applications/Chess.app"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func element(prefix: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
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
        app.launchEnvironment["SHIELD_PREVIEW_APP_BLOCKING"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        addTeardownBlock { if app.state != .notRunning { app.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15), "Shield window never appeared")
        app.activate()
        return app
    }

    // The real Open panel: Go to Folder with the app's path, then Open.
    private func choose(_ path: String, in app: XCUIApplication) {
        let open = app.windows.buttons["Open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 15), "The Open panel did not appear")
        app.windows.buttons["Cancel"].firstMatch.typeKey("g", modifierFlags: [.command, .shift])
        var field: XCUIElement?
        let ready = expectation(for: NSPredicate { _, _ in
            // Go to Folder's field has moved between macOS versions.
            for candidate in [app.textFields["PathTextField"], app.comboBoxes["PathTextField"],
                              app.popovers.textFields.firstMatch, app.comboBoxes.firstMatch,
                              app.dialogs.textFields.firstMatch, app.sheets.textFields.firstMatch]
                where candidate.exists && candidate.isHittable && candidate.identifier != "focusDomains" {
                field = candidate; return true
            }
            return false
        }, evaluatedWith: nil)
        wait(for: [ready], timeout: 10)
        guard let field else { return XCTFail("No Go to Folder field. \(app.debugDescription)") }
        field.typeKey("a", modifierFlags: .command)
        field.typeText(path)
        field.typeKey(.return, modifierFlags: [])
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: open)
        wait(for: [enabled], timeout: 10)
        open.click()
        XCTAssertTrue(waitGone(open), "The Open panel did not close")
    }

    func testBlockingAnAppClosesItWhenItOpens() {
        let chess = XCUIApplication(bundleIdentifier: "com.apple.Chess")
        if chess.state != .notRunning { chess.terminate() }
        let app = launchShield()

        // Lock In with only an app: blocked all day for the default hour.
        // Lock In lives in the ⋯ menu beside the blue +.
        let more = element("moreMenu", in: app)
        XCTAssertTrue(more.waitForExistence(timeout: 15))
        more.click()
        let add = element("lockInButton", in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()
        let addApp = element("blockAddApp", in: app)
        XCTAssertTrue(addApp.waitForExistence(timeout: 10), "Lock In has no Add App")
        addApp.click()
        choose(chessPath, in: app)
        XCTAssertTrue(element("lockInItem-Chess", in: app).waitForExistence(timeout: 10),
                      "Chess was not added. \(app.debugDescription)")
        let commit = element("commitFixtureFocus", in: app)
        XCTAssertEqual(commit.label, "Lock In")
        let review = element("lockInReview", in: app)
        XCTAssertTrue(review.waitForExistence(timeout: 5), "Lock In doesn't say what will happen")
        XCTAssertTrue("\(review.label) \(review.value ?? "")".contains("Chess is blocked all day"),
                      "The sentence doesn't say Chess is blocked: \(review.label)")
        attachScreen("01-lock-in-with-chess")
        XCTAssertTrue(commit.isEnabled, "An app-only Lock In must be creatable")
        commit.click()
        XCTAssertTrue(waitGone(commit), "Lock In did not close after the fixture confirmed")

        // The rule lists the app.
        let line = element(prefix: "ruleApps-", in: app)
        if !line.waitForExistence(timeout: 5) {
            let other = element("group-other", in: app)
            XCTAssertTrue(other.waitForExistence(timeout: 10))
            other.click()
        }
        XCTAssertTrue(line.waitForExistence(timeout: 10), "The new rule doesn't list its app. \(app.debugDescription)")
        XCTAssertEqual(line.value as? String, "Apps: Chess", "The rule line doesn't name Chess. \(line.debugDescription)")
        attachScreen("02-rule-lists-chess")

        // Opening Chess: Shield closes it within its 5-second refresh. Opened
        // through Launch Services, not XCUIApplication.launch(), which fails
        // when Shield closes the app before its accessibility loads.
        let launched = expectation(description: "Chess launched")
        var launchedPID: pid_t?
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: chessPath),
                                           configuration: NSWorkspace.OpenConfiguration()) { running, _ in
            launchedPID = running?.processIdentifier
            launched.fulfill()
        }
        wait(for: [launched], timeout: 15)
        XCTAssertNotNil(launchedPID, "Chess didn't launch at all")
        let closed = expectation(for: NSPredicate { _, _ in
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Chess").isEmpty
        }, evaluatedWith: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 20), .completed, "Chess stayed open")
        attachScreen("03-chess-closed")
    }

    // Allowed hours for an app: a category's New Daily Schedule holding only Chess.
    func testADailyScheduleCanHoldApps() {
        let app = launchShield()
        let social = element("group-social", in: app)
        XCTAssertTrue(social.waitForExistence(timeout: 15), "No Social media category")
        social.click()
        let menu = element("categoryAddMenu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "The category has no Add or Edit menu")
        menu.click()
        let newSchedule = app.menuItems["New Daily Schedule…"]
        XCTAssertTrue(newSchedule.waitForExistence(timeout: 5), "No New Daily Schedule in the category menu")
        newSchedule.click()
        let name = element("scheduleName", in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 10), "New Daily Schedule did not open")
        name.click()
        name.typeText("Chess")
        let addApp = element("blockAddApp", in: app)
        XCTAssertTrue(addApp.waitForExistence(timeout: 5), "New Daily Schedule has no Add App")
        addApp.click()
        choose(chessPath, in: app)
        XCTAssertTrue(element("blockApp-com.apple.Chess", in: app).waitForExistence(timeout: 10))
        let create = element("confirmAddSchedule", in: app)
        XCTAssertTrue(create.isEnabled, "An app-only schedule must be creatable")
        attachScreen("04-new-schedule-with-chess")
        create.click()
        XCTAssertTrue(waitGone(create), "New Daily Schedule did not close after the fixture confirmed")
        let line = element(prefix: "scheduleApps-", in: app)
        XCTAssertTrue(line.waitForExistence(timeout: 10), "The schedule doesn't list its app. \(app.debugDescription)")
        XCTAssertEqual(line.value as? String, "Apps: Chess")
        attachScreen("05-schedule-lists-chess")
    }
}
