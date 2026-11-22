#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import Shield

// Offscreen review captures of place blocks, fed by a real fixture
// authority (two places, a block limited to one, a recorded verdict): the
// Protection page, Location blocks, Places, a place page, Lock In (plain and at a place), and Add a Place. Never moves the pointer, shows a
// window on any display, or starts Core Location.
@MainActor
final class LocationRulesSnapshotTests: XCTestCase {
    private final class OffscreenWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private func model() throws -> ShieldViewModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldLocationSnapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
        let backend = try FixtureBackend(root: root)
        let now = Date()
        func submit(_ commands: [BackendCommand]) throws {
            let generation = (try? backend.snapshot(now: now, calendar: .current).generation) ?? 0
            _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: generation,
                                                 submittedAt: now, commands: commands), now: now, calendar: .current)
        }
        try submit(ShieldPreparedPlan.commands(at: now))
        let home = RulePlace(id: "home", name: "Home", latitude: 40.7812, longitude: -73.9665, radiusMeters: 200,
                             wifiTags: ["home-1"])
        let library = RulePlace(id: "library", name: "Library", latitude: 40.7532, longitude: -73.9822,
                                radiusMeters: 200, wifiTags: ["lib-1", "lib-2", "lib-3"])
        try submit([.add(home), .add(library)])
        try submit([.add(DomainRestriction(owner: .commitment, policyID: "focus-library-netflix", title: "netflix.com",
                                           domains: ["netflix.com", "www.netflix.com"], startsAt: now,
                                           placeID: "library"))])
        let report = PresenceReportBuilder.report(PresenceReportBuilder.record(
            fix: LocationFix(latitude: library.latitude, longitude: library.longitude, horizontalAccuracy: 25,
                             observedAt: now, isSimulated: false),
            fullAccuracy: true, connectedTag: "lib-1", visibleTags: ["lib-2"], sleptSinceLastReport: false, now: now))
        _ = try backend.reportPresence(report, session: PresenceSession(), now: now, calendar: .current)
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

    func testCaptureLocationRules() throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("ShieldUIPolishEvidence/Cleanup/snapshots/location", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = try model()
        XCTAssertNil(model.locationSensor, "Snapshots must never start Core Location")
        XCTAssertEqual(model.locationPolicy.places.count, 2)
        XCTAssertEqual(model.blocksUsing(place: "library"), 1)
        XCTAssertTrue(model.backendSnapshot?.authority.effectiveRestrictions
            .contains { $0.policyID == "focus-library-netflix" } == true, "At the library, so the place block is on")
        try capture(NavigationStack { ProtectionView(model: model) }, size: CGSize(width: 900, height: 900),
                    name: "0-protection-page", in: directory)
        XCTAssertEqual(ShieldRulePresentation(model: model).groups.first { $0.id == "location" }?.restrictions
            .map(\.policyID), ["focus-library-netflix"], "The place block is under Location blocks only")
        try capture(NavigationStack { RuleGroupDetailPage(categoryID: "location", model: model) },
                    size: CGSize(width: 900, height: 420), name: "1-location-blocks", in: directory)
        try capture(NavigationStack { PlacesView(model: model) }, size: CGSize(width: 900, height: 760),
                    name: "1b-places-page", in: directory)
        try capture(NavigationStack { PlaceDetailPage(placeID: "library", model: model) },
                    size: CGSize(width: 900, height: 980), name: "1c-place-detail", in: directory)
        try capture(LockInSheet(model: model), size: CGSize(width: 520, height: 760),
                    name: "2a-lock-in", in: directory)
        try capture(BlockEditor(model: model, placeID: "library"), size: CGSize(width: 520, height: 760),
                    name: "2-new-block-where", in: directory)
        try capture(PlaceEditor(model: model), size: CGSize(width: 580, height: 640),
                    name: "3-add-place", in: directory)
        XCTAssertNil(model.locationSensor, "Rendering the editors must not start Core Location")
    }
}
#endif
