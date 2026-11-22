import XCTest

final class ShieldUITests: XCTestCase {
    private var progressEvents: [[String: String]] = []
    private var progressStorage: URL?
    private var progressFallbackNoted = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        progressEvents = []
        progressStorage = nil
        progressFallbackNoted = false
        recordUIPhase("test-start")
    }

    override func tearDownWithError() throws {
        recordUIPhase("test-teardown")
    }

    private func recordUIPhase(_ phase: String) {
        // The XCTest runner is sandboxed: an external evidence folder may be
        // readable but not writable. Never request broad filesystem exceptions
        // or let that known denial fail all functional UI tests at setUp.
        guard let requested = ProcessInfo.processInfo.environment["SHIELD_UI_PROGRESS_DIRECTORY"] else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        progressEvents.append(["phase": phase, "test": name,
                               "time": ISO8601DateFormatter().string(from: Date()),
                               "pid": String(pid)])
        // OS/XCTest logging survives even when the runner is killed before
        // XCTest exports attachments. Stage-scoped log collection captures it.
        NSLog("SHIELD_UI_PHASE pid=%d test=%@ phase=%@", pid, name, phase)
        let preferred = URL(fileURLWithPath: requested, isDirectory: true)
        let privateStorage = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldNativeUIProgress-\(pid)", isDirectory: true)
        let destinations = progressStorage.map { [$0] } ?? [preferred, privateStorage]
        let filename = name.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        let bytes: Data
        do {
            bytes = try JSONSerialization.data(withJSONObject: progressEvents,
                                               options: [.prettyPrinted, .sortedKeys])
        } catch {
            XCTFail("Could not encode native UI progress: \(error)")
            return
        }
        for root in destinations {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try bytes.write(to: root.appendingPathComponent("\(pid)-\(filename).json"),
                                options: .atomic)
                progressStorage = root
                if root == privateStorage && !progressFallbackNoted {
                    NSLog("SHIELD_UI_PROGRESS_FALLBACK pid=%d: external evidence storage is sandbox-denied; private runner temp plus system log remain active", pid)
                    progressFallbackNoted = true
                }
                return
            } catch {
                // Continue to the sandbox-owned temporary directory. This
                // preserves per-phase OS logs even if neither file is writable.
                NSLog("SHIELD_UI_PROGRESS_FILE_UNAVAILABLE pid=%d phase=%@ error=%@", pid, phase, error.localizedDescription)
            }
        }
        XCTFail("Could not preserve native UI progress in external or runner-private storage.")
    }

    // macOS cooperative activation can leave a freshly launched app behind
    // the frontmost window (Oct 26/27: Chrome). Assertions about clicks and
    // hittability are meaningless until Shield is actually in front.
    private func launchFrontmost(_ app: XCUIApplication) {
        // Never inherit a window state (fullscreen, closed) from an earlier run.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "Shield window never appeared")
        let frontmost = expectation(for: NSPredicate { _, _ in
            if app.state != .runningForeground || !window.isHittable { app.activate() }
            return app.state == .runningForeground && window.isHittable
        }, evaluatedWith: app)
        guard XCTWaiter.wait(for: [frontmost], timeout: 15) != .completed else { return }
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = "not-frontmost-full-screen"
        screen.lifetime = .keepAlways
        add(screen)
        XCTFail("Shield could not be brought in front of other apps; the test environment is not usable")
    }

    private func makeApplication() -> XCUIApplication {
        let app = XCUIApplication()
        // The next case must never inherit a live modal or player from this one.
        // Only this target's Development/UI Review app is terminated.
        addTeardownBlock {
            if app.state != .notRunning { app.terminate() }
        }
        return app
    }

    func testInstalledReleaseCandidateAuthorityReadback() throws {
        guard ProcessInfo.processInfo.environment["SHIELD_RC_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Requires the explicit disposable installed-RC harness.")
        }
        let app = XCUIApplication(bundleIdentifier: "com.kairos.ShieldRC")
        launchFrontmost(app)
        XCTAssertTrue(app.staticTexts["Rules active"].waitForExistence(timeout: 25), app.debugDescription)
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["lockInButton"])
        wait(for: [ready], timeout: 15)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Installed-authority-after-boundary-recovery"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testInstalledReleaseCandidateWebsiteCommitments() throws {
        guard ProcessInfo.processInfo.environment["SHIELD_RC_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Requires the explicit disposable installed-RC harness.")
        }
        let app = XCUIApplication(bundleIdentifier: "com.kairos.ShieldRC")
        launchFrontmost(app)
        func commit(_ domains: String, duration: String) {
            if duration == "Until I remove it" {
                // Open-ended blocks are made inside a category (its Add or Edit menu), not in Lock In.
                let category = app.descendants(matching: .any).matching(NSPredicate(format:
                    "identifier BEGINSWITH 'group-' AND identifier != 'group-location'")).firstMatch
                XCTAssertTrue(category.waitForExistence(timeout: 10), app.debugDescription)
                category.click()
                app.descendants(matching: .any)["categoryAddMenu"].click()
                app.menuItems["New Block…"].click()
                app.textFields["newBlockDomains"].click()
                app.textFields["newBlockDomains"].typeText(domains)
                app.buttons["commitNewBlock"].click()
                let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["lockInButton"])
                wait(for: [ready], timeout: 25)
                return
            }
            openBlockEditor(app)
            app.textFields["focusDomains"].click()
            app.textFields["focusDomains"].typeText(domains)
            app.popUpButtons["focusDuration"].click()
            app.menuItems[duration].click()
            if duration == "Forever" {
                let acknowledgement = app.descendants(matching: .any).matching(identifier: "confirmPermanentBlock").firstMatch
                for _ in 0..<4 where !acknowledgement.isHittable { app.scrollViews["blockEditorScroll"].swipeUp() }
                acknowledgement.click()
            }
            app.buttons["commitFixtureFocus"].click()
            let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["lockInButton"])
            wait(for: [ready], timeout: 25)
            XCTAssertTrue(app.staticTexts["Rules active"].waitForExistence(timeout: 10), app.debugDescription)
        }
        commit("example.com, example.net", duration: "1 hour")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Installed system hosts reconciled"))
            .firstMatch.waitForExistence(timeout: 15), "Installed RC must not report fixture enforcement.")
        commit("example.com", duration: "Forever")
        commit("shield-release.invalid", duration: "Until I remove it")
        // Remove Block… is in a block's Edit menu; only "Until I remove it" offers it.
        let edits = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "ruleMenu-focus-"))
        XCTAssertTrue(edits.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        var released = false
        for index in 0..<edits.count where !released {
            let edit = edits.element(boundBy: index)
            for _ in 0..<8 where !edit.isHittable { app.descendants(matching: .any)["pageScrollView"].swipeUp() }
            edit.click()
            let release = app.menuItems["Remove Block…"]
            if release.waitForExistence(timeout: 2) && release.isEnabled {
                release.click()
                app.buttons["Remove After 24 Hours"].click()
                released = true
            } else {
                app.typeKey(.escape, modifierFlags: [])
            }
        }
        XCTAssertTrue(released, "The removable block must offer Remove Block… in Edit. \(app.debugDescription)")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Ends "))
            .firstMatch.waitForExistence(timeout: 20), app.debugDescription)
    }

    func testInstalledReleaseCandidatePlaybackResumeAfterRelaunch() throws {
        guard ProcessInfo.processInfo.environment["SHIELD_RC_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Requires the explicit disposable installed-RC harness.")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldRCMedia-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ShieldTests/Fixtures/controlled-playback.mp4")
        let media = folder.appendingPathComponent("abcdefghijk.mp4")
        try FileManager.default.copyItem(at: fixture, to: media)
        let title = "RC playback \(UUID())"
        let transcript = "Controlled native playback and relaunch transcript."
        try Data(transcript.utf8).write(to: folder.appendingPathComponent("abcdefghijk.txt"))
        let manifest = folder.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "courseTitle": title,
            "videos": [["id": "abcdefghijk", "title": "Twenty-second acceptance clip",
                        "expectedDuration": 20, "transcriptRequested": true]]]).write(to: manifest)
        let app = XCUIApplication(bundleIdentifier: "com.kairos.ShieldRC")
        launchFrontmost(app)
        openSection("studylibrary", in: app)
        app.buttons["importStudyManifest"].click()
        try selectImportPath(manifest.path, in: app)
        let importMedia = collectionMenuItem("importExistingMedia", in: app)
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: importMedia)
        wait(for: [ready], timeout: 15)
        importMedia.click()
        try selectImportPath(folder.path, in: app)
        XCTAssertTrue(app.buttons["play-abcdefghijk"].waitForExistence(timeout: 25), app.debugDescription)
        app.buttons["play-abcdefghijk"].click()
        let player = app.descendants(matching: .any)["studyVideoPlayer"].firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 15))
        let advanced = expectation(for: NSPredicate { _, _ in
            let fields = (player.value as? String ?? "").split(separator: " ")
            return fields.count >= 4 && (Int(fields[2]) ?? 0) >= 3
        }, evaluatedWith: player)
        wait(for: [advanced], timeout: 12)
        app.buttons["closePlayer"].click()
        app.terminate()
        launchFrontmost(app)
        openSection("studylibrary", in: app)
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["transcript-abcdefghijk"].waitForExistence(timeout: 25))
        app.buttons["transcript-abcdefghijk"].click() // Resume, without autoplay.
        XCTAssertTrue(app.staticTexts[transcript].waitForExistence(timeout: 15))
        let resumed = expectation(for: NSPredicate { _, _ in
            let fields = (player.value as? String ?? "").split(separator: " ")
            return fields.count >= 4 && (Int(fields[2]) ?? 0) >= 3
        }, evaluatedWith: player)
        wait(for: [resumed], timeout: 15)
        app.buttons["closePlayer"].click()
        XCTAssertEqual(try Data(contentsOf: media), try Data(contentsOf: fixture))
    }

    // Installed RC acceptance ONLY. Intentionally damages one uniquely named
    // disposable course index after preserving its exact bytes, never the
    // authority state, existing courses or system hosts.
    func testInstalledReleaseCandidateLibraryRecoveryAndTranscriptPreservation() throws {
        guard ProcessInfo.processInfo.environment["SHIELD_RC_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Requires the disposable installed-RC test harness.")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldRCRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ShieldTests/Fixtures/controlled-playback.mp4")
        let media = folder.appendingPathComponent("abcdefghijk.mp4")
        try FileManager.default.copyItem(at: fixture, to: media)
        let transcriptText = "RC recovery must preserve the complete transcript."
        try Data(transcriptText.utf8).write(to: folder.appendingPathComponent("abcdefghijk.txt"))
        let title = "RC recovery \(UUID().uuidString)"
        let manifest = folder.appendingPathComponent("course.json")
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "courseTitle": title,
            "videos": [["id": "abcdefghijk", "title": "Controlled recovery clip",
                         "expectedDuration": 20, "transcriptRequested": true]]]).write(to: manifest)

        let app = XCUIApplication(bundleIdentifier: "com.kairos.ShieldRC")
        launchFrontmost(app)
        openSection("studylibrary", in: app)
        app.buttons["importStudyManifest"].click()
        try selectImportPath(manifest.path, in: app)
        let importMedia = collectionMenuItem("importExistingMedia", in: app)
        XCTAssertTrue(importMedia.waitForExistence(timeout: 20))
        importMedia.click()
        try selectImportPath(folder.path, in: app)
        XCTAssertTrue(app.buttons["play-abcdefghijk"].waitForExistence(timeout: 30), app.debugDescription)
        app.terminate()

        let root = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("ShieldRC/StudyLibrary", isDirectory: true)
        let directories = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        let matching = try directories.filter { directory in
            let index = directory.appendingPathComponent("library-state.json")
            guard let data = try? Data(contentsOf: index) else { return false }
            return String(data: data, encoding: .utf8)?.contains(title) == true
        }
        XCTAssertEqual(matching.count, 1, "Must isolate the uniquely created course")
        let directory = try XCTUnwrap(matching.first)
        let index = directory.appendingPathComponent("library-state.json")
        let corrupted = Data("{intentionally invalid RC acceptance index".utf8)
        try corrupted.write(to: index, options: .atomic)

        launchFrontmost(app)
        openSection("studylibrary", in: app)
        app.buttons["importStudyManifest"].click()
        try selectImportPath(manifest.path, in: app)
        let recovery = app.buttons["rebuildStudyIndex"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 15), app.debugDescription)
        recovery.click()
        let confirm = app.buttons["Rebuild index"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), app.debugDescription)
        confirm.click()
        XCTAssertTrue(app.buttons["transcript-abcdefghijk"].waitForExistence(timeout: 30),
                      app.debugDescription)
        app.buttons["transcript-abcdefghijk"].click()
        XCTAssertTrue(app.staticTexts[transcriptText].waitForExistence(timeout: 15),
                      app.debugDescription)
        app.buttons["closePlayer"].click()
        app.terminate()

        let backups = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent.hasPrefix("library-state.damaged-") &&
                      $0.pathExtension == "json" }
        XCTAssertTrue(try backups.contains { try Data(contentsOf: $0) == corrupted },
                      "Rebuild must preserve the exact damaged index")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("abcdefghijk.mp4")),
                       try Data(contentsOf: fixture))
        XCTAssertEqual(try Data(contentsOf: media), try Data(contentsOf: fixture))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("abcdefghijk.txt"),
                                  encoding: .utf8), transcriptText)
    }


    #if !UI_REVIEW
    // Import a collection file, then its MP4 and transcript, through the real
    // Open panel; play it in Shield's player with the transcript beside it.
    func testLocalImportOpensNativePlayerAndTranscript() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldUIImport-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ShieldTests/Fixtures/controlled-media.mp4")
        let video = folder.appendingPathComponent("abcdefghijk.mp4")
        try FileManager.default.copyItem(at: fixture, to: video)
        let transcript = "A local transcript displayed inside Shield."
        try Data(transcript.utf8).write(to: folder.appendingPathComponent("abcdefghijk.txt"))
        let manifest = folder.appendingPathComponent("course.json")
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "courseTitle": "Native player UI course",
            "videos": [["id": "abcdefghijk", "title": "Local acceptance video",
                        "expectedDuration": 2, "transcriptRequested": true]]
        ]).write(to: manifest)
        let app = makeApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_UNCONFINED_TOOL_FIXTURE"] = "0"
        launchFrontmost(app)
        openSection("studylibrary", in: app)
        // Cancelling the real Open panel changes nothing and leaves the menu usable.
        chooseLibraryMenuItem("Import Collection File…", in: app)
        let cancelImport = app.windows.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelImport.waitForExistence(timeout: 10))
        cancelImport.click()
        XCTAssertTrue(waitUntilGone(cancelImport), "The Open panel must close on Cancel")
        chooseLibraryMenuItem("Import Collection File…", in: app)
        try selectImportPath(manifest.path, in: app)
        XCTAssertTrue(waitForTitle("Native player UI course", in: app), "The imported collection must open")
        chooseLibraryMenuItem("Import MP4 Files…", in: app)
        try selectImportPath(folder.path, in: app)
        // Row buttons show on hover; the row's menu offers the same actions.
        chooseVideoAction("Show Transcript", for: "abcdefghijk", in: app)
        // The AppKit player view keeps its own accessibility; the player's
        // Transcript toggle exists only while the player is open.
        XCTAssertTrue(element("playerTranscript", in: app).waitForExistence(timeout: 15), app.debugDescription)
        let text = element("playerTranscriptText", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(staticTextContent(text).contains(transcript), "Transcript text: \(staticTextContent(text))")
        goBack(app, to: "Native player UI course")
        chooseVideoAction("Play", for: "abcdefghijk", in: app)
        // The AppKit player view keeps its own accessibility; the player's
        // Transcript toggle exists only while the player is open.
        XCTAssertTrue(element("playerTranscript", in: app).waitForExistence(timeout: 15), app.debugDescription)
        goBack(app, to: "Native player UI course")
        XCTAssertEqual(try Data(contentsOf: video), try Data(contentsOf: fixture), "Import must not change the original")
    }

    // The next three run in a disposable XPC harness (private release tooling),
    // which names a real development service. Without it the app uses the
    // in-process fixture, so these would test nothing.
    private func requireXPCHarness(_ app: XCUIApplication) throws {
        guard ProcessInfo.processInfo.environment["SHIELD_CI_XPC_SERVICE"] != nil else {
            throw XCTSkip("Runs only in the disposable XPC harness (SHIELD_CI_XPC_SERVICE).")
        }
        for key in ["SHIELD_CI_XPC_SERVICE", "SHIELD_CI_PRIVILEGED_XPC", "SHIELD_XPC_SERVICE_REQUIREMENT"] {
            if let value = ProcessInfo.processInfo.environment[key] { app.launchEnvironment[key] = value }
        }
    }

    func testDevelopmentAppUsesNamedService() throws {
        let app = makeApplication()
        try requireXPCHarness(app)
        launchFrontmost(app)
        if ProcessInfo.processInfo.environment["SHIELD_CI_PRIVILEGED_XPC"] == "1" {
            let detail = app.staticTexts["backendReconciliationErrorDetail"]
            if detail.waitForExistence(timeout: 3) {
                print("Root service UI error: \(String(describing: detail.value))")
            }
        }
        XCTAssertTrue(element("backendModeLabel", in: app).waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(element("protectionStatus", in: app).waitForExistence(timeout: 20), app.debugDescription)
        openBlockEditor(app)
        let domain = element("focusDomains", in: app)
        domain.click()
        domain.typeText("example.com")
        element("commitFixtureFocus", in: app).click()
        let message = element("backendActionMessage", in: app)
        XCTAssertTrue(message.waitForExistence(timeout: 20), app.debugDescription)
        let committed = expectation(for: NSPredicate { _, _ in
            self.staticTextContent(message).contains("Changes confirmed by the service")
        }, evaluatedWith: message)
        wait(for: [committed], timeout: 20)
        openSection("diagnostics", in: app)
        expandDisclosure("serviceDetails", in: app)
        XCTAssertTrue(app.staticTexts["Service receipt"].waitForExistence(timeout: 10), app.debugDescription)
    }

    func testDevelopmentServiceDisconnectFailsClosed() throws {
        let app = makeApplication()
        try requireXPCHarness(app)
        launchFrontmost(app)
        XCTAssertTrue(app.staticTexts["Can't reach Shield"].waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertFalse(element("lockInButton", in: app).isEnabled)
        openSection("diagnostics", in: app)
        XCTAssertFalse(app.staticTexts["Service receipt"].exists)
    }

    func testDevelopmentServiceCommitsSchedules() throws {
        let app = makeApplication()
        try requireXPCHarness(app)
        launchFrontmost(app)
        openSection("protection", in: app)
        openCategory("video", in: app)
        let schedule = element(prefix: "editPreparedSchedule-", in: app)
        XCTAssertTrue(schedule.waitForExistence(timeout: 20), app.debugDescription)
        let id = String(schedule.identifier.dropFirst("editPreparedSchedule-".count))
        openHoursEditor(id, in: app)
        stepAllowedStart(by: 1, in: app)
        element("applyAllowedHours", in: app).click()
        let message = element("backendActionMessage", in: app)
        XCTAssertTrue(message.waitForExistence(timeout: 20), app.debugDescription)
        let committed = expectation(for: NSPredicate { _, _ in
            self.staticTextContent(message).contains("Changes confirmed by the service")
        }, evaluatedWith: message)
        wait(for: [committed], timeout: 20)
    }

    // Less allowed time applies at once; more allowed time waits at least 24
    // hours, and the confirmed hours don't move until then.
    func testStricterHoursApplyNowAndLooserHoursWait24Hours() {
        let app = makeApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_UI_POLISH_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_VISUAL_SIZE"] = "standard"
        launchFrontmost(app)
        openSection("protection", in: app)
        openCategory("video", in: app)
        // The row button carries the confirmed hours as its accessibility value.
        let hours = element("scheduleWebsites-youtube-evening", in: app)
        XCTAssertTrue(hours.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(staticTextContent(hours), "7–9 PM", "Fixture YouTube allowed hours")
        let pending = element("pendingScheduleRelease-youtube-evening", in: app)
        XCTAssertFalse(pending.exists)

        openHoursEditor("youtube-evening", in: app)
        stepAllowedStart(by: 1, in: app)
        let apply = element("applyAllowedHours", in: app)
        XCTAssertEqual(apply.title.isEmpty ? apply.label : apply.title, "Apply Now", "Less allowed time is stricter")
        apply.click()
        XCTAssertTrue(waitUntilGone(element("allowedStart", in: app), timeout: 15),
                      "The editor closes once the fixture confirms")
        let applied = expectation(for: NSPredicate { _, _ in self.staticTextContent(hours) == "8–9 PM" },
                                  evaluatedWith: hours)
        XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 10), .completed,
                       "Stricter hours apply at once: \(staticTextContent(hours))")
        XCTAssertFalse(pending.exists, "A stricter change needs no delayed release")
        let stricter = staticTextContent(hours)
        attachWindow("stricter-applied", app)

        openHoursEditor("youtube-evening", in: app)
        stepAllowedStart(by: -2, in: app)
        XCTAssertEqual(apply.title.isEmpty ? apply.label : apply.title, "Schedule Change", "More allowed time is looser")
        apply.click()
        XCTAssertTrue(waitUntilGone(element("allowedStart", in: app), timeout: 15),
                      "The editor closes once the fixture confirms")
        XCTAssertTrue(pending.waitForExistence(timeout: 15), "A looser change must wait. \(app.debugDescription)")
        XCTAssertEqual(staticTextContent(hours), stricter, "A looser change can't move the confirmed hours yet")
        attachWindow("looser-pending", app)

        openSection("studylibrary", in: app)
        openSection("protection", in: app)
        // Protection reopens on its category list; hours live on the category page.
        openCategory("video", in: app)
        XCTAssertTrue(hours.waitForExistence(timeout: 10))
        XCTAssertEqual(staticTextContent(hours), stricter, "Confirmed hours survive navigation")
        XCTAssertTrue(pending.exists, "The pending change survives navigation")
    }

    func testPermanentCommitmentRequiresExplicitAcknowledgement() {
        let app = makeApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_VISUAL_SIZE"] = "compact"
        launchFrontmost(app)
        openBlockEditor(app)
        let domains = element("focusDomains", in: app)
        domains.click()
        domains.typeText("example.org")
        let commit = element("commitFixtureFocus", in: app)
        XCTAssertTrue(commit.isEnabled)
        chooseDuration("Forever", in: app)
        XCTAssertFalse(commit.isEnabled, "A permanent commitment must be reviewed explicitly.")
        let acknowledgement = element("confirmPermanentBlock", in: app)
        XCTAssertTrue(acknowledgement.waitForExistence(timeout: 10))
        for _ in 0..<4 where !acknowledgement.isHittable { element("blockEditorScroll", in: app).swipeUp() }
        acknowledgement.click()
        XCTAssertTrue(commit.isEnabled)
        chooseDuration("1 hour", in: app)
        XCTAssertTrue(commit.isEnabled)
        XCTAssertFalse(acknowledgement.exists)
        chooseDuration("Forever", in: app)
        XCTAssertFalse(commit.isEnabled, "Returning to Forever must require a fresh acknowledgement.")
        element("cancelBlockEditor", in: app).click()
        XCTAssertTrue(waitUntilGone(domains), "Cancel must close Lock In")
        // Lock In is still on offer in the ⋯ menu after a cancel.
        element("moreMenu", in: app).click()
        let lockIn = element("lockInButton", in: app)
        XCTAssertTrue(lockIn.waitForExistence(timeout: 5), "Lock In missing from ⋯")
        XCTAssertTrue(lockIn.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }

    // A pasted address keeps only its site; anything else isn't a website.
    func testFocusEditorAcceptsPastedAddressesAndRejectsOtherText() {
        let app = makeApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        launchFrontmost(app)
        openBlockEditor(app)
        let focus = element("focusDomains", in: app)
        let commit = element("commitFixtureFocus", in: app)
        // Return on text that isn't a website says so under the field.
        let hint = element("lockInSiteProblem", in: app)
        focus.click()
        focus.typeText("https://example.com/path?q=1")
        XCTAssertTrue(commit.isEnabled, "A pasted address blocks its site")
        XCTAssertEqual(commit.label, "Lock In", "Commit: \(commit.label)")
        let review = element("lockInReview", in: app)
        XCTAssertTrue(review.waitForExistence(timeout: 5), "A valid site shows what will happen")
        XCTAssertTrue("\(review.label) \(review.value ?? "")".contains("example.com is blocked all day"),
                      "The pasted address must become its site: \(review.label)")
        XCTAssertFalse(hint.exists)
        focus.typeKey("a", modifierFlags: .command)
        focus.typeText("not a website!")
        XCTAssertFalse(commit.isEnabled, "Text that isn't a website can't be blocked")
        focus.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(hint.waitForExistence(timeout: 5),
                      "No hint for text that isn't a website. Sheet: \(element("blockEditorScroll", in: app).debugDescription)")
        XCTAssertTrue("\(hint.label) \(hint.value ?? "")".contains("like example.com"), "Hint: \(hint.label)")
        XCTAssertFalse(element("lockInItem-not a website!", in: app).exists, "Invalid text must not become a row")
        element("cancelBlockEditor", in: app).click()
        XCTAssertTrue(waitUntilGone(focus))
    }

    // With YouTube blocked, downloads say why and stay unavailable.
    func testDevelopmentIdentityAndBlockedFetcher() {
        let app = makeApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_UNCONFINED_TOOL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_UI_TEST_BLOCK_FETCH"] = "1"
        launchFrontmost(app)
        XCTAssertTrue(element("developmentBanner", in: app).waitForExistence(timeout: 10))
        openSection("studylibrary", in: app)
        addLinks("https://youtu.be/abcdefghijk", in: app)
        let reason = element("downloadAvailability", in: app)
        XCTAssertTrue(reason.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Downloads are paused while YouTube is blocked."].exists, app.debugDescription)
        let download = element("downloadRemaining", in: app)
        XCTAssertTrue(!download.exists || !download.isEnabled, "Blocked downloads must not look available.")
        let row = element("download-abcdefghijk", in: app)
        XCTAssertTrue(!row.exists || !row.isEnabled, "Blocked downloads must not look available.")
    }

    // The development package has no reviewed download tools: nothing offers
    // a download, while importing your own MP4 files still works.
    func testDevelopmentPackageKeepsExternalToolsDisabledByDefault() {
        let app = makeApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_UNCONFINED_TOOL_FIXTURE"] = "0"
        launchFrontmost(app)
        openSection("studylibrary", in: app)
        addLinks("https://youtu.be/abcdefghijk", in: app)
        XCTAssertTrue(element("videoActions-abcdefghijk", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(element("downloadRemaining", in: app).exists, "No dead download action")
        XCTAssertFalse(element("download-abcdefghijk", in: app).exists, "No dead download action")
        element("downloadsMenu", in: app).click()
        let localImport = app.menuItems["Import MP4 Files…"]
        XCTAssertTrue(localImport.waitForExistence(timeout: 5),
                      "Import MP4 Files… missing from ⋯: \(app.menuItems.allElementsBoundByIndex.map(\.title).filter { !$0.isEmpty })")
        XCTAssertTrue(localImport.isEnabled, "Importing your own MP4 files stays available")
        app.typeKey(.escape, modifierFlags: [])
    }

    func testMissingDownloaderToolsAreReported() {
        let app = makeApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_UNCONFINED_TOOL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_UI_TEST_MISSING_TOOLS"] = "1"
        launchFrontmost(app)
        openSection("studylibrary", in: app)
        addLinks("https://youtu.be/abcdefghijk", in: app)
        let download = element("downloadRemaining", in: app)
        XCTAssertTrue(download.waitForExistence(timeout: 10), app.debugDescription)
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: download)
        wait(for: [enabled], timeout: 10)
        download.click()
        let failure = element("studyMessage", in: app)
        XCTAssertTrue(failure.waitForExistence(timeout: 15), app.debugDescription)
        let reported = expectation(for: NSPredicate { _, _ in
            self.staticTextContent(failure).contains("Required tool is unavailable: yt-dlp")
        }, evaluatedWith: failure)
        wait(for: [reported], timeout: 10)
    }

    // Duplicates and non-links are reported, adding claims no download, and
    // deleting an unsaved video removes it.
    func testQueueLinksDeduplicateAndRemoveWithoutClaimingDownload() {
        let app = makeApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_UNCONFINED_TOOL_FIXTURE"] = "0"
        launchFrontmost(app)
        openSection("studylibrary", in: app)
        addLinks("https://youtu.be/abcdefghijk https://youtu.be/abcdefghijk invalid", in: app)
        let notice = element("downloadQueueNotice", in: app)
        XCTAssertTrue(notice.waitForExistence(timeout: 10), app.debugDescription)
        let first = staticTextContent(notice)
        XCTAssertTrue(first.contains("Added 1") && first.contains("1 not a YouTube link"), "Notice: \(first)")
        addLinks("https://youtu.be/abcdefghijk", in: app)
        let again = expectation(for: NSPredicate { _, _ in
            self.staticTextContent(notice).contains("1 already in your library")
        }, evaluatedWith: notice)
        XCTAssertEqual(XCTWaiter.wait(for: [again], timeout: 10), .completed, "Notice: \(staticTextContent(notice))")
        XCTAssertFalse(element("play-abcdefghijk", in: app).exists, "Adding a link must not claim a saved video")
        element("videoActions-abcdefghijk", in: app).click()
        let delete = app.menuItems["Delete Video…"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()
        let confirm = element("confirmDeleteVideo", in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.click()
        XCTAssertTrue(waitUntilGone(element("videoActions-abcdefghijk", in: app)),
                      "A deleted unsaved video must leave the list.")
    }

    func testLibraryFiltersAndSearchHaveWorkingRecovery() {
        let app = makeApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_UNCONFINED_TOOL_FIXTURE"] = "0"
        launchFrontmost(app)
        openSection("studylibrary", in: app)
        addLinks("https://youtu.be/abcdefghijk https://youtu.be/bcdefghijkl", in: app)
        let first = element("videoActions-abcdefghijk", in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 10), app.debugDescription)
        let search = app.windows.firstMatch.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10), app.debugDescription)
        search.click()
        search.typeText("No matching title 927491")
        let reset = element("resetLibraryFilter", in: app)
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "An empty search must offer a way back")
        XCTAssertFalse(first.exists)
        reset.click()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(element("videoActions-bcdefghijkl", in: app).exists)
        element("libraryFilter", in: app).click()
        let saved = app.menuItems["Saved"]
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.click()
        XCTAssertTrue(waitUntilGone(first), "Unsaved videos cannot appear in Saved.")
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "An empty filter must offer a way back")
        reset.click()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
    }

    func testSettingsRefreshAndCopyReport() {
        let app = makeApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_VISUAL_SIZE"] = "compact"
        launchFrontmost(app)
        openSection("diagnostics", in: app)
        let refresh = element("refreshEvidence", in: app)
        XCTAssertTrue(refresh.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<6 where !refresh.isHittable { element("pageScrollView", in: app).swipeUp() }
        XCTAssertTrue(refresh.isHittable, "Refresh must be reachable by scrolling.")
        refresh.click()
        let copy = element("copyDiagnosticReport", in: app)
        XCTAssertTrue(copy.waitForExistence(timeout: 10))
        for _ in 0..<6 where !copy.isHittable { element("pageScrollView", in: app).swipeUp() }
        copy.click()
        let copied = element("copyResult", in: app)
        XCTAssertTrue(copied.waitForExistence(timeout: 10))
        XCTAssertEqual(staticTextContent(copied), "Copied")
    }
    #endif


    func testHeadingsStayVisibleWhilePagesScroll() {
        let app = makeApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        app.launchEnvironment["SHIELD_VISUAL_SIZE"] = "compact"
        launchFrontmost(app)
        for (section, title) in [("protection", "Protection"), ("studylibrary", "Library"), ("diagnostics", "Settings")] {
            openSection(section, in: app)
            // The heading is the toolbar navigation title (the window title).
            let window = app.windows.firstMatch
            XCTAssertEqual(window.title, title, app.debugDescription)
            XCTAssertTrue(window.isHittable, "\(title) page must be visible before scrolling")
            let toolbar = window.toolbars.firstMatch
            let before = toolbar.frame
            app.descendants(matching: .any)["pageScrollView"].swipeUp()
            XCTAssertEqual(window.title, title, "\(title) heading must remain after scrolling")
            XCTAssertEqual(toolbar.frame.minY, before.minY, accuracy: 3)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "\(section)-below-fold"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }


    #if UI_REVIEW
    // A deterministic, read-only design review. This target is the separate
    // UI Review product; never launch installed Shield RC or a root service.
    func testUIReviewFullAppearanceSizeScrollMatrix() {
        let sections: [(String, String)] = [
            ("protection", "Protection"),
            ("studylibrary", "Library"),
            ("diagnostics", "Settings")
        ]
        for appearance in ["light", "dark"] {
            for size in ["compact", "standard"] {
                for (section, heading) in sections {
                    let app = makeApplication()
                    app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
                    app.launchEnvironment["SHIELD_VISUAL_SECTION"] = section
                    app.launchEnvironment["SHIELD_VISUAL_APPEARANCE"] = appearance
                    app.launchEnvironment["SHIELD_VISUAL_SIZE"] = size
                    app.launchEnvironment["SHIELD_UNCONFINED_TOOL_FIXTURE"] = "0"
                    launchFrontmost(app)
                    let context = "\(appearance)-\(size)-\(section)"
                    XCTAssertTrue(app.staticTexts["reviewModeText"].waitForExistence(timeout: 20),
                                  "\(context) must launch UI Review, not installed Shield RC.")
                    let reviewWindow = app.windows.firstMatch
                    let titled = expectation(for: NSPredicate { _, _ in reviewWindow.title == heading },
                                             evaluatedWith: reviewWindow)
                    wait(for: [titled], timeout: 15)
                    XCTAssertEqual(reviewWindow.title, heading, "\(context): unexpected page.")
                    let title = reviewWindow.toolbars.firstMatch
                    XCTAssertTrue(reviewWindow.waitForExistence(timeout: 10),
                                  "\(context): Shield window missing.")
                    XCTAssertTrue(reviewWindow.isHittable, "\(context): Shield window not visible.")
                    waitForStableWindow(reviewWindow, title: title, app: app)
                    let headingFrame = title.frame
                    // Capture the window element, NOT the desktop. Previous
                    // XCUIApplication screenshots actually exported browser
                    // content and were invalid as Shield visual evidence.
                    let top = XCTAttachment(screenshot: reviewWindow.screenshot())
                    top.name = "\(context)-top"
                    top.lifetime = .keepAlways
                    add(top)
                    let scroll = app.descendants(matching: .any)["pageScrollView"]
                    XCTAssertTrue(scroll.waitForExistence(timeout: 10), "\(context): page not scrollable.")
                    scroll.swipeUp()
                    XCTAssertEqual(reviewWindow.title, heading, "\(context): heading lost after scrolling.")
                    XCTAssertEqual(title.frame.minY, headingFrame.minY, accuracy: 1,
                                   "\(context): fixed heading moved while scrolling.")
                    let below = XCTAttachment(screenshot: reviewWindow.screenshot())
                    below.name = "\(context)-below-fold"
                    below.lifetime = .keepAlways
                    add(below)
                    app.terminate()
                }
            }
        }
        // 2 appearances × 2 window sizes × 4 pages × 2 scroll states =
        // 32 retained, named screenshots, all isolated from production policy.
    }

    func testUIReviewCapabilities() {
        let app = makeApplication()
        app.launchEnvironment["SHIELD_VISUAL_FIXTURE"] = "1"
        launchFrontmost(app)
        let banner = app.descendants(matching: .any)["developmentBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["reviewModeText"].waitForExistence(timeout: 10),
                      app.debugDescription)
        openSection("protection", in: app)
        // Lock In opens and says why, but nothing can be submitted.
        let add = element("lockInButton", in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.click()
        let domains = element("focusDomains", in: app)
        XCTAssertTrue(domains.waitForExistence(timeout: 10), app.debugDescription)
        domains.click()
        domains.typeText("example.com")
        XCTAssertFalse(element("commitFixtureFocus", in: app).isEnabled, "UI Review must not submit a block")
        element("cancelBlockEditor", in: app).click()
        XCTAssertTrue(waitUntilGone(domains))
        openSection("studylibrary", in: app)
        element("downloadsMenu", in: app).click()
        for title in ["Import Collection File…", "Import MP4 Files…"] {
            let item = app.menuItems[title]
            XCTAssertTrue(item.waitForExistence(timeout: 5), "Library menu is missing \(title)")
            XCTAssertFalse(item.isEnabled, "UI Review must not import: \(title)")
        }
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(element("downloadRemaining", in: app).exists, "Unavailable downloads should not appear as a dead primary action.")
        XCTAssertTrue(app.windows.firstMatch.isHittable && !app.windows.firstMatch.title.isEmpty)
        openSection("diagnostics", in: app)
        XCTAssertTrue(element("reviewModeText", in: app).waitForExistence(timeout: 10), "Settings must still say this is UI Review")
    }
    #endif

    // MARK: Helpers

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func element(prefix: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    private func waitUntilGone(_ target: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: target)
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    // The window title also carries a subtitle ("Library – 2 videos").
    private func waitForTitle(_ title: String, in app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let window = app.windows.firstMatch
        let titled = expectation(for: NSPredicate { _, _ in
            window.title == title || window.title.hasPrefix(title + " –")
        }, evaluatedWith: window)
        return XCTWaiter.wait(for: [titled], timeout: timeout) == .completed
    }

    private func attachWindow(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func expandDisclosure(_ id: String, in app: XCUIApplication) {
        let row = element(id, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<6 where !row.isHittable { element("pageScrollView", in: app).swipeUp() }
        // A native disclosure reports 1 when expanded.
        func isExpanded() -> Bool { (row.value as? NSNumber)?.intValue == 1 || row.value as? String == "1" }
        if !isExpanded() { row.click() }
        let expanded = expectation(for: NSPredicate { _, _ in isExpanded() }, evaluatedWith: row)
        wait(for: [expanded], timeout: 5)
    }

    // The toolbar's Lock In button is the one way to add a restriction.
    private func openBlockEditor(_ app: XCUIApplication) {
        // Lock In lives in the ⋯ menu beside the blue +.
        let more = element("moreMenu", in: app)
        XCTAssertTrue(more.waitForExistence(timeout: 20), app.debugDescription)
        more.click()
        let add = element("lockInButton", in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 20), app.debugDescription)
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: add)
        wait(for: [ready], timeout: 20)
        add.click()
        XCTAssertTrue(element("focusDomains", in: app).waitForExistence(timeout: 10), app.debugDescription)
    }

    private func chooseDuration(_ title: String, in app: XCUIApplication) {
        // In a compact window "Lock for" can sit below the visible part of the sheet.
        let duration = element("focusDuration", in: app)
        let scroll = element("blockEditorScroll", in: app)
        for _ in 0..<6 where duration.frame.maxY > scroll.frame.maxY - 4 {
            scroll.scroll(byDeltaX: 0, deltaY: -200)
        }
        duration.click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5),
                      "Missing duration \(title). Picker: \(duration.debugDescription) Menu items: \(app.menuItems.allElementsBoundByIndex.map(\.title))")
        item.click()
    }

    /// Edit ▸ Hours… on the schedule's row.
    private func openHoursEditor(_ scheduleID: String, in app: XCUIApplication) {
        let edit = element("editPreparedSchedule-\(scheduleID)", in: app)
        XCTAssertTrue(edit.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<8 where !edit.isHittable { element("pageScrollView", in: app).swipeUp() }
        edit.click()
        let item = app.menuItems["Hours…"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Edit is missing Hours…")
        XCTAssertTrue(item.isEnabled, "Editing hours must be available in the fixture")
        item.click()
        XCTAssertTrue(element("allowedStart", in: app).waitForExistence(timeout: 10), "Hours editor did not open")
    }

    // Moves "Allow from" by whole hours with the arrow keys on the hour field.
    private func stepAllowedStart(by hours: Int, in app: XCUIApplication) {
        let picker = app.datePickers.matching(identifier: "allowedStart").firstMatch
        let target = picker.exists ? picker : element("allowedStart", in: app)
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).click()
        for _ in 0..<abs(hours) { app.typeKey(hours > 0 ? .upArrow : .downArrow, modifierFlags: []) }
        attachWindow("hours-editor-\(hours > 0 ? "plus" : "minus")\(abs(hours))", app)
    }

    private func goBack(_ app: XCUIApplication, to title: String) {
        let back = app.windows.firstMatch.toolbars.buttons.matching(NSPredicate(format:
            "label ==[c] 'Back' OR identifier ==[c] 'Back' OR identifier CONTAINS[c] 'back'")).firstMatch
        if back.waitForExistence(timeout: 5) && back.isHittable { back.click() }
        else { app.typeKey("[", modifierFlags: .command) }
        XCTAssertTrue(waitForTitle(title, in: app), "Back must return to \(title); got \(app.windows.firstMatch.title)")
    }

    private func chooseLibraryMenuItem(_ title: String, in app: XCUIApplication) {
        let menu = element("downloadsMenu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: menu)
        wait(for: [ready], timeout: 10)
        menu.click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Library menu is missing \(title)")
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: item)
        wait(for: [enabled], timeout: 10)
        item.click()
    }

    private func chooseVideoAction(_ title: String, for videoID: String, in app: XCUIApplication) {
        let menu = element("videoActions-\(videoID)", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 20), app.debugDescription)
        menu.click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Video menu is missing \(title)")
        item.click()
    }

    private func addLinks(_ text: String, in app: XCUIApplication) {
        let add = element("addVideos", in: app)
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)
        add.click()
        let field = element("youtubeLinkInput", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Add Videos did not open")
        field.click()
        field.typeText(text)
        element("queueYouTubeLinks", in: app).click()
        XCTAssertTrue(waitUntilGone(field), "Add Videos did not close")
    }

    // Kept for the installed-RC harness cases above, which run only on a
    // disposable Mac (private release tooling).
    private func collectionMenuItem(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let menu = element("downloadsMenu", in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
        menu.click()
        let item = app.menuItems[id]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Library menu is missing \(id)")
        return item
    }

    // `title` is the window toolbar that carries the navigation title.
    private func waitForStableWindow(_ window: XCUIElement, title: XCUIElement, app: XCUIApplication) {
        var previous = CGRect.null
        var stableSamples = 0
        let settled = expectation(for: NSPredicate { _, _ in
            let frame = window.frame
            stableSamples = frame == previous ? stableSamples + 1 : 0
            previous = frame
            return stableSamples >= 2 && window.isHittable && frame.contains(title.frame)
        }, evaluatedWith: window)
        wait(for: [settled], timeout: 10)
        // The mode indicator lives in the sidebar footer: it must never cover
        // page content or the sidebar destinations.
        let banner = element("developmentBanner", in: app)
        XCTAssertTrue(banner.exists)
        let page = element("pageScrollView", in: app)
        XCTAssertFalse(banner.frame.intersects(page.frame), "The mode indicator cannot cover page content.")
        XCTAssertGreaterThanOrEqual(page.frame.minY, title.frame.maxY - 1,
                                    "Scrollable content must not cover the toolbar title.")
        for section in ["protection", "studylibrary", "diagnostics"] {
            let row = element("nav-\(section)", in: app)
            XCTAssertTrue(row.exists, "Each destination must have an accessible sidebar row.")
            XCTAssertTrue(window.frame.contains(row.frame), "All destinations must remain reachable.")
            XCTAssertFalse(row.frame.intersects(banner.frame), "The mode indicator cannot cover navigation.")
        }
    }

    private func staticTextContent(_ element: XCUIElement) -> String {
        // AppKit AXStaticText commonly puts its displayed text in AXValue.
        // Preserve the exact text assertions; an empty label is not missing UI.
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }


    /// Schedules and their hours live on each category's page.
    private func openCategory(_ id: String, in app: XCUIApplication) {
        let row = element("group-\(id)", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 15), "Missing category \(id). \(app.debugDescription)")
        row.click()
        XCTAssertTrue(element("categoryAddMenu", in: app).waitForExistence(timeout: 12), "Category \(id) did not open")
    }

    private func openSection(_ name: String, in app: XCUIApplication) {
        recordUIPhase("navigation-\(name)-begin")
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        // Native List(selection:) row, matched by identifier regardless of the
        // OS-specific AX wrapper (cell, outline row or nested label).
        let navigation = app.descendants(matching: .any).matching(identifier: "nav-\(name)").firstMatch
        recordUIPhase("navigation-\(name)-resolve-row")
        XCTAssertTrue(navigation.waitForExistence(timeout: 10))
        recordUIPhase("navigation-\(name)-click")
        if navigation.isHittable {
            navigation.click()
        } else {
            navigation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        // The page heading is the toolbar navigation title (the window title).
        let headings = ["schedules": "Protection", "protection": "Protection",
                        "studylibrary": "Library", "diagnostics": "Settings"]
        let changed = expectation(for: NSPredicate { _, _ in window.title == headings[name] },
                                  evaluatedWith: window)
        wait(for: [changed], timeout: 10)
        recordUIPhase("navigation-\(name)-complete")
    }

    private func selectImportPath(_ path: String, in app: XCUIApplication) throws {
        recordUIPhase("import-panel-resolve")
        // The Open panel belongs to the application's modal accessibility tree.
        // AppKit's implementation XPC service is not a launchable application;
        // constructing XCUIApplication for it raises an Objective-C exception.
        // Window-scoped: the panel's buttons also appear in the Touch Bar.
        let cancel = app.windows.buttons["Cancel"].firstMatch
        let open = app.windows.buttons["Open"].firstMatch
        let panelReady = expectation(for: NSPredicate { _, _ in
            open.exists && cancel.exists && cancel.isEnabled && cancel.isHittable
        }, evaluatedWith: app)
        wait(for: [panelReady], timeout: 15)
        XCTAssertTrue(cancel.isHittable, "The genuine native Open panel must be exposed by the app.")
        recordUIPhase("import-panel-go-to-folder")
        // Send the shortcut through an enabled panel control: the application
        // itself may be AX-disabled while its modal panel owns keyboard focus.
        cancel.typeKey("g", modifierFlags: [.command, .shift])
        // Go to Folder exposes a combo box or a text field inside its modal sheet/dialog.
        var pathField: XCUIElement?
        let pathReady = expectation(for: NSPredicate { _, _ in
            for field in [app.comboBoxes.firstMatch,
                          app.sheets.textFields.firstMatch, app.dialogs.textFields.firstMatch]
                where field.exists && field.isHittable {
                pathField = field; return true
            }
            return false
        }, evaluatedWith: nil)
        wait(for: [pathReady], timeout: 10)
        let field = try XCTUnwrap(pathField)
        recordUIPhase("import-panel-enter-selection")
        field.typeKey("a", modifierFlags: .command)
        field.typeText(path)
        field.typeKey(.return, modifierFlags: [])
        let selected = expectation(for: NSPredicate { _, _ in
            open.exists && open.isEnabled && open.isHittable
        }, evaluatedWith: open)
        wait(for: [selected], timeout: 15)
        recordUIPhase("import-panel-confirm")
        open.click()
        let dismissed = expectation(for: NSPredicate { _, _ in !open.exists || !open.isHittable }, evaluatedWith: open)
        wait(for: [dismissed], timeout: 10)
        recordUIPhase("import-panel-dismissed")
    }
}
