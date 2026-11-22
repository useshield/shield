import AppKit
import XCTest

// Source-only acceptance for Library and collections. The visual fixture is
// a throwaway simulated library in a temporary folder; nothing is fetched
// and installed Shield RC is never used.
final class ShieldDownloadsFlowTests: XCTestCase {
    // The first two videos in Library, read from the screen (two added links).
    private var lesson1 = "", lesson2 = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_UI_POLISH_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_VISUAL_SIZE"] = "wide"
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

    private func waitGone(_ target: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: target)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private func waitForTitle(_ title: String, in app: XCUIApplication) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            // The window title also carries the subtitle ("… – 23 videos").
            let current = app.windows.firstMatch.title
            if current == title || current.hasPrefix(title + " –") { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }

    private func chooseMenuItem(_ title: String, app: XCUIApplication) {
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Missing menu item \(title)")
        item.click()
    }

    /// Library opens on its collection tiles; All Videos lists every video.
    private func showAllVideos(_ app: XCUIApplication) {
        // Already on All Videos (clicking Library while on it keeps the list).
        if element("backToLibraryHome", in: app).waitForExistence(timeout: 2) { return }
        let all = element("showAllVideos", in: app)
        XCTAssertTrue(all.waitForExistence(timeout: 8), "Library has no All Videos tile")
        all.click()
    }

    private func openVideoMenu(_ id: String, app: XCUIApplication) {
        let menu = element("videoActions-\(id)", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 8), "Missing actions for \(id)")
        menu.click()
    }

    func testLibraryCollectionsAddRenameDeleteFlow() {
        let app = launchFixture()

        // 1. Library opens empty (Shield ships no course); add two videos by link.
        let nav = element("nav-studylibrary", in: app)
        XCTAssertTrue(nav.waitForExistence(timeout: 12))
        nav.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(element("emptyCollection", in: app).waitForExistence(timeout: 2) ||
                      element("localImportPrerequisite", in: app).waitForExistence(timeout: 10),
                      "Library should open empty. \(app.debugDescription)")
        attachScreen("01-empty-library")
        XCTAssertFalse(element("addCatalogCourse", in: app).exists, "Shield offers no built-in course")
        element("addVideos", in: app).click()
        let field = element("youtubeLinkInput", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText("https://youtu.be/cdefghijklm https://youtu.be/defghijklmn")
        element("queueYouTubeLinks", in: app).click()
        let rows = element(prefix: "videoActions-", in: app)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        let ids = rows.allElementsBoundByIndex.map { String($0.identifier.dropFirst("videoActions-".count)) }
        XCTAssertGreaterThanOrEqual(ids.count, 2)
        lesson1 = ids[0]
        lesson2 = ids[1]
        attachScreen("02-library-filled")

        // 3. A new collection becomes the selection and explains how to fill it.
        element("downloadsMenu", in: app).click()
        chooseMenuItem("New Collection…", app: app)
        let name = element("collectionName", in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        name.click()
        name.typeText("Review later")
        element("collectionColor-orange", in: app).click()
        element("saveCollection", in: app).click()
        XCTAssertTrue(waitGone(element("saveCollection", in: app)))
        XCTAssertTrue(waitForTitle("Review later", in: app), "New collection not selected")
        XCTAssertTrue(element("emptyCollection", in: app).waitForExistence(timeout: 5))
        let review = element(prefix: "collection-collection-", in: app).firstMatch
        XCTAssertTrue(review.exists, "New collection missing from the sidebar")

        // 4. Links added from the toolbar land in the collection being viewed.
        element("addVideos", in: app).click()
        let links = element("youtubeLinkInput", in: app)
        XCTAssertTrue(links.waitForExistence(timeout: 5), "Add popover did not open")
        links.click()
        links.typeText("https://youtu.be/abcdefghijk https://youtu.be/bcdefghijkl")
        element("queueYouTubeLinks", in: app).click()
        XCTAssertTrue(element("videoActions-abcdefghijk", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("videoActions-bcdefghijkl", in: app).exists)
        XCTAssertTrue(waitForTitle("Review later", in: app), "Adding must not navigate away")
        attachScreen("03-links-added")

        // 5. Library holds everything once.
        nav.click()
        XCTAssertTrue(waitForTitle("Library", in: app))
        showAllVideos(app)
        XCTAssertTrue(element("videoActions-abcdefghijk", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("videoActions-\(lesson1)", in: app).exists)

        // 6. Add a course lesson to Review later from its menu.
        openVideoMenu(lesson1, app: app)
        let addTo = app.menuItems["Add to Collection"]
        XCTAssertTrue(addTo.waitForExistence(timeout: 5))
        addTo.hover()
        chooseMenuItem("Review later", app: app)
        review.click()
        XCTAssertTrue(waitForTitle("Review later", in: app))
        XCTAssertTrue(element("videoActions-\(lesson1)", in: app).waitForExistence(timeout: 8))

        // 7. Rename it; the field opens focused with the current name selected.
        openVideoMenu(lesson1, app: app)
        chooseMenuItem("Rename…", app: app)
        XCTAssertTrue(app.staticTexts["Rename Video"].waitForExistence(timeout: 5), "Rename alert missing")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("Lesson one (review)")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Lesson one (review)"].waitForExistence(timeout: 5), "Renamed title not shown")
        attachScreen("04-renamed")

        // 8. Removing from this collection keeps it in the library.
        openVideoMenu(lesson1, app: app)
        chooseMenuItem("Remove from “Review later”", app: app)
        XCTAssertTrue(waitGone(element("videoActions-\(lesson1)", in: app)))

        // 9. Deleting a video removes it from the library.
        nav.click()
        XCTAssertTrue(waitForTitle("Library", in: app))
        showAllVideos(app)
        openVideoMenu(lesson2, app: app)
        chooseMenuItem("Delete Video…", app: app)
        let confirm = element("confirmDeleteVideo", in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete confirmation missing")
        confirm.click()
        XCTAssertTrue(waitGone(element("videoActions-\(lesson2)", in: app)))
        XCTAssertTrue(element("videoActions-\(lesson1)", in: app).exists, "Removed-from-collection video stays")

        // 10. Deleting a collection from the sidebar keeps its videos.
        review.rightClick()
        chooseMenuItem("Delete Collection…", app: app)
        let deleteCollection = element("confirmDeleteCollection", in: app)
        XCTAssertTrue(deleteCollection.waitForExistence(timeout: 5))
        deleteCollection.click()
        XCTAssertTrue(waitGone(review), "Deleted collection still in the sidebar")
        nav.click()
        showAllVideos(app)
        XCTAssertTrue(element("videoActions-abcdefghijk", in: app).waitForExistence(timeout: 8),
                      "Videos of a deleted collection stay in Library")
        attachScreen("05-after-deletes")
    }
}
