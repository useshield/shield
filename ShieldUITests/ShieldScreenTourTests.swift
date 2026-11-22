import AppKit
import XCTest

// Evidence capture, not acceptance: walks every page and the main sheets of
// the simulated fixture and attaches a window screenshot of each. Nothing is
// submitted; every sheet is cancelled. Missing elements are recorded as
// "tour-missing-*" notes instead of failing, so the same tour can photograph
// both the baseline and a redesigned candidate.
final class ShieldScreenTourTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = true }

    private func launch(size: String, appearance: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_UI_POLISH_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_VISUAL_SIZE"] = size
        app.launchEnvironment["SHIELD_VISUAL_APPEARANCE"] = appearance
        app.launchEnvironment["SHIELD_UNCONFINED_TOOL_FIXTURE"] = "0"
        app.launchEnvironment["SHIELD_UI_TEST_PLACES"] = "1"
        app.launchEnvironment["SHIELD_UI_TEST_GO_START"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        addTeardownBlock { if app.state != .notRunning { app.terminate() } }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.activate()
        sleep(2)
        return app
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private var prefix = ""

    private func shot(_ name: String, _ app: XCUIApplication) {
        usleep(700_000)
        // A window screenshot leaves out an attached sheet, so a sheet is
        // photographed on its own.
        let sheet = app.sheets.firstMatch
        let image = sheet.exists ? sheet.screenshot() : app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = "\(prefix)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func note(_ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = "\(prefix)-tour-missing-\(text)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @discardableResult
    private func click(_ id: String, in app: XCUIApplication, timeout: TimeInterval = 6) -> Bool {
        let target = element(id, in: app)
        guard target.waitForExistence(timeout: timeout) else { note(id); return false }
        if target.isHittable { target.click() } else {
            target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        return true
    }

    private func go(_ section: String, _ app: XCUIApplication) {
        click("nav-" + section, in: app)
        sleep(1)
    }

    private func scrollDown(_ app: XCUIApplication) {
        let scroll = element("pageScrollView", in: app)
        guard scroll.exists else { return }
        scroll.scroll(byDeltaX: 0, deltaY: -1200)
    }

    private func closeSheet(_ app: XCUIApplication) {
        app.typeKey(.escape, modifierFlags: [])
        sleep(1)
        if app.sheets.count > 0 { app.typeKey(.escape, modifierFlags: []) ; sleep(1) }
    }

    private func back(_ app: XCUIApplication) {
        app.typeKey("[", modifierFlags: .command)
        sleep(1)
    }

    private func pages(_ app: XCUIApplication) {
        for section in ["protection", "places", "studylibrary", "diagnostics"] {
            go(section, app)
            shot("page-\(section)", app)
        }
    }

    private func fullTour(_ app: XCUIApplication) {
        go("protection", app)
        shot("protection-top", app)
        scrollDown(app)
        shot("protection-scrolled", app)

        for group in ["social", "video", "adult", "custom"] {
            go("protection", app)
            if click("group-" + group, in: app) {
                sleep(1)
                shot("group-\(group)", app)
                back(app)
            }
        }

        // Lock In (Protection only): a site added with Return, given allowed hours.
        go("protection", app)
        if click("moreMenu", in: app), click("lockInButton", in: app) {
            sleep(1)
            shot("sheet-lock-in", app)
            let sites = element("focusDomains", in: app)
            if sites.waitForExistence(timeout: 3) {
                sites.click(); sites.typeText("example.org\r")
                shot("sheet-lock-in-site", app)
            }
            let rule = element("lockInAccess-example.org", in: app)
            if rule.waitForExistence(timeout: 2) {
                rule.click()
                let hours = app.menuItems["Allowed only at certain hours"]
                if hours.waitForExistence(timeout: 2) {
                    hours.click()
                    shot("sheet-lock-in-hours", app)
                } else {
                    note("lock-in-hours")
                    app.typeKey(.escape, modifierFlags: [])
                }
            } else {
                note("lockInAccess-example.org")
            }
            closeSheet(app)
        }

        // The + menu: New Category and Go There Today only.
        // By identifier: the menu bar's File menu has its own "New Category…" (⌘N).
        for (item, name, menuID) in [("goThereToday", "go-there", "moreMenu"), ("addCategory", "new-category", "addMenu")] {
            go("protection", app)
            let add = element(menuID, in: app)
            guard add.waitForExistence(timeout: 5) else { note("addMenu"); continue }
            if add.menuButtons.count > 0 { add.menuButtons.firstMatch.click() } else { add.click() }
            let entry = element(item, in: app)
            if entry.waitForExistence(timeout: 3) {
                entry.click(); sleep(1)
                shot("sheet-\(name)", app)
                closeSheet(app)
            } else {
                note("menu-\(name)")
                app.typeKey(.escape, modifierFlags: [])
            }
        }

        // A category's one menu: New Block, New Daily Schedule, Edit Category.
        for (item, name) in [("New Block…", "new-block"), ("New Daily Schedule…", "new-schedule"),
                             ("Edit Category…", "edit-category")] {
            go("protection", app)
            guard click("group-social", in: app) else { continue }
            sleep(1)
            let menu = element("categoryAddMenu", in: app)
            guard menu.waitForExistence(timeout: 5) else { note("categoryAddMenu"); back(app); continue }
            if menu.menuButtons.count > 0 { menu.menuButtons.firstMatch.click() } else { menu.click() }
            let entry = app.menuItems[item]
            if entry.waitForExistence(timeout: 3) {
                entry.click(); sleep(1)
                shot("sheet-\(name)", app)
                closeSheet(app)
            } else {
                note("category-menu-\(name)")
                app.typeKey(.escape, modifierFlags: [])
            }
            back(app)
        }

        // Allowed hours editor from the social category.
        go("protection", app)
        if click("group-social", in: app) {
            sleep(1)
            if click("scheduleWebsites-social-afternoon", in: app, timeout: 3) {
                shot("row-websites", app)
            }
            if click("editPreparedSchedule-social-afternoon", in: app, timeout: 3) {
                shot("menu-schedule-edit", app)
                let hours = app.menuItems["Hours…"]
                if hours.waitForExistence(timeout: 2) {
                    hours.click()
                    shot("sheet-allowed-hours", app)
                    closeSheet(app)
                } else {
                    app.typeKey(.escape, modifierFlags: [])
                }
            }
            back(app)
        }

        // Places and Add on Map.
        go("places", app)
        shot("places", app)
        if click("place-test-library", in: app, timeout: 3) {
            sleep(2)
            shot("place-detail", app)
            if click("placeAddMenu", in: app, timeout: 2) {
                shot("sheet-new-block-at-place", app)
                closeSheet(app)
            }
            back(app)
        }
        if click("addPlaceOnMap", in: app, timeout: 4) || click("addFirstPlace", in: app, timeout: 2) {
            sleep(2)
            shot("sheet-add-place-map", app)
            closeSheet(app)
        }

        go("studylibrary", app)
        shot("library", app)
        if click("addVideos", in: app, timeout: 4) {
            sleep(1)
            shot("sheet-add-videos", app)
            closeSheet(app)
        }

        go("diagnostics", app)
        shot("settings", app)
        if click("serviceDetails", in: app, timeout: 3) {
            scrollDown(app)
            shot("settings-technical", app)
        }
    }

    func testTourStandardLight() {
        prefix = "light-standard"
        fullTour(launch(size: "standard", appearance: "light"))
    }

    func testTourStandardDark() {
        prefix = "dark-standard"
        fullTour(launch(size: "standard", appearance: "dark"))
    }

    func testTourSizes() {
        for size in ["compact", "wide"] {
            for appearance in ["light", "dark"] {
                prefix = "\(appearance)-\(size)"
                let app = launch(size: size, appearance: appearance)
                pages(app)
                app.terminate()
            }
        }
    }
}
