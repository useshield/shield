#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import Shield

// Offscreen review captures of Go There days, fed by a real fixture
// authority: the start sheet, the map picker, and the status line in each
// state (undo, waiting, arrived, practice). Never moves the pointer, shows a
// window on any display, or starts Core Location.
@MainActor
final class GoDaySnapshotTests: XCTestCase {
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private let library = RulePlace(id: "place-library", name: "Library", latitude: 40.7532, longitude: -73.9822,
                                    radiusMeters: 150, wifiTags: [])
    private let homeFix = GoDayGate.StartFix(latitude: 40.7681, longitude: -73.9819, horizontalAccuracy: 30)

    private enum Stage { case none, undo, waiting, arrived }

    private func model(_ stage: Stage) throws -> ShieldViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldGoDaySnapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
        let backend = try FixtureBackend(root: root)
        let now = Date()
        func submit(_ commands: [BackendCommand], at time: Date) throws {
            let generation = (try? backend.snapshot(now: time, calendar: .current).generation) ?? 0
            _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: generation,
                                                 submittedAt: time, commands: commands), now: time, calendar: .current)
        }
        // Started 3 minutes ago unless still in the undo window. History only
        // moves forward, so everything before it is committed then too.
        let started = stage == .undo || stage == .none ? now : now.addingTimeInterval(-180)
        try submit(ShieldPreparedPlan.commands(at: started), at: started)
        try submit([.add(library)], at: started)
        if stage != .none {
            let day = try ShieldViewModel.makeGoDay(places: [library], startFix: homeFix, startTags: [],
                                                    until: now.addingTimeInterval(6 * 3_600), apps: [],
                                                    now: started).get()
            try submit([.add(day)], at: started)
        }
        if stage == .arrived {
            let session = PresenceSession(bootSessionID: "boot-snap")
            for (sequence, offset) in [(UInt64(1), -25.0), (2, -2)] {
                let time = now.addingTimeInterval(offset)
                let record = PresenceReportBuilder.record(
                    fix: LocationFix(latitude: library.latitude, longitude: library.longitude, horizontalAccuracy: 25,
                                     observedAt: time, isSimulated: false),
                    fullAccuracy: true, connectedTag: "lib-1", visibleTags: [], sleptSinceLastReport: false, now: time)
                let report = PresenceReport(sequence: sequence, bootSessionID: "boot-snap",
                                            uptimeNanoseconds: UInt64(1_000 + offset) * 1_000_000_000, evidence: record)
                _ = try backend.reportPresence(report, session: session, now: time, calendar: .current)
            }
        }
        let model = ShieldViewModel(authorityReader: AuthorityStateReader(fileURL: backend.paths.authority),
                                    enforcementReader: HostsEnforcementReader(fileURL: backend.paths.hosts),
                                    studyLibraryRoot: root.appendingPathComponent("study"), fixtureBackend: backend)
        model.refresh(now: now)
        return model
    }

    private func capture<V: View>(_ view: V, size: CGSize, name: String, in directory: URL) throws {
        for dark in [false, true] {
            let window = OffscreenWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
                                         backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
            window.contentView = host
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
            window.close()
        }
    }

    private func page(_ model: ShieldViewModel) -> some View {
        // As in the window: the day's banner in the top-right corner.
        NavigationStack { ProtectionView(model: model).modifier(FloatingNoticeHost(model: model)) }
    }

    /// Product-website screenshot: Go There Today ready to start.
    func testCaptureMarketingGoThere() throws {
        MarketingRender.isActive = true
        defer { MarketingRender.isActive = false }
        let directory = ProcessInfo.processInfo.environment["SHIELD_SNAPSHOT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("marketing", isDirectory: true) } ??
            FileManager.default.temporaryDirectory.appendingPathComponent("ShieldMarketing", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let idle = try model(.none)
        XCTAssertTrue(idle.goDayStartReady)
        try capture(GoDayStartSheet(model: idle), size: CGSize(width: 520, height: 520), name: "go-there-today",
                    in: directory)
    }

    func testCaptureGoThereDays() throws {
        let directory = ProcessInfo.processInfo.environment["SHIELD_SNAPSHOT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("goday", isDirectory: true) } ??
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("ShieldUIPolishEvidence/Cleanup/snapshots/goday", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 900, height: 360)

        let idle = try model(.none)
        XCTAssertTrue(idle.supportsGoDays)
        XCTAssertNil(idle.goDayLine(), "No line on a normal day")
        try capture(GoDayStartSheet(model: idle), size: CGSize(width: 520, height: 560), name: "1-start-sheet",
                    in: directory)
        try capture(ShieldConfirmationSheet(confirmation: ShieldConfirmation(
                        symbol: "figure.walk", tint: ShieldGroupKind.location.tint, title: "Start Go There Today?",
                        message: "Blocking starts in 2 minutes and can't be cancelled after that. "
                            + "It ends when you get to Library, or at 9:00 PM.",
                        confirmTitle: "Start") {}),
                    size: CGSize(width: 340, height: 330), name: "1b-start-confirmation", in: directory)
        try capture(ShieldConfirmationSheet(confirmation: ShieldConfirmation(
                        symbol: "checkmark.shield.fill", tint: ShieldCategoryColor.blue.color, title: "Keep your current rules?",
                        message: "X / Reddit won't change at 10:06 PM. Changing it later means waiting 24 hours again.",
                        confirmTitle: "Keep Current Rules") {}),
                    size: CGSize(width: 340, height: 330), name: "1c-keep-confirmation", in: directory)
        try capture(ShieldConfirmationSheet(confirmation: ShieldConfirmation(
                        symbol: "calendar.badge.minus", tint: ShieldCategoryColor.pink.color, title: "Remove Netflix?",
                        message: "Its hours keep applying for 24 hours, then it's gone.",
                        confirmTitle: "Remove After 24 Hours", destructive: true) {}),
                    size: CGSize(width: 340, height: 310), name: "1e-remove-confirmation", in: directory)
        try capture(VideoLibraryAddOnSheet(model: idle), size: CGSize(width: 480, height: 420),
                    name: "1f-video-library-addon", in: directory)
        try capture(ZStack(alignment: .topTrailing) {
                        Color.clear
                        VStack(alignment: .trailing, spacing: 10) {
                            ShieldBanner(symbol: "arrow.clockwise", tint: .blue,
                                         title: BrowserReopenAdvisor.headline(["Social media"]),
                                         message: "If Google Chrome still blocks it, reopen it. Your tabs come back.") {
                                Button("Not Now") {}
                                Button("Reopen Google Chrome") {}.buttonStyle(ShieldFilledButtonStyle())
                            }
                            NoticeBar(kind: .warning, text: "The library index needs repair.",
                                      action: ("Rebuild…", {})).closing {}
                        }
                        .padding(.top, 14).padding(.trailing, 18)
                    },
                    size: CGSize(width: 900, height: 320), name: "1d-banners", in: directory)
        try capture(PlaceEditor(model: idle), size: CGSize(width: 560, height: 600), name: "2-map-picker",
                    in: directory)
        idle.goDayPractice = (try ShieldViewModel.makeGoDay(places: [library], startFix: homeFix, startTags: [],
                                                             until: .now.addingTimeInterval(3_600), apps: [],
                                                             now: .now).get().goDay!, .now.addingTimeInterval(3_600))
        XCTAssertEqual(idle.goDayLine()?.isPractice, true)
        try capture(page(idle), size: size, name: "3-bar-practice", in: directory)

        let undo = try model(.undo)
        XCTAssertEqual(undo.goDayLine()?.canUndo, true)
        try capture(page(undo), size: size, name: "4-bar-undo", in: directory)

        let waiting = try model(.waiting)
        XCTAssertEqual(waiting.goDayLine()?.tone, .waiting)
        XCTAssertTrue(waiting.goDayLine()?.text.contains("Library") == true)
        XCTAssertNil(waiting.undoGoDay(), "No undo after 2 minutes")
        try capture(page(waiting), size: size, name: "5-bar-waiting", in: directory)

        let arrived = try model(.arrived)
        XCTAssertEqual(arrived.goDayLine()?.tone, .done)
        XCTAssertFalse(arrived.backendSnapshot?.authority.effectiveRestrictions
            .contains { $0.apps.contains(.webBrowsers) } == true, "Arrived, so browsers are open")
        try capture(page(arrived), size: size, name: "6-bar-arrived", in: directory)

        for model in [idle, undo, waiting, arrived] {
            XCTAssertNil(model.locationSensor, "Snapshots must never start Core Location")
        }
    }
}
#endif
