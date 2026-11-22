import AppKit
import XCTest

// Source-only acceptance for the native redesign. The launch environment
// creates an isolated fixture; these tests never use installed Shield RC.
// Page titles live in the window toolbar (navigationTitle), so the window
// title is the page heading; `pageScrollView` anchors each page's content.
final class ShieldUIRebuildAcceptanceTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchFixture(size: String = "compact", appearance: String = "light") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_UI_POLISH_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_VISUAL_SIZE"] = size
        app.launchEnvironment["SHIELD_VISUAL_APPEARANCE"] = appearance
        app.launchEnvironment["SHIELD_UNCONFINED_TOOL_FIXTURE"] = "0"
        // Never inherit a window state (fullscreen, closed) from an earlier run.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        addTeardownBlock {
            if app.state != .notRunning { app.terminate() }
        }
        requireFrontmostWindow(app)
        return app
    }

    // macOS cooperative activation can leave a freshly launched app behind
    // the user's frontmost window (Oct 26: Chrome kept activation, so the
    // Shield window was fully covered and a swipe scrolled Chrome instead).
    // Occlusion by another app is not a Shield defect, but no geometry or
    // gesture assertion is meaningful until the window is actually in front.
    private func requireFrontmostWindow(_ app: XCUIApplication,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15),
                      "Shield window never appeared", file: file, line: line)
        let frontmost = expectation(for: NSPredicate { _, _ in
            if app.state != .runningForeground || !window.isHittable { app.activate() }
            return app.state == .runningForeground && window.isHittable
        }, evaluatedWith: app)
        guard XCTWaiter.wait(for: [frontmost], timeout: 15) != .completed else { return }
        attachScreen("not-frontmost-full-screen")
        XCTFail("Shield window could not be brought in front of other apps; " +
                "test environment is not usable (see not-frontmost-full-screen)",
                file: file, line: line)
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

    // A window screenshot cannot show what covers the app. Oct 22 and Oct 26
    // "obstructed" failures were a hidden window and a system Screen Time
    // overlay, so obstruction failures attach the whole screen as evidence.
    private func assertUnobstructed(_ target: XCUIElement, _ message: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard !target.isHittable else { return }
        attachScreen("obstructed-full-screen")
        XCTFail(message + " (see obstructed-full-screen attachment)", file: file, line: line)
    }

    private func title(_ app: XCUIApplication) -> String { app.windows.firstMatch.title }

    private func waitForTitle(_ heading: String, in app: XCUIApplication, timeout: TimeInterval = 12) -> Bool {
        let window = app.windows.firstMatch
        let changed = expectation(for: NSPredicate { _, _ in window.title == heading }, evaluatedWith: window)
        return XCTWaiter.wait(for: [changed], timeout: timeout) == .completed
    }

    private func navigate(_ id: String, heading: String, app: XCUIApplication) {
        XCTAssertTrue(element("pageScrollView", in: app).waitForExistence(timeout: 12),
                      "Initial page content is missing: \(app.debugDescription)")
        // The initially selected Protection item need not be clicked to test
        // that the page is already displayed; subsequent items MUST navigate.
        if title(app) == heading { return }

        let destination = element("nav-" + id, in: app)
        XCTAssertTrue(destination.waitForExistence(timeout: 12),
                      "Missing native sidebar destination nav-\(id). \(app.debugDescription)")
        let window = app.windows.firstMatch
        let bounds = destination.frame
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let visible = bounds.width >= 16 && bounds.height >= 12 && window.frame.contains(center)
        if !visible { attachScreen("unreachable-sidebar-\(id)") }
        XCTAssertTrue(visible, "Native sidebar target nav-\(id) has no visible hit region. " +
                      "Frame=\(bounds) window=\(window.frame)")
        NSLog("SHIELD_UI_NAV destination=%@ type=%@ isHittable=%d bounds=%@",
              id, String(describing: destination.elementType),
              destination.isHittable ? 1 : 0, NSStringFromRect(bounds))
        if destination.isHittable {
            destination.click()
        } else {
            // Mouse-coordinate click is valid for a visible native List row,
            // unlike XCTest's AX hittability check on a nested Label.
            destination.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        if !waitForTitle(heading, in: app) {
            attachScreen("navigation-failed-\(id)")
            NSLog("SHIELD_UI_NAVIGATION_FAILED destination=%@ hierarchy=%@", id, app.debugDescription)
        }
        XCTAssertEqual(title(app), heading, "Clicking native sidebar nav-\(id) must display \(heading)")
        XCTAssertTrue(element("pageScrollView", in: app).waitForExistence(timeout: 12),
                      "\(heading) page content missing")
    }

    private func scrollTo(_ target: XCUIElement, in app: XCUIApplication, up: Bool = true) {
        let scroll = element("pageScrollView", in: app)
        for _ in 0..<8 where !target.isHittable {
            if up { scroll.swipeUp() } else { scroll.swipeDown() }
        }
    }

    private func openGroup(_ id: String, in app: XCUIApplication) {
        let row = element("group-" + id, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 12), "Missing group \(id). \(app.debugDescription)")
        scrollTo(row, in: app)
        XCTAssertTrue(row.isHittable, "Group \(id) must be reachable")
        let before = title(app)
        row.click()
        XCTAssertTrue(element("categoryAddMenu", in: app).waitForExistence(timeout: 12),
                      "Group \(id) did not open")
        XCTAssertNotEqual(title(app), before, "Drill-down must change the page title")
    }

    // The system back button in the toolbar (NavigationStack), not a custom link.
    private func back(_ app: XCUIApplication, to heading: String) {
        let window = app.windows.firstMatch
        let back = window.toolbars.buttons.matching(NSPredicate(format:
            "label ==[c] 'Back' OR identifier ==[c] 'Back' OR identifier CONTAINS[c] 'back'")).firstMatch
        if back.waitForExistence(timeout: 5) && back.isHittable {
            back.click()
        } else {
            NSLog("SHIELD_UI_BACK_FALLBACK toolbar=%@", window.toolbars.firstMatch.debugDescription)
            app.typeKey("[", modifierFlags: .command)
        }
        XCTAssertTrue(waitForTitle(heading, in: app), "Back must return to \(heading); got \(title(app))")
        XCTAssertFalse(element("categoryAddMenu", in: app).exists)
    }

    // Settings › Advanced › Technical details shows the committed state:
    // owners, recurring windows and pending releases. Unchanged counts prove
    // nothing was submitted. The generation also advances on routine
    // maintenance (heartbeat, schedule boundaries), so it is only checked
    // never to go backwards.
    private struct PolicyCounters: Equatable {
        var owners: Int, windows: Int, pending: Int
        var generation: Int
        static func == (l: Self, r: Self) -> Bool {
            l.owners == r.owners && l.windows == r.windows && l.pending == r.pending
        }
    }

    private func policyCounters(_ app: XCUIApplication) -> PolicyCounters {
        navigate("diagnostics", heading: "Settings", app: app)
        // The disclosure title is a button whose value reports its state.
        let details = element("serviceDetails", in: app)
        XCTAssertTrue(details.waitForExistence(timeout: 10), "Missing Technical details")
        scrollTo(details, in: app)
        // A native disclosure triangle reports 1 when expanded.
        func isExpanded() -> Bool { (details.value as? NSNumber)?.intValue == 1 || details.value as? String == "1" }
        if !isExpanded() { details.click() }
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate { _, _ in
            isExpanded() }, evaluatedWith: details)], timeout: 5), .completed,
                       "Technical details did not expand")
        let generation = element("receiptGeneration", in: app)
        scrollTo(generation, in: app)
        XCTAssertTrue(generation.waitForExistence(timeout: 10),
                      "Receipt generation missing: \(app.debugDescription)")
        let pending = element("pendingReleaseCount", in: app)
        XCTAssertTrue(pending.exists, "Pending release count missing")
        // Static text carries its words in AXValue (sometimes only the label).
        func number(_ text: XCUIElement) -> Int {
            let words = [text.value as? String ?? "", text.label].joined(separator: " ")
            return words.split(whereSeparator: { !$0.isNumber }).last.flatMap { Int($0) } ?? -1
        }
        let counters = PolicyCounters(owners: number(element("committedOwnerCount", in: app)),
                                      windows: number(element("recurringWindowCount", in: app)),
                                      pending: number(pending), generation: number(generation))
        XCTAssertTrue(counters.owners >= 0 && counters.windows >= 0 && counters.pending >= 0 && counters.generation > 0,
                      "Unreadable policy counters: \(counters)")
        return counters
    }

    private func waitUntilGone(_ target: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: target)],
                       timeout: timeout) == .completed
    }

    func testFiveProtectionGroupsAndBothAdultOwners() {
        let app = launchFixture()
        XCTAssertTrue(waitForTitle("Protection", in: app, timeout: 15))
        XCTAssertTrue(app.staticTexts["reviewModeText"].waitForExistence(timeout: 15),
                      "Must exercise UI Review, not installed Shield")
        XCTAssertFalse(app.staticTexts["Rules active"].exists,
                       "Fixture must not look production-confirmed")
        for id in ["social", "video", "adult", "food", "custom"] {
            XCTAssertTrue(element("group-" + id, in: app).waitForExistence(timeout: 12),
                          "Missing expected group: \(id)")
        }
        openGroup("adult", in: app)
        // The adult list (split by size into parts) shows as one card in its
        // group. That both parts survive as one card is pinned by the unit
        // test NamesAndCombineTests.ownerPlanPartsShowAsOneCard; here it
        // must simply be there and openable.
        XCTAssertTrue(element(prefix: "ruleWebsites-", in: app).waitForExistence(timeout: 5),
                      "The Adult content group shows no list")
        back(app, to: "Protection")
        openGroup("social", in: app)
        for id in ["social-afternoon", "instagram-afternoon", "tiktok-afternoon", "pinterest-afternoon"] {
            XCTAssertTrue(element("confirmedScheduleHours-" + id, in: app).exists,
                          "Missing social rule \(id)")
        }
        back(app, to: "Protection")
        // Lock In opens so a reviewer can see it, but UI Review can't commit.
        element("moreMenu", in: app).click()
        XCTAssertTrue(element("lockInButton", in: app).waitForExistence(timeout: 5), "Lock In missing from ⋯")
        element("lockInButton", in: app).click()
        let commit = element("commitFixtureFocus", in: app)
        XCTAssertTrue(commit.waitForExistence(timeout: 8), "Lock In did not open")
        XCTAssertFalse(commit.isEnabled, "UI Review cannot change protection")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testScheduleGroupsAndSixAllowedWindows() {
        let app = launchFixture()
        navigate("protection", heading: "Protection", app: app)
        XCTAssertTrue(element("protectionStatus", in: app).exists)
        // Each category's page shows its schedules with ALLOWED hours.
        let expected = ["social": ["social-afternoon": "2:00", "instagram-afternoon": "2:00",
                                   "tiktok-afternoon": "2:00", "pinterest-afternoon": "4:00"],
                        "video": ["netflix-evening": "5:00", "youtube-evening": "6:00"]]
        for (group, schedules) in expected {
            openGroup(group, in: app)
            for (id, start) in schedules {
                let hours = element("confirmedScheduleHours-" + id, in: app)
                XCTAssertTrue(hours.exists, "Missing allowed hours for \(id)")
                XCTAssertTrue(hours.label.localizedCaseInsensitiveContains("Allowed"),
                              "Should show allowed, not blocked hours: \(hours.label)")
                XCTAssertTrue(hours.label.contains(start), "\(id) should be allowed from \(start): \(hours.label)")
            }
            if group == "video" {
                // A read-only preview must never offer a functional commit action.
                // Edit opens; every change in it that commits stays off.
                let edit = element("editPreparedSchedule-youtube-evening", in: app)
                XCTAssertTrue(edit.exists)
                edit.click()
                for item in ["Hours…", "Websites…", "Remove Schedule…"] {
                    let menuItem = app.menuItems[item]
                    XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "Edit is missing \(item)")
                    XCTAssertFalse(menuItem.isEnabled, "\(item) must be off in the read-only preview")
                }
                app.typeKey(.escape, modifierFlags: [])
            }
            back(app, to: "Protection")
        }
        openGroup("adult", in: app)
        XCTAssertFalse(element("confirmedScheduleHours-owner-plan-adult-1", in: app).exists,
                       "Permanent categories must not appear as schedules")
        back(app, to: "Protection")
    }

    func testNativeSidebarNavigationAndFixedPageHeading() {
        for size in ["compact", "standard"] {
            let app = launchFixture(size: size)
            for (destination, heading) in [
                ("protection", "Protection"),
                ("studylibrary", "Library"),
                ("diagnostics", "Settings")
            ] {
                navigate(destination, heading: heading, app: app)
                let window = app.windows.firstMatch
                let toolbar = window.toolbars.firstMatch
                let toolbarY = toolbar.exists ? toolbar.frame.minY : window.frame.minY
                let scroll = element("pageScrollView", in: app)
                XCTAssertTrue(scroll.exists)
                if scroll.isHittable { scroll.swipeUp() }
                // The heading is the toolbar title: it must survive scrolling
                // unchanged and stay in place with the window chrome.
                XCTAssertEqual(title(app), heading, "\(size) \(heading) title changed while scrolling")
                assertUnobstructed(window, "\(size) \(heading) window obscured")
                if toolbar.exists {
                    XCTAssertEqual(toolbar.frame.minY, toolbarY, accuracy: 4,
                                   "\(size) \(heading) toolbar moved when scrolling")
                }
            }
            app.terminate()
        }
    }

    // Owner visual review evidence: every page at compact, standard and wide
    // widths in light and dark, reached by real sidebar clicks, plus a group
    // drill-down. Window-element screenshots only (never other apps' content).
    func testVisualReviewAcrossWidthsAndAppearances() {
        for appearance in ["light", "dark"] {
            for size in ["compact", "standard", "wide"] {
                let app = launchFixture(size: size, appearance: appearance)
                let window = app.windows.firstMatch
                // The sizer applies its final size 1.5 s after launch.
                let settled = expectation(for: NSPredicate { _, _ in
                    let width = window.frame.width
                    switch size {
                    case "compact": return width < 900
                    case "wide": return width > 1600
                    default: return width > 950 && width < 1100
                    }
                }, evaluatedWith: window)
                XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed,
                               "\(size) window never reached its size: \(window.frame)")
                func capture(_ name: String) {
                    let shot = XCTAttachment(screenshot: window.screenshot())
                    shot.name = "\(appearance)-\(size)-\(name)"
                    shot.lifetime = .keepAlways
                    add(shot)
                }
                for (destination, heading) in [("protection", "Protection"), ("studylibrary", "Library"), ("diagnostics", "Settings")] {
                    navigate(destination, heading: heading, app: app)
                    capture("\(destination)-top")
                    // Drill down before scrolling: openGroup only scrolls forward.
                    if destination == "protection" {
                        openGroup("social", in: app)
                        capture("protection-social-group")
                        back(app, to: "Protection")
                    }
                    let scroll = element("pageScrollView", in: app)
                    if scroll.isHittable {
                        scroll.swipeUp()
                        capture("\(destination)-scrolled")
                    }
                    XCTAssertEqual(title(app), heading)
                    assertUnobstructed(window, "\(appearance) \(size) \(heading) window obscured")
                }
                app.terminate()
            }
        }
    }

    // Keyboard-only page navigation: arrow keys move the native sidebar
    // selection, ⌘[ is the system Back for drill-downs. The first click only
    // gives the sidebar focus on the already-selected row.
    func testKeyboardNavigation() {
        let app = launchFixture(size: "standard")
        XCTAssertTrue(waitForTitle("Protection", in: app, timeout: 15))
        app.typeKey(.downArrow, modifierFlags: [])
        let initialFocusInSidebar = waitForTitle("Places", in: app, timeout: 3)
        NSLog("SHIELD_UI_KEYBOARD initialFocusInSidebar=%d", initialFocusInSidebar ? 1 : 0)
        if !initialFocusInSidebar {
            XCTAssertEqual(title(app), "Protection", "A stray arrow key must not change pages elsewhere")
            element("nav-protection", in: app).click()
            XCTAssertTrue(waitForTitle("Protection", in: app))
            app.typeKey(.downArrow, modifierFlags: [])
            XCTAssertTrue(waitForTitle("Places", in: app), "↓ must select Places")
        }
        for heading in ["Library", "Settings"] {
            app.typeKey(.downArrow, modifierFlags: [])
            XCTAssertTrue(waitForTitle(heading, in: app), "↓ must select \(heading); got \(title(app))")
        }
        for heading in ["Library", "Places", "Protection"] {
            app.typeKey(.upArrow, modifierFlags: [])
            XCTAssertTrue(waitForTitle(heading, in: app), "↑ must select \(heading); got \(title(app))")
        }
        openGroup("video", in: app)
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(waitForTitle("Protection", in: app), "⌘[ must go back; got \(title(app))")
        XCTAssertFalse(element("categoryAddMenu", in: app).exists)
        // ⌘N makes a category (presentation only); it never opens a sheet that changes protection.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertFalse(element("focusDomains", in: app).waitForExistence(timeout: 2),
                       "⌘N must not open Lock In")
        XCTAssertFalse(element("newBlockDomains", in: app).exists, "⌘N must not open New Block")
        if element("categoryName", in: app).exists { app.typeKey(.escape, modifierFlags: []) }
    }

    // True macOS fullscreen (its own Space), light and dark: every page and a
    // drill-down must lay out with the sidebar and toolbar title intact.
    func testTrueFullscreenLayout() {
        let screen = NSScreen.main?.frame ?? .zero
        // On a display with a camera housing, fullscreen content sits below it.
        let topInset = NSScreen.main?.safeAreaInsets.top ?? 0
        XCTAssertGreaterThan(screen.width, 0)
        for appearance in ["light", "dark"] {
            let app = launchFixture(size: "standard", appearance: appearance)
            let window = app.windows.firstMatch
            XCTAssertTrue(waitForTitle("Protection", in: app, timeout: 15))
            // The fixture sizer settles 1.5 s after launch; enter fullscreen after it.
            let settled = expectation(for: NSPredicate { _, _ in
                window.frame.width > 950 && window.frame.width < 1100 }, evaluatedWith: window)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed)
            sleep(2)
            // The window's green button, as a person would use it.
            let green = window.buttons["_XCUI:FullScreenWindow"]
            XCTAssertTrue(green.exists, "Window must offer the fullscreen button")
            green.click()
            let fullscreen = expectation(for: NSPredicate { _, _ in
                window.frame.width >= screen.width - 1 && window.frame.height >= screen.height - topInset - 1
            }, evaluatedWith: window)
            XCTAssertEqual(XCTWaiter.wait(for: [fullscreen], timeout: 10), .completed,
                           "\(appearance): window never entered fullscreen: \(window.frame) screen \(screen)")
            sleep(1) // Let the Space transition finish before capturing.
            func capture(_ name: String) {
                let shot = XCTAttachment(screenshot: window.screenshot())
                shot.name = "\(appearance)-fullscreen-\(name)"
                shot.lifetime = .keepAlways
                add(shot)
            }
            for (destination, heading) in [("protection", "Protection"), ("studylibrary", "Library"), ("diagnostics", "Settings")] {
                navigate(destination, heading: heading, app: app)
                capture("\(destination)-top")
                if destination == "protection" {
                    openGroup("social", in: app)
                    capture("protection-social-group")
                    back(app, to: "Protection")
                }
                let scroll = element("pageScrollView", in: app)
                if scroll.isHittable { scroll.swipeUp(); capture("\(destination)-scrolled") }
                XCTAssertEqual(title(app), heading)
                // The approved sidebar: Protection, Library, Settings (Places is hidden in UI Review).
                for id in ["protection", "studylibrary", "diagnostics"] {
                    XCTAssertTrue(window.frame.contains(element("nav-" + id, in: app).frame),
                                  "\(appearance) fullscreen: sidebar row \(id) must stay visible")
                }
                assertUnobstructed(window, "\(appearance) fullscreen \(heading) window obscured")
            }
            // Leave fullscreen the standard ways: ⌃⌘F, then View › Exit Full Screen.
            func windowed(within seconds: TimeInterval) -> Bool {
                XCTWaiter.wait(for: [expectation(for: NSPredicate { _, _ in window.frame.width < screen.width - 1 },
                                                 evaluatedWith: window)], timeout: seconds) == .completed
            }
            app.typeKey("f", modifierFlags: [.command, .control])
            if !windowed(within: 6) {
                NSLog("SHIELD_UI_FULLSCREEN_EXIT shortcut did not exit; using the View menu")
                app.menuBars.menuBarItems["View"].click()
                app.menuItems["toggleFullScreen:"].firstMatch.click()
            }
            XCTAssertTrue(windowed(within: 10), "\(appearance): window never left fullscreen")
            app.terminate()
        }
    }

    // XCTest's accessibility audit on every page and a drill-down, in light
    // and dark. Issues are attached as a report; issues on Shield's own
    // identified content fail the test, system chrome findings are reported.
    func testAccessibilityAudit() throws {
        var report: [String] = []
        var failures: [String] = []
        for appearance in ["light", "dark"] {
            let app = launchFixture(size: "standard", appearance: appearance)
            for (destination, heading) in [("protection", "Protection"), ("studylibrary", "Library"), ("diagnostics", "Settings"),
                                           ("social-group", "Social media")] {
                if destination == "social-group" {
                    navigate("protection", heading: "Protection", app: app)
                    openGroup("social", in: app)
                } else {
                    navigate(destination, heading: heading, app: app)
                }
                // Contrast is only meaningful for text actually drawn on screen;
                // rows scrolled outside the page are reported, not enforced.
                let visibleArea = element("pageScrollView", in: app).frame
                    .intersection(app.windows.firstMatch.frame)
                let page = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
                page.name = "audit-\(appearance)-\(destination)"
                page.lifetime = .keepAlways
                add(page)
                try app.performAccessibilityAudit { issue in
                    let target = issue.element
                    let identifier = target?.identifier ?? ""
                    let value = (target?.value as? String).map { String($0.prefix(60)) } ?? "-"
                    let line = "\(appearance) \(destination) [\(issue.auditType.rawValue)] " +
                        "\(issue.compactDescription) | id=\(identifier) " +
                        "type=\(target.map { String(describing: $0.elementType.rawValue) } ?? "-") " +
                        "label=\(target?.label ?? "-") value=\(value) " +
                        "frame=\(target.map { NSStringFromRect($0.frame) } ?? "-") " +
                        "enabled=\(target?.isEnabled ?? true) | \(issue.detailedDescription)"
                    report.append(line)
                    // Gate policy: any issue on Shield's own identified content
                    // fails, except contrast that "nearly passed" (the system
                    // secondary label colour) and the audit's missing-press
                    // report for SwiftUI menu buttons and pop-up buttons, which open via AXShowMenu.
                    let nearlyPassed = issue.compactDescription.localizedCaseInsensitiveContains("nearly passed")
                    // Pop-up buttons (a Form's menu Picker) open the same way.
                    let menuButton = [.menuButton, .popUpButton].contains(target?.elementType ?? .any) &&
                        issue.auditType == .action
                    let onScreen = target.map { visibleArea.contains($0.frame) } ?? false
                    let contrastFailed = issue.auditType == .contrast && !nearlyPassed &&
                        (target?.isEnabled ?? true) && onScreen
                    let enforced = issue.auditType == .contrast ? contrastFailed : (!identifier.isEmpty && !menuButton)
                    if enforced {
                        failures.append(line)
                    }
                    return true
                }
                if destination == "social-group" { back(app, to: "Protection") }
            }
            app.terminate()
        }
        let attachment = XCTAttachment(string: report.isEmpty ? "No accessibility audit issues." :
                                        report.joined(separator: "\n"))
        attachment.name = "accessibility-audit-report.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        NSLog("SHIELD_AX_AUDIT issues=%d identified=%d", report.count, failures.count)
        XCTAssertTrue(failures.isEmpty, "Accessibility issues on Shield content:\n" + failures.joined(separator: "\n"))
    }

    // Basic VoiceOver semantics without toggling VoiceOver: every sidebar
    // destination, group row and timeline exposes a meaningful label.
    func testVoiceOverLabels() {
        let app = launchFixture(size: "standard")
        XCTAssertTrue(waitForTitle("Protection", in: app, timeout: 15))
        for (id, label) in [("protection", "Protection"), ("studylibrary", "Library"), ("diagnostics", "Settings")] {
            let row = element("nav-" + id, in: app)
            XCTAssertTrue(row.exists)
            let spoken = [row.label, row.value as? String ?? ""].joined(separator: " ")
                + row.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
            XCTAssertTrue(spoken.contains(label), "Sidebar \(id) must speak \(label): \(spoken)")
        }
        for id in ["social", "video", "adult", "food", "custom"] {
            let row = element("group-" + id, in: app)
            let spoken = row.label + " " + row.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
            XCTAssertFalse(spoken.trimmingCharacters(in: .whitespaces).isEmpty, "Group \(id) has no spoken label")
        }
        navigate("protection", heading: "Protection", app: app)
        for (group, ids) in [("social", ["social-afternoon", "instagram-afternoon", "tiktok-afternoon",
                                          "pinterest-afternoon"]),
                             ("video", ["netflix-evening", "youtube-evening"])] {
            openGroup(group, in: app)
            for id in ids {
                let hours = element("confirmedScheduleHours-" + id, in: app)
                XCTAssertTrue(hours.label.localizedCaseInsensitiveContains("Allowed"),
                              "\(id) must be spoken as allowed hours: \(hours.label)")
            }
            back(app, to: "Protection")
        }
        let images = app.images.allElementsBoundByIndex.filter { $0.exists && $0.isHittable && $0.label.isEmpty }
        XCTAssertTrue(images.isEmpty, "Unlabelled visible images: \(images.map(\.debugDescription))")
    }

    #if !UI_REVIEW
    // Development fixture (isolated temporary backend, simulated rules only):
    // the complete editing flows. Nothing here can reach installed authority.
    func testEditingFlowsCancelCreateDrillDownAndHours() {
        let app = launchFixture(size: "standard")
        XCTAssertTrue(app.staticTexts["developmentModeText"].waitForExistence(timeout: 15),
                      "Editing flows must run against the Development fixture")
        XCTAssertTrue(waitForTitle("Protection", in: app, timeout: 15))
        let initial = policyCounters(app)
        navigate("protection", heading: "Protection", app: app)
        let groupsBefore = ["social", "video", "adult", "food", "custom", "other"]
            .filter { element("group-" + $0, in: app).exists }

        // Lock In → Cancel changes nothing.
        let more = element("moreMenu", in: app)
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.click()
        let add = element("lockInButton", in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(add.isEnabled, "Development fixture must allow Lock In")
        let newBlock = add
        newBlock.click()
        let domains = element("focusDomains", in: app)
        XCTAssertTrue(domains.waitForExistence(timeout: 10), "Lock In sheet did not open")
        domains.click(); domains.typeText("cancelled.example")
        element("cancelBlockEditor", in: app).click()
        XCTAssertTrue(NSPredicate(format: "exists == false").evaluate(with: domains) ||
                      XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"),
                                                       evaluatedWith: domains)], timeout: 5) == .completed,
                      "Cancel must close the sheet")
        let groupsAfterCancel = ["social", "video", "adult", "food", "custom", "other"]
            .filter { element("group-" + $0, in: app).exists }
        XCTAssertEqual(groupsAfterCancel, groupsBefore, "Cancel must not add or remove rules")
        XCTAssertFalse(app.staticTexts["cancelled.example"].exists)

        // Keyboard: ⌘N opens New Category, Escape cancels it.
        app.typeKey("n", modifierFlags: .command)
        let categoryName = element("categoryName", in: app)
        XCTAssertTrue(categoryName.waitForExistence(timeout: 10), "⌘N must open New Category")
        categoryName.click(); categoryName.typeText("Escaped")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntilGone(categoryName), "Escape must cancel New Category")
        XCTAssertFalse(app.staticTexts["Escaped"].exists)
        let afterCancels = policyCounters(app)
        XCTAssertEqual(afterCancels, initial, "Cancelled Lock In and New Category must not submit policy")
        XCTAssertGreaterThanOrEqual(afterCancels.generation, initial.generation)
        navigate("protection", heading: "Protection", app: app)

        // Lock In → a typed site counts without pressing Add; commits to the isolated fixture only.
        more.click()
        XCTAssertTrue(newBlock.waitForExistence(timeout: 5), "Lock In missing from ⋯")
        newBlock.click()
        XCTAssertTrue(domains.waitForExistence(timeout: 10))
        domains.click(); domains.typeText("fixture-test.example")
        let commit = element("commitFixtureFocus", in: app)
        XCTAssertTrue(commit.waitForExistence(timeout: 5))
        XCTAssertTrue(commit.isEnabled, "A valid one-hour block must be submittable to the fixture")
        commit.click()
        let other = element("group-other", in: app)
        XCTAssertTrue(other.waitForExistence(timeout: 15), "Created fixture block must appear as a rule")
        XCTAssertFalse(domains.exists, "Sheet closes once the fixture confirms the block")
        let afterCreate = policyCounters(app)
        XCTAssertEqual(afterCreate.owners, initial.owners + 1, "Create Block must add exactly one rule")
        XCTAssertEqual(afterCreate.windows, initial.windows)
        XCTAssertEqual(afterCreate.pending, initial.pending, "A new stronger block needs no delayed release")
        XCTAssertGreaterThan(afterCreate.generation, initial.generation, "Create Block must commit")
        navigate("protection", heading: "Protection", app: app)

        // Drill-down into an existing group and back.
        openGroup("social", in: app)
        XCTAssertTrue(element("editPreparedSchedule-social-afternoon", in: app).exists)
        back(app, to: "Protection")

        // Schedule hours editor: Cancel leaves the committed allowed hours intact.
        navigate("protection", heading: "Protection", app: app)
        openGroup("video", in: app)
        // The row button carries the confirmed hours as its accessibility value.
        let hours = element("scheduleWebsites-youtube-evening", in: app)
        XCTAssertTrue(hours.waitForExistence(timeout: 10))
        func hoursText() -> String { hours.value as? String ?? "" }
        let original = hoursText()
        // Edit ▸ Hours… opens the hours editor.
        let edit = element("editPreparedSchedule-youtube-evening", in: app)
        func openEditor() {
            scrollTo(edit, in: app)
            edit.click()
            let item = app.menuItems["Hours…"]
            XCTAssertTrue(item.waitForExistence(timeout: 5), "Edit is missing Hours…")
            XCTAssertTrue(item.isEnabled, "Development fixture must allow editing hours")
            item.click()
        }
        openEditor()
        let start = element("allowedStart", in: app)
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Hours editor did not open")
        XCTAssertTrue(element("allowedEnd", in: app).exists)
        XCTAssertTrue(element("applyAllowedHours", in: app).exists)
        element("cancelAllowedHours", in: app).click()
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"),
                                                        evaluatedWith: start)], timeout: 5), .completed,
                       "Cancel must close the hours editor")
        XCTAssertEqual(hoursText(), original, "Cancelling the editor must not change allowed hours")
        XCTAssertEqual(original, "7–9 PM", "YouTube stays allowed 7–9 PM")

        // Keyboard: Escape also cancels the hours editor.
        openEditor()
        XCTAssertTrue(start.waitForExistence(timeout: 10), "Hours editor did not reopen")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntilGone(start), "Escape must cancel the hours editor")
        XCTAssertEqual(hoursText(), original)

        // Navigation away and back keeps state; no pending change was created.
        // (Reselecting the current sidebar row doesn't pop a drill-down; Back does.)
        back(app, to: "Protection")
        navigate("studylibrary", heading: "Library", app: app)
        navigate("protection", heading: "Protection", app: app)
        XCTAssertTrue(element("group-other", in: app).exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'pending change'")).firstMatch.exists,
                       "Cancelled hours edit must not leave a pending change")
        let final = policyCounters(app)
        XCTAssertEqual(final, afterCreate,
                       "Drill-down, navigation and cancelled hours edits must not submit policy")
        XCTAssertEqual(final.pending, initial.pending, "No delayed release may be queued")
        XCTAssertGreaterThanOrEqual(final.generation, afterCreate.generation)
    }

    /// Lock In commits only on a deliberate click: Return while typing a
    /// website, Cancel and Esc submit nothing; a week-long lock needs its
    /// acknowledgement, then Lock In creates exactly one rule.
    func testLockInReturnKeyCancelAndConfirm() {
        let app = launchFixture(size: "standard")
        XCTAssertTrue(app.staticTexts["developmentModeText"].waitForExistence(timeout: 15),
                      "Must run against the Development fixture")
        XCTAssertTrue(waitForTitle("Protection", in: app, timeout: 15))
        let initial = policyCounters(app)
        navigate("protection", heading: "Protection", app: app)
        let add = element("lockInButton", in: app)
        let domains = element("focusDomains", in: app)
        let commit = element("commitFixtureFocus", in: app)
        func open() {
            let more = element("moreMenu", in: app)
            XCTAssertTrue(more.waitForExistence(timeout: 10))
            more.click()
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            add.click()
            XCTAssertTrue(domains.waitForExistence(timeout: 10), "Lock In did not open")
        }

        // 1. Return while typing a valid website: the sheet stays open, nothing submitted.
        open()
        domains.click()
        domains.typeText("return-key.example")
        XCTAssertTrue(commit.isEnabled, "A valid website makes Lock In available")
        domains.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "exists == false"),
                                                        evaluatedWith: commit)], timeout: 3) == .completed,
                       "Return in the Websites field must not submit a Lock In")
        XCTAssertTrue(element("lockInItem-return-key.example", in: app).waitForExistence(timeout: 3),
                      "Return adds the typed website as a row")
        attachScreen("lockin-after-return")
        element("cancelBlockEditor", in: app).click()
        XCTAssertTrue(waitUntilGone(domains), "Cancel must close Lock In")

        // 2. Esc closes without submitting.
        open()
        domains.click()
        domains.typeText("escape-key.example")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntilGone(domains), "Esc must close Lock In")
        XCTAssertEqual(policyCounters(app), initial, "Return, Cancel and Esc must not submit anything")
        navigate("protection", heading: "Protection", app: app)

        // 3. Confirm: a week can't be ended early, so it asks first; then exactly one new rule.
        open()
        domains.click()
        domains.typeText("confirm-week.example")
        let duration = element("focusDuration", in: app)
        let scroll = element("blockEditorScroll", in: app)
        for _ in 0..<6 where duration.frame.maxY > scroll.frame.maxY - 4 { scroll.scroll(byDeltaX: 0, deltaY: -200) }
        duration.click()
        let week = app.menuItems["1 week"]
        XCTAssertTrue(week.waitForExistence(timeout: 5), "Missing 1 week")
        week.click()
        let understand = element("confirmLongLock", in: app)
        XCTAssertTrue(understand.waitForExistence(timeout: 5), "A week-long lock needs an acknowledgement")
        XCTAssertFalse(commit.isEnabled, "Lock In must wait for the acknowledgement")
        let review = element("lockInReview", in: app)
        XCTAssertTrue("\(review.label) \(review.value ?? "")".contains("can't be ended early"),
                      "The review must say it can't be ended early: \(review.label)")
        understand.click()
        attachScreen("lockin-week-acknowledged")
        XCTAssertTrue(commit.isEnabled)
        commit.click()
        XCTAssertTrue(waitUntilGone(commit, timeout: 12), "Lock In did not close after the fixture confirmed")
        let after = policyCounters(app)
        XCTAssertEqual(after.owners, initial.owners + 1, "Exactly one rule must be added")
        XCTAssertEqual(after.windows, initial.windows, "No schedule may change")
        XCTAssertEqual(after.pending, initial.pending, "A timed lock queues no release")
        XCTAssertGreaterThanOrEqual(after.generation, initial.generation)
    }

    /// One Lock In, two rules: Reddit blocked all day, YouTube allowed only
    /// 6–8 PM. Allowed hours take "1 hour" and "Forever" off the menu, the
    /// sentence says what happens to each, and one request adds one block,
    /// one schedule and its one end.
    func testLockInPerSiteRules() {
        let app = launchFixture(size: "standard")
        XCTAssertTrue(app.staticTexts["developmentModeText"].waitForExistence(timeout: 15),
                      "Must run against the Development fixture")
        XCTAssertTrue(waitForTitle("Protection", in: app, timeout: 15))
        let initial = policyCounters(app)
        navigate("protection", heading: "Protection", app: app)
        // Lock In lives in the ⋯ menu beside the blue +.
        let more = element("moreMenu", in: app)
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.click()
        let add = element("lockInButton", in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 10), "Lock In missing from ⋯")
        add.click()
        let domains = element("focusDomains", in: app)
        XCTAssertTrue(domains.waitForExistence(timeout: 10), "Lock In did not open")
        domains.click()
        domains.typeText("reddit.com\r")
        domains.typeText("youtube.com\r")
        let rule = element("lockInAccess-youtube.com", in: app)
        XCTAssertTrue(rule.waitForExistence(timeout: 5), "youtube.com has no rule menu")
        rule.click()
        let hours = app.menuItems["Allowed only at certain hours"]
        XCTAssertTrue(hours.waitForExistence(timeout: 5), "Missing Allowed only at certain hours")
        hours.click()
        let explained = element("lockInHours-youtube.com", in: app)
        XCTAssertTrue(explained.waitForExistence(timeout: 5), "The row doesn't explain its hours")
        XCTAssertTrue("\(explained.label) \(explained.value ?? "")".contains("Blocked the rest of the day"))

        let duration = element("focusDuration", in: app)
        XCTAssertEqual(duration.value as? String, "1 day", "Allowed hours need at least a day")
        duration.click()
        XCTAssertFalse(app.menuItems["1 hour"].waitForExistence(timeout: 2), "1 hour can't hold allowed hours")
        XCTAssertFalse(app.menuItems["Forever"].exists, "Allowed hours can't be forever")
        app.menuItems["1 day"].click()

        let review = element("lockInReview", in: app)
        let sentence = "\(review.label) \(review.value ?? "")"
        XCTAssertTrue(sentence.contains("reddit.com is blocked all day"), sentence)
        XCTAssertTrue(sentence.contains("youtube.com is allowed only from 6 PM to 8 PM"), sentence)
        XCTAssertTrue(sentence.contains("Both stay locked until"), sentence)
        attachScreen("lockin-per-site")

        let commit = element("commitFixtureFocus", in: app)
        XCTAssertTrue(commit.isEnabled)
        commit.click()
        XCTAssertTrue(waitUntilGone(commit, timeout: 12), "Lock In did not close after the fixture confirmed")
        let after = policyCounters(app)
        XCTAssertEqual(after.owners, initial.owners + 1, "Reddit: exactly one new block")
        XCTAssertEqual(after.windows, initial.windows + 1, "YouTube: exactly one new schedule")
        XCTAssertEqual(after.pending, initial.pending + 1, "The schedule's end is its one release")
        XCTAssertGreaterThan(after.generation, initial.generation)
    }
    #endif
}
