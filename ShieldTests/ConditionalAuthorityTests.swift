import Foundation
import Testing
@testable import Shield

// Conditional rules wired into the fixture authority (blueprint §7).
// Nothing here runs against the installed service.
struct ConditionalAuthorityTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private func at(day: Int = 28, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private let library = RulePlace(id: "library", name: "Library", latitude: 40.7532, longitude: -73.9822,
                                    radiusMeters: 120, wifiTags: ["lib-ap-1", "lib-ap-2", "lib-ap-3"])
    private let home = RulePlace(id: "home", name: "Home", latitude: 40.7812, longitude: -73.9665,
                                 radiusMeters: 100, wifiTags: ["home-ap"], isHome: true)
    // Blocked 6 AM–11 PM (the stored BLOCKED complement, as for the real six).
    private let schedule = DailySchedule(id: "youtube", title: "YouTube", domains: ["youtube.com", "x.com"],
                                         startMinutes: 360, endMinutes: 1_380, isRequested: true)
    private let adult = DomainRestriction(owner: .permanent, policyID: "adult", title: "Adult",
                                          domains: ["adult.example"])
    private func tumblr(_ now: Date) -> DomainRestriction {
        DomainRestriction(owner: .commitment, policyID: "tumblr", title: "Tumblr", domains: ["tumblr.com"], startsAt: now)
    }
    private let youtubeAtLibrary = ConditionalRule(
        id: "yt-library", title: "YouTube at the library",
        domains: ["youtube.com", "adult.example", "tumblr.com"], effect: .allow,
        conditions: [.atPlace(placeID: "library", minimumDwellMinutes: 10)], committedAt: .distantPast)
    private let homeNight = ConditionalRule(
        id: "home-night", title: "Stricter at home", domains: ["reddit.com"], effect: .block,
        conditions: [.atPlace(placeID: "home", minimumDwellMinutes: 0)], committedAt: .distantPast)

    @discardableResult
    private func submit(_ backend: FixtureBackend, _ commands: [BackendCommand], now: Date) throws -> BackendRequest {
        let generation = (try? backend.snapshot(now: now, calendar: calendar).generation) ?? 0
        let request = BackendRequest(version: 1, id: UUID(), expectedGeneration: generation,
                                     submittedAt: now, commands: commands)
        _ = try backend.apply(request, now: now, calendar: calendar)
        return request
    }

    private func seeded(_ now: Date) throws -> FixtureBackend {
        let backend = try FixtureBackend(root: try conditionalBackendDirectory())
        try submit(backend, [.add(schedule), .add(adult), .add(tumblr(now))], now: now)
        return backend
    }

    private func report(_ sequence: UInt64, now: Date, atLibrary: Bool = true, boot: String = "boot-A") -> PresenceReport {
        let spot = atLibrary ? library : home
        return PresenceReport(sequence: sequence, bootSessionID: boot, uptimeNanoseconds: sequence * 1_000_000_000,
            evidence: PresenceEvidenceRecord(latitude: spot.latitude, longitude: spot.longitude, horizontalAccuracy: 20,
                fixObservedAt: now, isSimulated: false, fullAccuracy: true, observedAt: now,
                connectedWiFiTag: atLibrary ? "lib-ap-1" : "home-ap", visibleWiFiTags: [], sleptSinceLastEvidence: false))
    }

    // MARK: 1. Policy model and schema

    @Test func schemaBumpsOnlyWithConditionsAndOldReadersRefuse() throws {
        let now = at(10)
        let backend = try seeded(now)
        let plainDocument = try PropertyListDecoder().decode(BackendDocument.self,
            from: Data(contentsOf: backend.paths.document))
        // Shield 1.1 writes 6 for its removal record; conditions alone would make 4.
        #expect(plainDocument.version == 6)
        #expect(BackendDocument.version(restrictions: plainDocument.restrictions, schedules: plainDocument.schedules,
                                        pendingReleases: plainDocument.pendingReleases) == 2)
        #expect(try backend.snapshot(now: now, calendar: calendar).authority.schemaVersion == 1)

        try submit(backend, [.add(home), .add(homeNight)], now: now)
        let document = try PropertyListDecoder().decode(BackendDocument.self, from: Data(contentsOf: backend.paths.document))
        #expect(document.version == 6)
        #expect(BackendDocument.version(restrictions: document.restrictions, schedules: document.schedules,
                                        pendingReleases: document.pendingReleases, conditions: document.conditions) == 4)
        // Older services accept `1...2` (before apps) or `1...3` (apps): both refuse this document.
        #expect(!(1...3).contains(document.version))
        #expect(document.conditions?.places == [home])
        #expect(document.conditions?.rules.map(\.id) == ["home-night"])
        let snapshot = try backend.snapshot(now: now, calendar: calendar)
        #expect(snapshot.authority.schemaVersion == 2)
        #expect(snapshot.authority.conditions?.rules.map(\.id) == ["home-night"])
        #expect(snapshot.conditions == document.conditions)

        // Readers: schema 2 is accepted; a future schema and a schema-1 state
        // carrying conditions are refused.
        func read(_ state: AuthorityState) throws -> AuthorityStatus {
            let url = backend.paths.root.appendingPathComponent("probe-authority.plist")
            try PropertyListEncoder().encode(state).write(to: url)
            return AuthorityStateReader(fileURL: url, maximumAge: .infinity).read(now: now)
        }
        let state = snapshot.authority
        guard case .valid = try read(state) else { Issue.record("schema 2 refused"); return }
        func copy(_ version: Int, _ conditions: ConditionalAuthorityState?) -> AuthorityState {
            AuthorityState(schemaVersion: version, generation: state.generation, generatedAt: state.generatedAt,
                           reconciliationID: state.reconciliationID,
                           lastSuccessfulReconciliation: state.lastSuccessfulReconciliation,
                           commitments: state.commitments, effectiveRestrictions: state.effectiveRestrictions,
                           conditions: conditions)
        }
        #expect(try read(copy(3, state.conditions)) == .unavailable(.unsupportedSchema(3)))
        #expect(try read(copy(1, state.conditions)) == .unavailable(.unsupportedSchema(1)))
    }

    // MARK: 2. Commands

    @Test func placeAndRuleChangesApplyNowOnlyWhenStronger() throws {
        let now = at(10)
        let later = now.addingTimeInterval(86_400)
        let backend = try seeded(now)
        func rejects(_ commands: [BackendCommand]) {
            #expect(throws: FixtureBackendError.self) { try submit(backend, commands, now: now) }
        }
        // Adding a place is immediate and takes no date.
        rejects([.add(home), BackendCommand(kind: .addPlace, restriction: nil, schedule: nil, policyID: nil,
                                            effectiveAt: later, place: library)])
        try submit(backend, [.add(home), .add(library)], now: now)
        // A block rule applies at once; a date is refused.
        rejects([.add(homeNight, at: later)])
        try submit(backend, [.add(homeNight)], now: now)
        // An allow rule waits at least 24 hours.
        rejects([.add(youtubeAtLibrary)])
        rejects([.add(youtubeAtLibrary, at: later.addingTimeInterval(-60))])
        let addAllow = try submit(backend, [.add(youtubeAtLibrary, at: later)], now: now)
        var snapshot = try backend.snapshot(now: now, calendar: calendar)
        #expect(snapshot.conditions?.rules.map(\.id) == ["home-night"])
        let pendingAllow = try #require(snapshot.pendingReleases.first { $0.policyID == "rule:yt-library" })
        #expect(pendingAllow.effectiveAt == later)
        #expect(pendingAllow.replacementRule?.committedAt == now)   // the service dates it
        // Moving a place waits; renaming applies at once.
        var moved = library
        moved.latitude += 0.01
        rejects([.replace(moved)])
        var renamed = library
        renamed.name = "Main library"
        try submit(backend, [.replace(renamed)], now: now)
        // Removing home while a pending exception needs it would leave no veto.
        rejects([.removePlace("home", at: later)])
        // Removing a place a rule still names is refused, now or after landing.
        rejects([.removePlace("library", at: later)])
        // Widening a block rule is immediate; dropping it waits.
        var wider = homeNight
        wider.domains.insert("instagram.com")
        try submit(backend, [.replace(wider)], now: now)
        rejects([.removeRule("home-night")])
        let removeBlock = try submit(backend, [.removeRule("home-night", at: later)], now: now)
        snapshot = try backend.snapshot(now: now, calendar: calendar)
        #expect(snapshot.conditions?.places.first { $0.id == "library" }?.name == "Main library")
        #expect(snapshot.conditions?.rules.first?.domains == ["reddit.com", "instagram.com"])
        #expect(snapshot.pendingReleases.contains { $0.policyID == "rule:home-night" && $0.replacementRule == nil })

        // Both pending changes are recognized from authenticated state even after
        // another request advanced the receipt.
        try submit(backend, [.cancelPending("rule:home-night")], now: now)
        snapshot = try backend.snapshot(now: now, calendar: calendar)
        #expect(PendingPolicySubmission(version: 1, request: addAllow, schedulePreferences: nil).isConfirmed(by: snapshot))
        #expect(!PendingPolicySubmission(version: 1, request: removeBlock, schedulePreferences: nil).isConfirmed(by: snapshot))
        #expect(snapshot.conditions?.rules.contains { $0.id == "home-night" } == true)

        // The exception lands when due, already past its 24-hour wait.
        _ = try backend.tick(now: later, calendar: calendar)
        snapshot = try backend.snapshot(now: later, calendar: calendar)
        let landed = try #require(snapshot.conditions?.rules.first { $0.id == "yt-library" })
        #expect(landed.sameContent(as: youtubeAtLibrary))
        #expect(later.timeIntervalSince(landed.committedAt) >= ConditionalRule.precommitment)
        #expect(snapshot.pendingReleases.isEmpty)
        // Removing an allow rule is immediate. The schedule is untouched throughout.
        try submit(backend, [.removeRule("yt-library")], now: later)
        snapshot = try backend.snapshot(now: later, calendar: calendar)
        #expect(snapshot.conditions?.rules.map(\.id) == ["home-night"])
        #expect(snapshot.committedSchedules == [schedule])
    }

    @Test func malformedOrForeignConditionalCommandsAreRefused() throws {
        let now = at(10)
        let backend = try seeded(now)
        var tiny = home
        tiny.radiusMeters = 20
        var badDomain = homeNight
        badDomain.domains = ["Not A Domain"]
        var badWindow = homeNight
        badWindow.conditions = [.timeWindow(startMinute: 1_500, endMinute: 10, weekdays: [])]
        for commands: [BackendCommand] in [[.add(tiny)], [.add(home), .add(badDomain)], [.add(home), .add(badWindow)],
                                            [.add(homeNight)],   // names a place that doesn't exist
                                            [.add(DomainRestriction(owner: .conditional, policyID: "c", title: "C", domains: ["c.example"]))],
                                            [.add(DomainRestriction(owner: .commitment, policyID: "rule:x", title: "X", domains: ["x.example"]))],
                                            [BackendCommand(kind: .addRestriction, restriction: adult, schedule: nil,
                                                            policyID: nil, effectiveAt: nil, place: home)]] {
            #expect(throws: FixtureBackendError.self) { try submit(backend, commands, now: now) }
        }
        #expect(try backend.snapshot(now: now, calendar: calendar).conditions == nil)
    }

    // MARK: 3. Evaluation

    @Test func rulesLayerOverBaseAndNeverOpenProtectedOwners() {
        let now = at(15)
        let engine = UnifiedPolicyEngine()
        let restrictions = [adult, tumblr(now.addingTimeInterval(-60))]
        let earned = ConditionalRule(id: "earned", title: "Earned", domains: ["youtube.com", "adult.example", "tumblr.com"],
                                     effect: .allow, conditions: [.studiedToday(minimumMinutes: 30)], committedAt: .distantPast)
        let extra = ConditionalRule(id: "extra", title: "Extra", domains: ["reddit.com"], effect: .block,
                                    conditions: [], committedAt: .distantPast)
        let studied = PresenceSnapshot(capturedAt: now, locationKnown: false, places: [:], studyMinutesToday: 45)
        let conditions = ConditionalPolicy(places: [], rules: [earned, extra], presence: studied)
        let base = engine.evaluate(restrictions: restrictions, schedules: [schedule], at: now, calendar: calendar)
        let result = engine.evaluate(restrictions: restrictions, schedules: [schedule], at: now, calendar: calendar,
                                     conditions: conditions)
        #expect(base.domains == ["youtube.com", "x.com", "adult.example", "tumblr.com"])
        // Only the schedule-only domain opens; permanent and Until-released stay.
        #expect(result.domains == ["x.com", "adult.example", "tumblr.com", "reddit.com"])
        #expect(result.conditional?.openedBy == ["youtube.com": "earned"])
        let recurring = result.restrictions.first { $0.owner == .recurring }
        #expect(recurring?.policyID == "youtube" && recurring?.domains == ["x.com"])
        #expect(result.restrictions.contains { $0.owner == .conditional && $0.policyID == "rule:extra" && $0.domains == ["reddit.com"] })
        #expect(Set(result.restrictions.flatMap(\.domains)) == result.domains)
        // Unknown study time: the exception fails, so the base stands (plus the block rule).
        let unknown = engine.evaluate(restrictions: restrictions, schedules: [schedule], at: now, calendar: calendar,
                                      conditions: ConditionalPolicy(places: [], rules: [earned, extra], presence: nil))
        #expect(unknown.domains == base.domains.union(["reddit.com"]))
        // Outside the schedule's blocked hours nothing is opened or invented.
        let night = at(23, 30)
        #expect(engine.evaluate(restrictions: restrictions, schedules: [schedule], at: night, calendar: calendar,
                                conditions: conditions).domains == ["adult.example", "tumblr.com", "reddit.com"])
        // No rules: identical to the base engine.
        let plain = engine.evaluate(restrictions: restrictions, schedules: [schedule], at: now, calendar: calendar,
                                    conditions: .empty)
        #expect(plain.domains == base.domains && plain.nextTransition == base.nextTransition && plain.conditional == nil)
    }

    // MARK: 4. Presence reports

    @Test func presenceOpensOnlyAfterDwellCommitsSparinglyAndReplays() throws {
        let start = at(10)
        let backend = try seeded(start)
        try submit(backend, [.add(home), .add(library), .add(youtubeAtLibrary, at: start.addingTimeInterval(86_400))],
                   now: start)
        let now0 = start.addingTimeInterval(86_400)
        _ = try backend.tick(now: now0, calendar: calendar)
        let session = PresenceSession(bootSessionID: "boot-A")
        let firstGeneration = try backend.snapshot(now: now0, calendar: calendar).generation

        var now = now0
        var openedAt: Date?
        var unchanged = 0
        for step in 1...66 {
            now = now0.addingTimeInterval(TimeInterval(step * 10))
            let ack = try backend.reportPresence(report(UInt64(step), now: now), session: session, now: now, calendar: calendar)
            if ack.status == .unchanged { unchanged += 1 }
            let blocked = try backend.snapshot(now: now, calendar: calendar).enforcement.blockedDomains
            if openedAt == nil, !blocked.contains("youtube.com") { openedAt = now }
            // Never-relaxable owners stay blocked whatever the rule says.
            #expect(blocked.isSuperset(of: ["adult.example", "tumblr.com", "x.com"]))
        }
        // Opens only once the first verified fix is 10 minutes old.
        let opened = try #require(openedAt)
        #expect(opened.timeIntervalSince(now0.addingTimeInterval(10)) >= 600)
        // Unchanged reports within 30 s of the stored record commit nothing.
        let commits = try backend.snapshot(now: now, calendar: calendar).generation - firstGeneration
        #expect(unchanged >= 40)
        #expect(Int(commits) + unchanged == 66)

        // A replayed or foreign-boot report is refused and changes nothing stored.
        let generation = try backend.snapshot(now: now, calendar: calendar).generation
        #expect(throws: FixtureBackendError.self) {
            try backend.reportPresence(report(66, now: now), session: session, now: now, calendar: calendar)
        }
        #expect(throws: FixtureBackendError.self) {
            try backend.reportPresence(report(67, now: now, boot: "boot-B"), session: session, now: now, calendar: calendar)
        }
        #expect(try backend.snapshot(now: now, calendar: calendar).generation == generation)

        // The committed state still verifies long after its record went stale
        // (replay uses the stored record), and maintenance closes the exception.
        let quiet = now.addingTimeInterval(PresenceSnapshot.maximumAge + 5)
        _ = try backend.tick(now: quiet, calendar: calendar)
        let closed = try backend.snapshot(now: quiet, calendar: calendar)
        #expect(closed.enforcement.blockedDomains.contains("youtube.com"))
        #expect(closed.authority.conditions?.openedBy.isEmpty == true)
        #expect(closed.committedSchedules == [schedule])
        _ = try backend.tick(now: quiet.addingTimeInterval(90), calendar: calendar)
        _ = try backend.snapshot(now: quiet.addingTimeInterval(90), calendar: calendar)
    }

    @Test func aServiceRestartForgetsWhereTheMacWas() throws {
        let now = at(10)
        let backend = try seeded(now)
        try submit(backend, [.add(library)], now: now)
        try submit(backend, [.add(DomainRestriction(owner: .commitment, policyID: "library-netflix", title: "netflix.com",
                                                    domains: ["netflix.com"], startsAt: now, placeID: "library"))],
                   now: now)
        #expect(try backend.forgetPresence(now: now, calendar: calendar) == nil, "Nothing known, nothing to forget")
        let elsewhere = now.addingTimeInterval(10)
        _ = try backend.reportPresence(report(1, now: elsewhere, atLibrary: false),
                                       session: PresenceSession(bootSessionID: "boot-A"), now: elsewhere,
                                       calendar: calendar)
        #expect(try !backend.snapshot(now: elsewhere, calendar: calendar).enforcement.blockedDomains.contains("netflix.com"))

        // The new run trusts nothing from the old one: the place block is back at once.
        let restart = elsewhere.addingTimeInterval(5)
        #expect(try backend.forgetPresence(now: restart, calendar: calendar)?.status == .applied)
        let after = try backend.snapshot(now: restart, calendar: calendar)
        #expect(after.enforcement.blockedDomains.contains("netflix.com"))
        #expect(after.conditions?.presence?.locationKnown == false)
        #expect(after.committedRestrictions.contains { $0.policyID == "library-netflix" })
        #expect(try backend.forgetPresence(now: restart.addingTimeInterval(1), calendar: calendar) == nil)
    }

    @Test func unknownOrRepeatedReportsCommitNothing() throws {
        let now = at(10)
        let backend = try seeded(now)
        try submit(backend, [.add(library)], now: now)
        try submit(backend, [.add(DomainRestriction(owner: .commitment, policyID: "library-netflix", title: "netflix.com",
                                                    domains: ["netflix.com"], startsAt: now, placeID: "library"))],
                   now: now)
        let session = PresenceSession(bootSessionID: "boot-A")
        let start = try backend.snapshot(now: now, calendar: calendar).generation
        // Location denied: unknown reports lift nothing, so nothing is written.
        for step in 1...3 {
            let at = now.addingTimeInterval(TimeInterval(step * 10))
            let unknown = PresenceReport(sequence: UInt64(step), bootSessionID: "boot-A",
                uptimeNanoseconds: UInt64(step) * 1_000_000_000,
                evidence: PresenceEvidenceRecord(latitude: nil, longitude: nil, horizontalAccuracy: nil,
                    fixObservedAt: nil, isSimulated: false, fullAccuracy: false, observedAt: at,
                    connectedWiFiTag: nil, visibleWiFiTags: [], sleptSinceLastEvidence: false))
            #expect(try backend.reportPresence(unknown, session: session, now: at, calendar: calendar).status == .unchanged)
        }
        #expect(try backend.snapshot(now: now.addingTimeInterval(30), calendar: calendar).generation == start)
        // One fix elsewhere commits once; the same fix again commits nothing.
        let fixTime = now.addingTimeInterval(40)
        func elsewhere(_ sequence: UInt64, at: Date) -> PresenceReport {
            PresenceReport(sequence: sequence, bootSessionID: "boot-A", uptimeNanoseconds: sequence * 1_000_000_000,
                evidence: PresenceEvidenceRecord(latitude: home.latitude, longitude: home.longitude, horizontalAccuracy: 20,
                    fixObservedAt: fixTime, isSimulated: false, fullAccuracy: true, observedAt: at,
                    connectedWiFiTag: nil, visibleWiFiTags: [], sleptSinceLastEvidence: false))
        }
        #expect(try backend.reportPresence(elsewhere(4, at: fixTime), session: session, now: fixTime,
                                           calendar: calendar).status == .applied)
        let later = fixTime.addingTimeInterval(50)
        #expect(try backend.reportPresence(elsewhere(9, at: later), session: session, now: later,
                                           calendar: calendar).status == .unchanged)
        #expect(try backend.snapshot(now: later, calendar: calendar).generation == start + 1)
    }

    @Test func movingAPlaceForgetsItsRecordedVerdict() throws {
        let start = at(10)
        let backend = try seeded(start)
        let due = start.addingTimeInterval(86_400)
        try submit(backend, [.add(home), .add(library), .add(youtubeAtLibrary, at: due)], now: start)
        _ = try backend.tick(now: due, calendar: calendar)
        var moved = library
        moved.radiusMeters = 150
        let moveDue = due.addingTimeInterval(86_400 + 600)
        try submit(backend, [.replace(moved, at: moveDue)], now: due)
        let session = PresenceSession(bootSessionID: "boot-A")
        // Present and verified until 90 s before the move lands (record still fresh).
        var now = moveDue.addingTimeInterval(-700)
        for step in 1...61 {
            now = now.addingTimeInterval(10)
            _ = try backend.reportPresence(report(UInt64(step), now: now), session: session, now: now, calendar: calendar)
        }
        #expect(try !backend.snapshot(now: now, calendar: calendar).enforcement.blockedDomains.contains("youtube.com"))
        _ = try backend.tick(now: moveDue, calendar: calendar)
        let after = try backend.snapshot(now: moveDue, calendar: calendar)
        #expect(after.conditions?.places.contains(moved) == true)
        #expect(after.conditions?.presence?.places["library"] == nil)
        #expect(after.enforcement.blockedDomains.contains("youtube.com"))
    }

    @Test func presenceTravelsOverTheXPCWire() throws {
        let now = Date()
        let backend = try FixtureBackend(root: try conditionalBackendDirectory())
        try submit(backend, [.add(schedule), .add(home), .add(homeNight)], now: now)
        let service = try FixtureBackendXPCService(backend: backend, peerPolicy: .currentProcessForTests,
                                                   presenceSession: PresenceSession(bootSessionID: "boot-X"))
        service.resume()
        defer { service.invalidate() }
        let connection = NSXPCConnection(listenerEndpoint: service.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: FixtureBackendXPCWire.self)
        connection.resume()
        defer { connection.invalidate() }
        let remote = try #require(connection.remoteObjectProxyWithErrorHandler({ _ in }) as? FixtureBackendXPCWire)
        func send(_ value: PresenceReport) throws -> (Data?, String?) {
            let done = DispatchSemaphore(value: 0)
            var result: (Data?, String?) = (nil, nil)
            remote.reportPresence(try JSONEncoder().encode(value) as NSData) { data, error in
                result = (data as Data?, error as String?)
                done.signal()
            }
            #expect(done.wait(timeout: .now() + 10) == .success)
            return result
        }
        let atHome = report(1, now: now, atLibrary: false, boot: "boot-X")
        let (bytes, error) = try send(atHome)
        #expect(error == nil)
        let ack = try JSONDecoder().decode(BackendAcknowledgment.self, from: #require(bytes))
        #expect(ack.status == .applied)
        #expect(try backend.snapshot(now: .now, calendar: .current).conditions?.presence?.places["home"]?.indicated == true)
        let (replayBytes, replayError) = try send(atHome)
        #expect(replayBytes == nil)
        #expect(replayError?.contains("refused") == true)

        // The service says it understands places; an older one says nothing.
        let done = DispatchSemaphore(value: 0)
        var envelopeBytes: Data?
        remote.snapshot { data, _ in envelopeBytes = data as Data?; done.signal() }
        #expect(done.wait(timeout: .now() + 10) == .success)
        var envelope = try JSONDecoder().decode(FixtureSnapshotEnvelope.self, from: #require(envelopeBytes))
        #expect(envelope.features == [BackendSnapshot.placesFeature, BackendSnapshot.goDaysFeature,
                                      BackendSnapshot.permanentRemovalFeature])
        #expect(envelope.permanentRemoval?.wait == PermanentRemovalPolicy.defaultWait)
        envelope.features = nil
        let older = try JSONDecoder().decode(FixtureSnapshotEnvelope.self, from: JSONEncoder().encode(envelope))
        #expect(older.features == nil, "No features key means no place support")
    }

    @Test func bootSessionIdentifierIsReadable() {
        #expect(!PresenceSession.currentBootSessionID().isEmpty)
    }
}

private func conditionalBackendDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShieldConditionalTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
    return root
}
