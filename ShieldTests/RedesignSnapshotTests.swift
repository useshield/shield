#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import Shield

// Offscreen visual evidence harness. It never moves the pointer, never
// activates the app, and only renders the simulated fixture model into
// windows placed far outside every display. PNGs go to SHIELD_SNAPSHOT_DIR.
@MainActor
final class RedesignSnapshotTests: XCTestCase {
    private struct Size { let name: String; let size: CGSize }
    private let sizes = [
        Size(name: "compact", size: CGSize(width: 860, height: 600)),
        Size(name: "standard", size: CGSize(width: 1100, height: 720)),
        Size(name: "wide", size: CGSize(width: 1680, height: 1000))
    ]

    private var outputDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        let base = env["SHIELD_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ??
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("ShieldUIPolishEvidence/Cleanup/snapshots/redesign", isDirectory: true)
        return base.appendingPathComponent(env["SHIELD_SNAPSHOT_LABEL"] ?? "after", isDirectory: true)
    }

    private func note(_ line: String) {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appendingPathComponent("capture-log.txt")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else { try? data.write(to: url) }
    }

    private func settle(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private final class OffscreenWindow: NSWindow {
        // Titled windows are normally pulled back onto a display; keep this
        // evidence window far outside every screen so nothing appears.
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private func dump(_ view: NSView, depth: Int = 0) {
        guard depth < 22 else { return }
        let f = view.convert(view.bounds, to: nil)
        note(String(repeating: "  ", count: depth) + "\(type(of: view)) \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)) hidden=\(view.isHidden) layer=\(view.layer.map { String(describing: type(of: $0)) } ?? "-") sub=\(view.layer?.sublayers?.count ?? 0)")
        for sub in view.subviews { dump(sub, depth: depth + 1) }
    }

    private func makeWindow(size: CGSize, dark: Bool, toolbar: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if toolbar { style.insert(.fullSizeContentView) }
        let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Shield"
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        return window
    }

    // Screen Recording permission is NOT requested, so window-server capture
    // is unavailable. cacheDisplay draws ordinary views but not macOS 26 glass
    // containers (their content is mirrored through portal layers), so the
    // sidebar panel is re-composited: an approximate glass fill, then a
    // cacheDisplay of the panel's own content view. Toolbar glass capsules
    // are approximated the same way. Everything else is the real rendering.
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private func render(_ view: NSView) -> NSBitmapImageRep? {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    // In-process Core Animation rendering of a view's layer tree, used where
    // the glass container mirrors content that cacheDisplay leaves blank.
    private func renderLayer(of view: NSView) {
        guard let layer = view.layer, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = view.convert(view.bounds, to: nil)
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        if layer.contentsAreFlipped() {
            context.translateBy(x: 0, y: rect.height); context.scaleBy(x: 1, y: -1)
        }
        // Backdrop/portal layers are composited by the window server only and
        // render as opaque fills in-process; hide them for this pass.
        func effectLayers(_ layer: CALayer) -> [CALayer] {
            let own = String(describing: type(of: layer))
            let mine = (own.contains("Backdrop") || own.contains("Portal")) && !layer.isHidden ? [layer] : []
            return mine + (layer.sublayers ?? []).flatMap(effectLayers)
        }
        let hidden = effectLayers(layer)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hidden.forEach { $0.isHidden = true }
        layer.render(in: context)
        hidden.forEach { $0.isHidden = false }
        CATransaction.commit()
        context.restoreGState()
    }

    private func composite(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let frameView = window.contentView?.superview, let base = render(frameView) else { return nil }
        let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: base.pixelsWide,
                                            pixelsHigh: base.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return base }
        output.size = frameView.bounds.size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
        let windowFill = dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.985, alpha: 1)
        windowFill.setFill(); frameView.bounds.fill()
        if ProcessInfo.processInfo.environment["SHIELD_SNAPSHOT_CACHEDISPLAY"] == "1" {
            base.draw(in: frameView.bounds)
        } else {
            renderLayer(of: frameView)
        }
        let all = descendants(of: frameView)
        for glass in all where String(describing: type(of: glass)).contains("ConcentricGlassEffectView") {
            let rect = glass.convert(glass.bounds, to: nil)
            if let wrapper = glass.superview {
                windowFill.setFill(); wrapper.convert(wrapper.bounds, to: nil).fill()
            }
            let panel = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
            (dark ? NSColor(white: 0.19, alpha: 1) : NSColor(white: 0.925, alpha: 1)).setFill(); panel.fill()
            NSColor(white: dark ? 1 : 0, alpha: dark ? 0.10 : 0.06).setStroke(); panel.lineWidth = 1; panel.stroke()
            if let content = descendants(of: glass).first(where: {
                String(describing: type(of: $0)).hasPrefix("NSHostingView") }) {
                renderLayer(of: content)
            }
        }
        // Re-draw titlebar contents (traffic lights, toolbar items, title) on top,
        // since the panel fill above may cover the sidebar half of the titlebar.
        for item in all where ["NSToolbarItemViewer", "_NSThemeCloseWidget", "_NSThemeZoomWidget",
                                "_NSThemeWidget", "NSToolbarTitleView"].contains(String(describing: type(of: item))) {
            let rect = item.convert(item.bounds, to: nil)
            let isItem = String(describing: type(of: item)) == "NSToolbarItemViewer"
            if isItem, let hosted = item.subviews.first, !String(describing: type(of: hosted)).contains("Space") {
                let r = hosted.convert(hosted.bounds, to: nil).insetBy(dx: -2, dy: 0)
                let capsule = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
                (dark ? NSColor(white: 0.24, alpha: 1) : NSColor(white: 1, alpha: 1)).setFill(); capsule.fill()
                NSColor(white: dark ? 1 : 0, alpha: dark ? 0.12 : 0.10).setStroke(); capsule.stroke()
            }
            if isItem { renderLayer(of: item) }
            else if let rep = render(item) {
                rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        return output
    }

    @discardableResult
    private func capture(_ window: NSWindow, name: String) throws -> URL {
        window.displayIfNeeded()
        if ProcessInfo.processInfo.environment["SHIELD_SNAPSHOT_DUMP"] == "1", let frame = window.contentView?.superview { dump(frame) }
        guard let rep = composite(window), let png = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("Rendering failed")
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appendingPathComponent(name + ".png")
        try png.write(to: url)
        return url
    }

    private func host<V: View>(_ view: V, size: CGSize, dark: Bool, toolbar: Bool = true,
                               name: String, settleFor seconds: TimeInterval = 1.2,
                               afterAppear: (() -> Void)? = nil) throws {
        let window = makeWindow(size: size, dark: dark, toolbar: toolbar)
        let controller = NSHostingController(rootView: view
            .environment(\.colorScheme, dark ? .dark : .light))
        controller.sceneBridgingOptions = [.title, .toolbars]
        window.contentViewController = controller
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        settle(0.4)
        afterAppear?()
        settle(seconds)
        try capture(window, name: name)
        window.orderOut(nil)
        window.close()
    }

    /// A made-up course for library renders (Shield itself ships none).
    static let sampleCourse = StudyManifest(schemaVersion: 1, courseTitle: "Sample — Algebra Course",
        videos: (1...12).map { n in
            StudyVideo(id: String(format: "smpl%07d", n), title: "Algebra Course - Lesson #\(n) Topic \(n)",
                       expectedDuration: 600, transcriptRequested: true)
        })

    private let sections: [(String, ShieldSection)] = [
        ("protection", .protection), ("schedules", .schedules),
        ("downloads", .studyLibrary), ("settings", .diagnostics)
    ]

    /// Shield's own player controls, paused with the transcript open.
    /// The video picture itself doesn't draw offscreen (it's a video layer).
    func testCapturePlayer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldPlayerSnap-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let originals = root.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/controlled-media.mp4")
        for id in ["aaaaaaaaaaa", "bbbbbbbbbbb"] {
            try FileManager.default.copyItem(at: fixture, to: originals.appendingPathComponent("\(id).mp4"))
        }
        try Data("A sample transcript line.\n\nAnother paragraph of the lesson.".utf8)
            .write(to: originals.appendingPathComponent("aaaaaaaaaaa.txt"))
        let manifest = StudyManifest(schemaVersion: 1, courseTitle: "Player", videos: [
            StudyVideo(id: "aaaaaaaaaaa", title: "Lesson 1: Linear equations", expectedDuration: 2, transcriptRequested: true),
            StudyVideo(id: "bbbbbbbbbbb", title: "Lesson 2: Systems", expectedDuration: 2, transcriptRequested: false),
        ])
        let manifestURL = root.appendingPathComponent("course.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let model = ShieldViewModel(studyLibraryRoot: root.appendingPathComponent("library"))
        model.importStudyManifest(from: manifestURL)
        for _ in 0..<200 where model.isRestoringStudy { settle(0.025) }
        var imported = false
        Task { await model.importExistingMedia(from: originals); imported = true }
        for _ in 0..<400 where !imported { settle(0.025) }
        let selection = try XCTUnwrap(model.playbackSelection(for: "aaaaaaaaaaa", transcript: true))
        // Timed lines: the transcript follows the video, captions on.
        let cues = [TranscriptCue(start: 0, end: 0.8, text: "In this lesson we solve linear equations"),
                    TranscriptCue(start: 0.8, end: 1.4, text: "one step at a time,"),
                    TranscriptCue(start: 1.4, end: 2, text: "and check every answer.")]
        try XCTUnwrap(TranscriptCue.encode(cues))
            .write(to: selection.store.root.appendingPathComponent("aaaaaaaaaaa.cues.json"))
        let savedCaptions = UserDefaults.standard.object(forKey: PlayerPrefs.captionsKey)
        UserDefaults.standard.set(true, forKey: PlayerPrefs.captionsKey)
        defer {
            if let savedCaptions { UserDefaults.standard.set(savedCaptions, forKey: PlayerPrefs.captionsKey) }
            else { UserDefaults.standard.removeObject(forKey: PlayerPrefs.captionsKey) }
        }
        for dark in [true, false] {
            for size in sizes where size.name != "compact" {
                let view = NavigationStack {
                    StudyPlayerView(selection: selection, title: { model.videoTitle($0) },
                                    nextID: { model.nextSavedVideo(after: $0) },
                                    selectionFor: { model.playbackSelection(for: $0) })
                }
                try host(view, size: size.size, dark: dark, name: "player-\(dark ? "dark" : "light")-\(size.name)",
                         settleFor: 2.0)
            }
        }
    }

    func testCaptureEveryPage() throws {
        let filter = ProcessInfo.processInfo.environment["SHIELD_SNAPSHOT_FILTER"]
        for dark in [false, true] {
            for size in sizes {
                for (name, section) in sections {
                    let label = "\(dark ? "dark" : "light")-\(size.name)-\(name)"
                    if let filter, !label.contains(filter) { continue }
                    let model = makeFixturePreviewModel(preparedPlan: true)
                    model.selectedSection = section
                    if section == .studyLibrary { model.addCourseToLibrary(Self.sampleCourse) }
                    try host(ContentView(model: model), size: size.size, dark: dark, name: label)
                    model.stop()
                }
                try captureExtraRoutes(dark: dark, size: size, filter: filter)
            }
        }
    }

    /// Product-website screenshots: the app as a customer sees it,
    /// with protection on and no development footer.
    /// Run with SHIELD_SNAPSHOT_LABEL=marketing to keep them apart.
    func testCaptureMarketingScreens() throws {
        MarketingRender.isActive = true
        defer { MarketingRender.isActive = false }
        let lockItems = [LockInItem(target: .website("reddit.com")), LockInItem(target: .website("youtube.com")),
                         LockInItem(target: .website("instagram.com")),
                         LockInItem(target: .app(AppTarget(displayName: "News", bundleID: "com.apple.news",
                                                           teamID: nil)))]
        for dark in [true, false] {
            let appearance = dark ? "dark" : "light"
            // 1. Protection: the status and the categories. (A running Lock In
            // has no section of its own; it would show as an "Other" category.)
            let overview = makeFixturePreviewModel(preparedPlan: true)
            overview.selectedSection = .protection
            try host(ContentView(model: overview), size: CGSize(width: 1280, height: 800), dark: dark,
                     name: "protection-overview-\(appearance)")
            overview.stop()
            // 2. A category's allowed hours.
            let category = makeFixturePreviewModel(preparedPlan: true)
            category.selectedSection = .protection
            try host(ContentView(model: category, initialPath: [ShieldGroupKind.social.rawValue]),
                     size: CGSize(width: 1100, height: 720), dark: dark, name: "category-allowed-hours-\(appearance)")
            category.stop()
            // 3. Lock In, filled in and ready.
            let lock = makeFixturePreviewModel(preparedPlan: true)
            lock.start()
            try host(LockInSheet(model: lock, initialItems: lockItems), size: CGSize(width: 500, height: 600),
                     dark: dark, toolbar: false, name: "lock-in-\(appearance)")
            lock.stop()
            // 4. Setting a site's allowed hours (generic YouTube 7–9 PM).
            let hours = makeFixturePreviewModel(preparedPlan: true)
            hours.start()
            let youtube = try XCTUnwrap(hours.backendSnapshot?.committedSchedules.first { $0.id == "youtube-evening" })
            try host(PreparedScheduleHoursEditor(model: hours, schedule: youtube), size: CGSize(width: 440, height: 432),
                     dark: dark, toolbar: false, name: "allowed-hours-editor-\(appearance)")
            hours.stop()
        }
    }

    // Drill-down routes at every size; sheets once per appearance (their
    // size is independent of the main window).
    private func captureExtraRoutes(dark: Bool, size: Size, filter: String?) throws {
        let appearance = dark ? "dark" : "light"
        // Every Protection status, as the installed app shows them (the
        // fixture itself is always "Preview only").
        let statusLabel = "\(appearance)-\(size.name)-status-states"
        if filter == nil || statusLabel.contains(filter!) {
            let model = makeFixturePreviewModel(preparedPlan: true)
            let presentation = ShieldRulePresentation(model: model)
            let states = VStack(spacing: 18) {
                ProtectionHero(model: model, presentation: presentation, detail: "Next change at 6 PM",
                               evidenceOverride: .confirmed, hasRulesOverride: true)
                ProtectionHero(model: model, presentation: presentation, evidenceOverride: .confirmed,
                               hasRulesOverride: false)
                ProtectionHero(model: model, presentation: presentation, evidenceOverride: .attention)
                ProtectionHero(model: model, presentation: presentation, evidenceOverride: .unavailable)
            }
            .padding(28)
            .frame(maxWidth: 820, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity)
            .background(Color.shieldPage)
            try host(states, size: size.size, dark: dark, toolbar: false, name: statusLabel)
            model.stop()
        }
        // Empty pages: a new user's first look.
        for (name, section) in [("library", ShieldSection.studyLibrary), ("places", .places)] {
            let label = "\(appearance)-\(size.name)-empty-\(name)"
            if let filter, !label.contains(filter) { continue }
            let model = makeFixturePreviewModel()
            model.selectedSection = section
            try host(ContentView(model: model), size: size.size, dark: dark, name: label)
            model.stop()
        }
        for kind in [ShieldGroupKind.social, .adult] {
            let label = "\(appearance)-\(size.name)-protection-\(kind.rawValue)"
            if let filter, !label.contains(filter) { continue }
            let model = makeFixturePreviewModel(preparedPlan: true)
            model.selectedSection = .protection
            try host(ContentView(model: model, initialPath: [kind.rawValue]), size: size.size, dark: dark, name: label)
            model.stop()
        }
        let libraryLabel = "\(appearance)-\(size.name)-downloads-library"
        if filter == nil || libraryLabel.contains(filter!) {
            let model = makeFixturePreviewModel(preparedPlan: true)
            model.addCourseToLibrary(Self.sampleCourse)
            settle(0.5)
            let review = StudyCollection(id: "collection-review", name: "Review later", symbol: "star.fill",
                                         color: .orange, videoIDs: [])
            model.saveCollection(review)
            _ = model.addVideoLinks("https://youtu.be/abcdefghijk https://youtu.be/bcdefghijkl",
                                    toCollection: review.id)
            settle(0.5)
            model.selectedCollectionID = model.collectionID(forCourse: Self.sampleCourse)
            model.selectedSection = .studyLibrary
            try host(ContentView(model: model), size: size.size, dark: dark, name: libraryLabel)
            model.stop()
        }
        // One place's page (map, blocks set there).
        let placeLabel = "\(appearance)-\(size.name)-place-detail"
        if filter == nil || placeLabel.contains(filter!) {
            let model = makeFixturePreviewModel(preparedPlan: true)
            model.start()
            settle(0.3)
            if let added = model.addMapPlace(name: "Home", latitude: 40.7812, longitude: -73.9665, radiusMeters: 150) {
                settle(0.5)
                _ = model.commitBlock(domains: ["reddit.com", "www.reddit.com"], duration: .untilReleased,
                                      groupName: "reddit.com", placeID: added.placeID)
                settle(0.5)
                model.selectedSection = .places
                try host(ContentView(model: model, initialPath: ["place:" + added.placeID]), size: size.size,
                         dark: dark, name: placeLabel)
            }
            model.stop()
        }
        guard size.name == "standard" else { return }
        for (suffix, atPlace) in [("newblock-plain", false), ("newblock-at-place", true)] {
            let label = "\(appearance)-sheet-\(suffix)"
            if let filter, !label.contains(filter) { continue }
            let model = makeFixturePreviewModel(preparedPlan: true)
            model.start()
            settle(0.3)
            var placeID: String?
            if atPlace, let added = model.addMapPlace(name: "Home", latitude: 40.7812, longitude: -73.9665, radiusMeters: 150) {
                settle(0.5)
                placeID = added.placeID
            }
            try host(BlockEditor(model: model, placeID: placeID), size: CGSize(width: 460, height: 520),
                     dark: dark, toolbar: false, name: label)
            model.stop()
        }
        let collectionLabel = "\(appearance)-sheet-collection"
        if filter == nil || collectionLabel.contains(filter!) {
            let model = makeFixturePreviewModel(preparedPlan: true)
            try host(StudyCollectionEditor(model: model, existing: nil), size: CGSize(width: 500, height: 520),
                     dark: dark, toolbar: false, name: collectionLabel)
            model.stop()
        }
        let sheetLabel = "\(appearance)-sheet-newblock"
        if filter == nil || sheetLabel.contains(filter!) {
            let model = makeFixturePreviewModel(preparedPlan: true)
            model.start()
            try host(LockInSheet(model: model), size: CGSize(width: 500, height: 600), dark: dark,
                     toolbar: false, name: sheetLabel)
            model.stop()
        }
        let editorLabel = "\(appearance)-sheet-hours"
        if filter == nil || editorLabel.contains(filter!) {
            let model = makeFixturePreviewModel(preparedPlan: true)
            model.start()
            settle(0.3)
            if let schedule = model.backendSnapshot?.committedSchedules.first(where: { $0.id == "pinterest-afternoon" }) {
                try host(PreparedScheduleHoursEditor(model: model, schedule: schedule),
                         size: CGSize(width: 480, height: 520), dark: dark, toolbar: false, name: editorLabel)
            }
            model.stop()
        }
    }
}
#endif
