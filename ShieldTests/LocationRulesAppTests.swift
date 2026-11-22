import Foundation
import Testing
@testable import Shield

// Place blocks — an ordinary New Block limited to a saved place — plus the
// sensor's reports and Wi-Fi tags, through the real fixture authority.
// No Location permission is needed: nothing here starts Core Location.
struct LocationRulesAppTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private func at(_ hour: Int, _ minute: Int = 0, second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: hour, minute: minute, second: second))!
    }

    private let library = RulePlace(id: "library", name: "Library", latitude: 40.7532, longitude: -73.9822,
                                    radiusMeters: 250, wifiTags: ["lib-1", "lib-2", "lib-3"])
    private let home = RulePlace(id: "home", name: "Home", latitude: 40.7812, longitude: -73.9665,
                                 radiusMeters: 150, wifiTags: ["home-1"], isHome: true)

    // MARK: Reports and Wi-Fi tags

    @Test func reportsCarryTagsOnlyAndRiseWithinTheBoot() throws {
        let now = Date()
        let fix = LocationFix(latitude: 40.7532, longitude: -73.9822, horizontalAccuracy: 30,
                              observedAt: now, isSimulated: false)
        let visible = ["c"] + (0..<60).map { "v\($0)" } + ["v1"]
        let record = PresenceReportBuilder.record(fix: fix, fullAccuracy: true, connectedTag: "c", visibleTags: visible,
                                                  sleptSinceLastReport: true, now: now)
        #expect(record.connectedWiFiTag == "c")
        #expect(!record.visibleWiFiTags.contains("c"), "The connected network isn't counted twice")
        #expect(record.visibleWiFiTags.count == PresenceReportBuilder.maximumVisibleTags)
        #expect(Set(record.visibleWiFiTags).count == record.visibleWiFiTags.count)
        #expect(record.sleptSinceLastEvidence)
        #expect(record.horizontalAccuracy == 30)

        let unusable = LocationFix(latitude: 1, longitude: 1, horizontalAccuracy: -1, observedAt: now, isSimulated: false)
        let none = PresenceReportBuilder.record(fix: unusable, fullAccuracy: true, connectedTag: nil, visibleTags: [],
                                                sleptSinceLastReport: false, now: now)
        #expect(none.latitude == nil && none.horizontalAccuracy == nil, "An invalid fix is not sent")

        let first = PresenceReportBuilder.report(record)
        let second = PresenceReportBuilder.report(record)
        #expect(second.sequence > first.sequence)
        #expect(second.uptimeNanoseconds >= first.uptimeNanoseconds)
        #expect(!first.bootSessionID.isEmpty)
        #expect(first.bootSessionID == PresenceSession.currentBootSessionID())
    }

    @Test func wifiTagsAreKeyedStableAndStoredPrivately() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldLocationKey-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("location-tag.key")
        let tagger = try WiFiTagger.loadOrCreate(at: url)
        let again = try WiFiTagger.loadOrCreate(at: url)
        #expect(tagger.tag("AA:BB:CC:DD:EE:FF") == again.tag("aa:bb:cc:dd:ee:ff"))
        #expect(!tagger.tag("aa:bb:cc:dd:ee:ff").lowercased().contains("aa:bb"), "No raw BSSID in a tag")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let other = try WiFiTagger.loadOrCreate(at: directory.appendingPathComponent("other.key"))
        #expect(other.tag("aa:bb:cc:dd:ee:ff") != tagger.tag("aa:bb:cc:dd:ee:ff"))
        #expect(PresenceReportBuilder.enrollmentTags(connected: "c", visible: (0..<40).map { "v\($0)" }).count == 24)
    }

    // MARK: Headline

    @Test func headlineNeverClaimsMoreThanTheServiceRecorded() {
        let now = at(12)
        #expect(LocationPresentation.headline(access: nil, places: [], presence: nil, now: now) == "No places yet")
        #expect(LocationPresentation.headline(access: .denied, places: [library], presence: nil, now: now)
                == "Location is off for Shield")
        #expect(LocationPresentation.headline(access: .allowed, places: [library], presence: nil, now: now)
                == "Location unknown")
        let old = PresenceSnapshot(capturedAt: now.addingTimeInterval(-200), locationKnown: true,
                                   places: ["library": .init(indicated: true)], studyMinutesToday: nil)
        #expect(LocationPresentation.headline(access: .allowed, places: [library], presence: old, now: now)
                == "Location unknown", "A record older than 120 s is unknown")
        let fresh = PresenceSnapshot(capturedAt: now, locationKnown: true,
                                     places: ["library": .init(indicated: true), "home": .init()], studyMinutesToday: nil)
        #expect(LocationPresentation.headline(access: .allowed, places: [home, library], presence: fresh, now: now)
                == "At Library")
        #expect(LocationPresentation.whereabouts(home, presence: fresh, now: now) == .notHere)
        #expect(LocationPresentation.headline(access: .allowed, places: [library], presence: nil, tracked: false, now: now)
                == "Your places", "Nothing uses a place: the service isn't checking, so no alarm")
        #expect(LocationPresentation.headline(access: .denied, places: [library], presence: nil, tracked: false, now: now)
                == "Location is off for Shield")
    }

    /// "Shield can't tell" with Location on and nothing blocked
    /// at a place read like a fault. Unknown now says why.
    @Test func rightNowSaysWhyLocationIsUnknown() {
        let now = at(12)
        #expect(LocationPresentation.rightNow(home, presence: nil, tracked: false, locationOn: true, now: now)
                == "Not checked")
        #expect(LocationPresentation.rightNow(home, presence: nil, tracked: true, locationOn: false, now: now)
                == "Location off")
        #expect(LocationPresentation.rightNow(home, presence: nil, tracked: true, locationOn: true, now: now)
                == "Location unknown")
        let fresh = PresenceSnapshot(capturedAt: now, locationKnown: true,
                                     places: ["library": .init(indicated: true), "home": .init()], studyMinutesToday: nil)
        #expect(LocationPresentation.rightNow(library, presence: fresh, tracked: true, locationOn: true, now: now) == "You're here")
        #expect(LocationPresentation.rightNow(home, presence: fresh, tracked: true, locationOn: true, now: now)
                == "You're somewhere else")
        let stale = PresenceSnapshot(capturedAt: now.addingTimeInterval(-200), locationKnown: true,
                                     places: ["library": .init(indicated: true)], studyMinutesToday: nil)
        #expect(LocationPresentation.rightNow(library, presence: stale, tracked: true, locationOn: true, now: now)
                == "Location unknown", "A stale record never says here")
        #expect(LocationPresentation.rowStatus(.unknown, tracked: false) == "Not checked")
        #expect(LocationPresentation.rowStatus(.unknown, tracked: true) == "Location unknown")
    }

    // MARK: Place blocks through the fixture authority

    private func backend() throws -> FixtureBackend {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldPlaceBlocks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
        return try FixtureBackend(root: root)
    }

    private func submit(_ backend: FixtureBackend, _ commands: [BackendCommand], now: Date) throws {
        let generation = (try? backend.snapshot(now: now, calendar: calendar).generation) ?? 0
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: generation,
                                             submittedAt: now, commands: commands), now: now, calendar: calendar)
    }

    private func blocked(_ backend: FixtureBackend, _ now: Date) throws -> (sites: Set<String>, apps: Set<AppTarget>) {
        let rules = try backend.snapshot(now: now, calendar: calendar).authority.effectiveRestrictions
        return (rules.reduce(into: Set<String>()) { $0.formUnion($1.domains) },
                rules.reduce(into: Set<AppTarget>()) { $0.formUnion($1.apps) })
    }

    /// A report built exactly as the app builds it, judged by the real gate.
    private func report(at place: RulePlace, wifi: String, now: Date) -> PresenceReport {
        PresenceReportBuilder.report(PresenceReportBuilder.record(
            fix: LocationFix(latitude: place.latitude, longitude: place.longitude, horizontalAccuracy: 25,
                             observedAt: now, isSimulated: false),
            fullAccuracy: true, connectedTag: wifi, visibleTags: [], sleptSinceLastReport: false, now: now))
    }

    private let game = AppTarget(displayName: "Example Game", bundleID: "com.example.game", teamID: "TEAM000001")

    private func placeBlock(_ now: Date) -> DomainRestriction {
        DomainRestriction(owner: .commitment, policyID: "focus-library", title: "netflix.com",
                          domains: ["netflix.com"], startsAt: now, apps: [game], placeID: "library")
    }

    @Test func aPlaceBlockAppliesThereAndWhenLocationIsUnknown() throws {
        let backend = try backend()
        let start = at(12)
        try submit(backend, [.add(DomainRestriction(owner: .permanent, policyID: "adult", title: "Adult",
                                                    domains: ["adult.example"]))], now: start)
        try submit(backend, [.add(home), .add(library)], now: start)
        try submit(backend, [.add(placeBlock(start))], now: start)
        #expect(try blocked(backend, start).sites.contains("netflix.com"), "Unknown location: blocked")
        #expect(try blocked(backend, start).apps == [game], "Its apps are blocked too")
        let document = try PropertyListDecoder().decode(BackendDocument.self,
                                                        from: Data(contentsOf: backend.paths.document))
        #expect(document.version >= 4, "Older services refuse a document with place blocks")
        #expect(BackendDocument.version(restrictions: document.restrictions, schedules: document.schedules,
                                        pendingReleases: document.pendingReleases, conditions: document.conditions) == 4)

        let session = PresenceSession()
        let away = start.addingTimeInterval(10)
        _ = try backend.reportPresence(report(at: home, wifi: "home-1", now: away), session: session,
                                       now: away, calendar: calendar)
        #expect(try !blocked(backend, away).sites.contains("netflix.com"), "Seen elsewhere: not blocked")
        #expect(try blocked(backend, away).apps.isEmpty)
        #expect(try blocked(backend, away).sites.contains("adult.example"), "Other blocks are untouched")

        let there = away.addingTimeInterval(20)
        _ = try backend.reportPresence(report(at: library, wifi: "lib-1", now: there), session: session,
                                       now: there, calendar: calendar)
        #expect(try blocked(backend, there).sites.contains("netflix.com"), "At the library: blocked")

        let back = there.addingTimeInterval(20)
        _ = try backend.reportPresence(report(at: home, wifi: "home-1", now: back), session: session,
                                       now: back, calendar: calendar)
        #expect(try !blocked(backend, back).sites.contains("netflix.com"))
        // Shield quit or the Mac slept: the record goes stale and the block returns.
        let later = back.addingTimeInterval(PresenceSnapshot.maximumAge + 5)
        _ = try backend.tick(now: later, calendar: calendar)
        #expect(try blocked(backend, later).sites.contains("netflix.com"), "Stale location: blocked again")
    }

    @Test func onlyAPreciseFreshFixCanLiftAPlaceBlock() throws {
        let backend = try backend()
        let start = at(12)
        try submit(backend, [.add(DomainRestriction(owner: .permanent, policyID: "adult", title: "Adult",
                                                    domains: ["adult.example"])), .add(home), .add(library)], now: start)
        try submit(backend, [.add(placeBlock(start))], now: start)
        let session = PresenceSession()
        var now = start
        func send(fix: LocationFix?, fullAccuracy: Bool = true, wifi: String? = "home-1") throws -> Bool {
            now = now.addingTimeInterval(12)
            let record = PresenceReportBuilder.record(fix: fix, fullAccuracy: fullAccuracy, connectedTag: wifi,
                                                      visibleTags: [], sleptSinceLastReport: false, now: now)
            _ = try backend.reportPresence(PresenceReportBuilder.report(record), session: session, now: now,
                                           calendar: calendar)
            return try blocked(backend, now).sites.contains("netflix.com")
        }
        func fixAtHome(age: TimeInterval = 0, simulated: Bool = false) -> LocationFix {
            LocationFix(latitude: home.latitude, longitude: home.longitude, horizontalAccuracy: 25,
                        observedAt: now.addingTimeInterval(12 - age), isSimulated: simulated)
        }
        // Location denied, Wi-Fi only: unknown, so the block holds.
        #expect(try send(fix: nil), "No fix: still blocked")
        #expect(try send(fix: fixAtHome(), fullAccuracy: false), "Approximate location: still blocked")
        #expect(try send(fix: fixAtHome(simulated: true)), "Simulated fix: still blocked")
        #expect(try send(fix: fixAtHome(age: 150)), "A fix older than two minutes: still blocked")
        #expect(try send(fix: nil, wifi: nil), "Nothing at all: still blocked")
        #expect(LocationPresentation.headline(access: .allowed, places: [home, library],
                                              presence: try backend.snapshot(now: now, calendar: calendar).conditions?.presence,
                                              now: now) == "Location unknown", "The Places page doesn't claim more")
        // A precise, fresh fix elsewhere is what lifts it.
        #expect(try !send(fix: fixAtHome()), "Seen at home with a good fix: not blocked")
        #expect(try backend.snapshot(now: now, calendar: calendar).authority.commitments
            .first { $0.id == "focus-library" }?.active == false, "Not reported active while it isn't applied")
    }

    @Test func placeBlocksKeepTheUsualRules() throws {
        let backend = try backend()
        let start = at(12)
        try submit(backend, [.add(DomainRestriction(owner: .permanent, policyID: "adult", title: "Adult",
                                                    domains: ["adult.example"])), .add(library)], now: start)
        // Only an "until released" block can name a place, and only a saved one.
        #expect(throws: (any Error).self) {
            try submit(backend, [.add(DomainRestriction(owner: .permanent, policyID: "focus-p", title: "P",
                                                        domains: ["a.example"], startsAt: start, placeID: "library"))],
                       now: start)
        }
        #expect(throws: (any Error).self) {
            try submit(backend, [.add(DomainRestriction(owner: .commitment, policyID: "focus-q", title: "Q",
                                                        domains: ["a.example"], startsAt: start, placeID: "gym"))],
                       now: start)
        }
        try submit(backend, [.add(placeBlock(start))], now: start)
        // A place in use can't be removed.
        #expect(throws: (any Error).self) {
            try submit(backend, [.removePlace("library", at: start.addingTimeInterval(86_460))], now: start)
        }
        // Releasing it waits 24 hours, like any "until released" block.
        #expect(throws: (any Error).self) {
            try submit(backend, [.release("focus-library", at: start.addingTimeInterval(3_600))], now: start)
        }
        try submit(backend, [.release("focus-library", at: start.addingTimeInterval(86_460))], now: start)
        #expect(try blocked(backend, start.addingTimeInterval(86_000)).sites.contains("netflix.com"))
        // Renaming is immediate and keeps the block.
        var renamed = library
        renamed.name = "Main library"
        try submit(backend, [.replace(renamed)], now: start)
        #expect(try backend.snapshot(now: start, calendar: calendar).conditions?.places.first?.name == "Main library")
    }

    /// Removing some websites from a place block keeps the rest at that place.
    @MainActor @Test func removingWebsitesKeepsThePlace() throws {
        let backend = try backend()
        let start = Date()
        func submit(_ commands: [BackendCommand]) throws {
            let generation = (try? backend.snapshot(now: start, calendar: .current).generation) ?? 0
            _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: generation,
                                                 submittedAt: start, commands: commands), now: start, calendar: .current)
        }
        try submit([.add(DomainRestriction(owner: .permanent, policyID: "adult", title: "Adult",
                                           domains: ["adult.example"])), .add(library)])
        let block = DomainRestriction(owner: .commitment, policyID: "focus-two", title: "a.example + 1 more",
                                      domains: ["a.example", "b.example"], startsAt: start, placeID: "library")
        try submit([.add(block)])
        let root = backend.paths.document.deletingLastPathComponent()
        let model = ShieldViewModel(authorityReader: AuthorityStateReader(fileURL: backend.paths.authority),
                                    enforcementReader: HostsEnforcementReader(fileURL: backend.paths.hosts),
                                    studyLibraryRoot: root.appendingPathComponent("study"), fixtureBackend: backend)
        model.refresh(now: start)
        #expect(model.removeSites(["b.example"], from: block, now: start) != nil, "\(model.backendActionMessage ?? "")")
        let kept = try #require(backend.snapshot(now: start, calendar: .current).committedRestrictions
            .first { $0.domains == ["a.example"] })
        #expect(kept.placeID == "library", "The kept website stays a Library block, not an everywhere block")
        #expect(ShieldGrouping.categoryID(for: kept, layout: model.categoryLayout) == ShieldCategoryLayout.locationID)
    }

    @Test func blocksWithoutAPlaceKeepTheirExactEncoding() throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let plain = DomainRestriction(owner: .commitment, policyID: "p", title: "P", domains: ["a.example"])
        #expect(!String(decoding: try encoder.encode(plain), as: UTF8.self).contains("placeID"))
        let located = placeBlock(at(12))
        let decoded = try PropertyListDecoder().decode(DomainRestriction.self, from: encoder.encode(located))
        #expect(decoded == located)
        #expect(decoded.with(owner: .commitment).placeID == "library")
    }
}
