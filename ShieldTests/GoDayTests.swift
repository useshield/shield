import Foundation
import Testing
@testable import Shield

// "Go there today" (docs/conditional-rules-blueprint.md §8). Browsers and chosen
// apps stay closed until the service confirms this Mac reached a chosen place,
// then stay open for the rest of the day. Nothing here touches the installed service.
struct GoDayTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private func at(month: Int = 10, day: Int = 31, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    // About 5.5 km apart.
    private let library = GoDayGate.Place(name: "Library", latitude: 40.7532, longitude: -73.9822, radiusMeters: 150)
    private let home = (latitude: 40.7681, longitude: -73.9819)
    private let schedule = DailySchedule(id: "youtube", title: "YouTube", domains: ["youtube.com"],
                                         startMinutes: 360, endMinutes: 1_380, isRequested: true)
    private let discord = AppTarget(displayName: "Discord", bundleID: "com.hnc.Discord", teamID: "53Q6R32WPB")

    private func gate(places: [GoDayGate.Place]? = nil, startTags: Set<String> = ["home-ap-1", "home-ap-2"],
                      startFix: GoDayGate.StartFix? = nil) -> GoDayGate {
        GoDayGate(places: places ?? [library], startTags: startTags,
                  startFix: startFix ?? .init(latitude: home.latitude, longitude: home.longitude, horizontalAccuracy: 30))
    }

    private func day(_ now: Date, id: String = "goday-1", gate: GoDayGate? = nil, until: Date? = nil,
                     apps: Set<AppTarget> = [.webBrowsers]) -> DomainRestriction {
        DomainRestriction(owner: .temporary, policyID: id, title: "Go to Library", domains: [],
                          startsAt: now.addingTimeInterval(GoDayGate.undoWindow), endsAt: until ?? at(21),
                          apps: apps, goDay: gate ?? self.gate())
    }

    private func evidence(_ now: Date, latitude: Double? = nil, longitude: Double? = nil, accuracy: Double = 30,
                          fixAge: TimeInterval = 0, simulated: Bool = false, connected: String? = nil,
                          visible: Set<String> = [], slept: Bool = false) -> PresenceEvidence {
        PresenceEvidence(observedAt: now,
                         fix: .init(latitude: latitude ?? library.latitude, longitude: longitude ?? library.longitude,
                                    horizontalAccuracy: accuracy, observedAt: now.addingTimeInterval(-fixAge),
                                    isSimulated: simulated, fullAccuracy: true),
                         connectedWiFiTag: connected, visibleWiFiTags: visible, sleptSinceLastEvidence: slept)
    }

    private func report(_ sequence: UInt64, uptime seconds: UInt64, now: Date, atLibrary: Bool = true,
                        boot: String = "boot-A") -> PresenceReport {
        PresenceReport(sequence: sequence, bootSessionID: boot, uptimeNanoseconds: seconds * 1_000_000_000,
            evidence: PresenceEvidenceRecord(
                latitude: atLibrary ? library.latitude : home.latitude,
                longitude: atLibrary ? library.longitude : home.longitude, horizontalAccuracy: 30,
                fixObservedAt: now, isSimulated: false, fullAccuracy: true, observedAt: now,
                connectedWiFiTag: atLibrary ? "lib-ap" : "home-ap-1", visibleWiFiTags: [],
                sleptSinceLastEvidence: false))
    }

    @discardableResult
    private func submit(_ backend: FixtureBackend, _ commands: [BackendCommand], now: Date) throws -> BackendAcknowledgment {
        let generation = (try? backend.snapshot(now: now, calendar: calendar).generation) ?? 0
        let request = BackendRequest(version: 1, id: UUID(), expectedGeneration: generation,
                                     submittedAt: now, commands: commands)
        return try backend.apply(request, now: now, calendar: calendar)
    }

    private func seeded(_ now: Date) throws -> FixtureBackend {
        let backend = try FixtureBackend(root: try goDayBackendDirectory())
        try submit(backend, [.add(schedule)], now: now)
        return backend
    }

    /// After the service's maintenance pass at `now`, as the running service would.
    private func blocksBrowsers(_ backend: FixtureBackend, at now: Date) throws -> Bool {
        _ = try backend.tick(now: now, calendar: calendar)
        return try backend.snapshot(now: now, calendar: calendar).authority.effectiveRestrictions
            .contains { $0.apps.contains(.webBrowsers) }
    }

    // MARK: Arriving

    @Test func aPreciseRealFixInsideThePlaceQualifies() {
        let now = at(10)
        #expect(GoDayArrival.qualifies(evidence(now), gate: gate(), now: now))
        #expect(GoDayArrival.qualifies(evidence(now, accuracy: 100), gate: gate(), now: now))
        #expect(!GoDayArrival.qualifies(evidence(now, accuracy: 101), gate: gate(), now: now), "Too rough")
        #expect(!GoDayArrival.qualifies(evidence(now, simulated: true), gate: gate(), now: now), "Simulated")
        #expect(!GoDayArrival.qualifies(evidence(now, slept: true), gate: gate(), now: now), "First reading after a wake")
        #expect(!GoDayArrival.qualifies(evidence(now, fixAge: 61), gate: gate(), now: now), "Old fix")
        // About 500 m north of the library's centre: outside a 150 m place.
        #expect(!GoDayArrival.qualifies(evidence(now, latitude: library.latitude + 0.0045), gate: gate(), now: now))
        let noFix = PresenceEvidence(observedAt: now, fix: nil, connectedWiFiTag: "lib-ap", visibleWiFiTags: [],
                                     sleptSinceLastEvidence: false)
        #expect(!GoDayArrival.qualifies(noFix, gate: gate(), now: now), "Location off: never arrived")
    }

    @Test func whereTheDayBeganNeverCountsAsArriving() {
        let now = at(10)
        #expect(!GoDayArrival.qualifies(evidence(now, connected: "home-ap-1"), gate: gate(), now: now))
        #expect(!GoDayArrival.qualifies(evidence(now, visible: ["home-ap-1", "home-ap-2"]), gate: gate(), now: now))
        #expect(GoDayArrival.qualifies(evidence(now, visible: ["home-ap-1", "lib-ap"]), gate: gate(), now: now),
                "One home network seen from far away is not a veto")
        // A fix right where the day began never qualifies, whatever the pin says.
        let pinnedAtHome = gate(places: [.init(name: "Fake", latitude: home.latitude, longitude: home.longitude,
                                               radiusMeters: 150)])
        #expect(!GoDayArrival.qualifies(evidence(now, latitude: home.latitude, longitude: home.longitude),
                                        gate: pinnedAtHome, now: now))
    }

    // MARK: What the app sends

    @Test func theAppsGoDayIsOneTheServiceTakes() throws {
        let now = at(9)
        let libraryPlace = RulePlace(id: "place-lib", name: "Library", latitude: library.latitude,
                                     longitude: library.longitude, radiusMeters: 1_500, wifiTags: [])
        let homePlace = RulePlace(id: "place-home", name: "Home", latitude: home.latitude, longitude: home.longitude,
                                  radiusMeters: 150, wifiTags: ["home-ap-1"], isHome: true)
        let fix = GoDayGate.StartFix(latitude: home.latitude, longitude: home.longitude, horizontalAccuracy: 30)
        let made = ShieldViewModel.makeGoDay(places: [libraryPlace, homePlace], startFix: fix, startTags: [],
                                             until: at(21), apps: [discord], now: now)
        let day = try made.get()
        #expect(day.goDay?.places.map(\.name) == ["Library"], "Home is never a destination")
        #expect(day.goDay?.places.first?.radiusMeters == GoDayGate.radiusRange.upperBound, "Big places are capped")
        #expect(day.apps == [.webBrowsers, discord])
        #expect(day.startsAt == now.addingTimeInterval(GoDayGate.undoWindow))

        let backend = try seeded(now)
        #expect(try submit(backend, [.add(day)], now: now).status == .applied)
        #expect(try blocksBrowsers(backend, at: now.addingTimeInterval(180)))
        let session = PresenceSession(bootSessionID: "boot-A")
        let t = now.addingTimeInterval(3_600)
        _ = try backend.reportPresence(report(1, uptime: 100, now: t), session: session, now: t, calendar: calendar)
        let t2 = t.addingTimeInterval(21)
        _ = try backend.reportPresence(report(2, uptime: 121, now: t2), session: session, now: t2, calendar: calendar)
        #expect(try !blocksBrowsers(backend, at: t2.addingTimeInterval(1)))
    }

    /// A day can block websites instead of browsers. They're
    /// blocked from the start until this Mac gets there, like everything else.
    @Test func websitesWithoutBrowsersAreBlockedUntilArriving() throws {
        let now = at(9)
        let libraryPlace = RulePlace(id: "place-lib", name: "Library", latitude: library.latitude,
                                     longitude: library.longitude, radiusMeters: 150, wifiTags: [])
        let fix = GoDayGate.StartFix(latitude: home.latitude, longitude: home.longitude, horizontalAccuracy: 30)
        let day = try ShieldViewModel.makeGoDay(places: [libraryPlace], startFix: fix, startTags: [], until: at(21),
                                                apps: [], browsers: false, domains: ["reddit.com"], now: now).get()
        #expect(day.domains == ["reddit.com", "www.reddit.com"], "www. is added for you")
        #expect(day.apps.isEmpty, "Browsers left open when not chosen")
        #expect(day.isWellFormedGoDay)

        let backend = try seeded(now)
        #expect(try submit(backend, [.add(day)], now: now).status == .applied)
        func blocksReddit(at time: Date) throws -> Bool {
            _ = try backend.tick(now: time, calendar: calendar)
            return try backend.snapshot(now: time, calendar: calendar).authority.effectiveRestrictions
                .contains { $0.domains.contains("www.reddit.com") }
        }
        #expect(try !blocksReddit(at: now.addingTimeInterval(60)), "Nothing during the 2 minutes to undo")
        #expect(try blocksReddit(at: now.addingTimeInterval(180)))
        #expect(try !blocksBrowsers(backend, at: now.addingTimeInterval(181)))
        let session = PresenceSession(bootSessionID: "boot-A")
        let t = now.addingTimeInterval(3_600)
        _ = try backend.reportPresence(report(1, uptime: 100, now: t), session: session, now: t, calendar: calendar)
        let t2 = t.addingTimeInterval(21)
        _ = try backend.reportPresence(report(2, uptime: 121, now: t2), session: session, now: t2, calendar: calendar)
        #expect(try !blocksReddit(at: t2.addingTimeInterval(1)), "Open once you get there")

        let empty = ShieldViewModel.makeGoDay(places: [libraryPlace], startFix: fix, startTags: [], until: at(21),
                                              apps: [], browsers: false, now: now)
        #expect((try? empty.get()) == nil, "Nothing to block")
    }

    @Test func theAppRefusesDaysItCantStart() {
        let now = at(9)
        let fix = GoDayGate.StartFix(latitude: home.latitude, longitude: home.longitude, horizontalAccuracy: 30)
        let nextDoor = RulePlace(id: "p", name: "Cafe", latitude: home.latitude + 0.002, longitude: home.longitude,
                                 radiusMeters: 150, wifiTags: [])
        let far = RulePlace(id: "q", name: "Library", latitude: library.latitude, longitude: library.longitude,
                            radiusMeters: 150, wifiTags: [])
        func refusal(_ places: [RulePlace], fix: GoDayGate.StartFix?, tags: Set<String> = [], until: Date) -> String? {
            if case .failure(let refusal) = ShieldViewModel.makeGoDay(places: places, startFix: fix, startTags: tags,
                                                                      until: until, apps: [], now: now) {
                return refusal.message
            }
            return nil
        }
        #expect(refusal([nextDoor], fix: fix, until: at(21))?.contains("already at Cafe") == true)
        #expect(refusal([far], fix: nil, until: at(21))?.contains("where you are now") == true)
        #expect(refusal([far], fix: nil, tags: ["a", "b"], until: at(21)) == nil, "Two Wi-Fi tags are enough")
        #expect(refusal([far], fix: fix, until: now.addingTimeInterval(300))?.contains("end time") == true)
        #expect(refusal([], fix: fix, until: at(21))?.contains("Pick where") == true)
    }

    @Test func arrivingNeedsTwoReadingsTwentySecondsApart() {
        let now = at(10)
        let running = day(at(9))
        let second: UInt64 = 1_000_000_000
        // A fresh fix at each report, `offset` seconds after `now`.
        func observe(_ c: inout GoDayConfirmation, _ offset: UInt64, _ e: ((Date) -> PresenceEvidence)? = nil) -> Set<String> {
            let time = now.addingTimeInterval(TimeInterval(offset))
            return c.observe(e?(time) ?? evidence(time), uptime: (100 + offset) * second, days: [running], now: time)
        }
        var confirmation = GoDayConfirmation()
        #expect(observe(&confirmation, 0).isEmpty)
        #expect(observe(&confirmation, 19).isEmpty)
        #expect(observe(&confirmation, 20) == ["goday-1"])

        // One fix sent twice is one reading, however far apart the reports.
        var repeated = GoDayConfirmation()
        _ = observe(&repeated, 0)
        #expect(observe(&repeated, 25) { self.evidence($0, fixAge: 25) }.isEmpty, "Same fix as before")
        #expect(observe(&repeated, 30) { self.evidence($0, fixAge: 12) }.isEmpty, "Only 18 s newer")
        #expect(observe(&repeated, 40) { self.evidence($0, fixAge: 15) } == ["goday-1"], "25 s newer")

        // A reading that doesn't qualify in between starts over.
        var interrupted = GoDayConfirmation()
        _ = observe(&interrupted, 0)
        _ = observe(&interrupted, 10) { self.evidence($0, accuracy: 300) }
        #expect(observe(&interrupted, 25).isEmpty)
        #expect(observe(&interrupted, 45) == ["goday-1"])

        // A refused report (or a restart: a new session) starts over too.
        var refused = GoDayConfirmation()
        _ = observe(&refused, 0)
        refused.interrupt()
        #expect(observe(&refused, 30).isEmpty)
    }

    @Test func aSecondDayAfterArrivingIsTheOneShown() throws {
        let now = at(9)
        let backend = try seeded(now)
        try submit(backend, [.add(day(now))], now: now)
        let session = PresenceSession(bootSessionID: "boot-A")
        let t = now.addingTimeInterval(600)
        _ = try backend.reportPresence(report(1, uptime: 100, now: t), session: session, now: t, calendar: calendar)
        let t2 = t.addingTimeInterval(21)
        _ = try backend.reportPresence(report(2, uptime: 121, now: t2), session: session, now: t2, calendar: calendar)
        let later = t2.addingTimeInterval(600)
        #expect(try submit(backend, [.add(day(later, id: "goday-2"))], now: later).status == .applied,
                "Another Go day may start once the first is reached")
        #expect(try blocksBrowsers(backend, at: later.addingTimeInterval(180)))
    }

    @Test func untilElevenFiftyNineFitsTheDayTheClocksGoBack() throws {
        // 12:30 AM EDT on Nov 1 to 11:59 PM EST is 24 h 29 min.
        let start = at(month: 11, day: 1, 0, 30)
        let until = at(month: 11, day: 1, 23, 59)
        #expect(until.timeIntervalSince(start) > 86_400)
        let fix = GoDayGate.StartFix(latitude: home.latitude, longitude: home.longitude, horizontalAccuracy: 30)
        let place = RulePlace(id: "l", name: "Library", latitude: library.latitude, longitude: library.longitude,
                              radiusMeters: 150, wifiTags: [])
        let day = try ShieldViewModel.makeGoDay(places: [place], startFix: fix, startTags: [], until: until,
                                                apps: [], now: start).get()
        let backend = try seeded(start)
        #expect(try submit(backend, [.add(day)], now: start).status == .applied)
    }

    // MARK: The day, end to end in the fixture authority

    @Test func aGoDayClosesBrowsersUntilYouArriveThenStaysOpen() throws {
        let start = at(9)
        let backend = try seeded(start)
        try submit(backend, [.add(day(start))], now: start)
        #expect(try !blocksBrowsers(backend, at: start), "The 2-minute undo comes first")
        let running = start.addingTimeInterval(GoDayGate.undoWindow + 1)
        _ = try backend.tick(now: running, calendar: calendar)
        #expect(try blocksBrowsers(backend, at: running))
        #expect(try backend.snapshot(now: running, calendar: calendar).generation > 0)

        // Still at home: nothing lifts.
        let session = PresenceSession(bootSessionID: "boot-A")
        let atHome = running.addingTimeInterval(60)
        _ = try backend.reportPresence(report(1, uptime: 1_000, now: atHome, atLibrary: false), session: session,
                                       now: atHome, calendar: calendar)
        _ = try backend.reportPresence(report(2, uptime: 1_030, now: atHome.addingTimeInterval(30), atLibrary: false),
                                       session: session, now: atHome.addingTimeInterval(30), calendar: calendar)
        #expect(try blocksBrowsers(backend, at: atHome.addingTimeInterval(30)))

        // At the library: the first reading starts, the second (20 s later) confirms.
        let there = at(11)
        _ = try backend.reportPresence(report(3, uptime: 4_000, now: there), session: session, now: there, calendar: calendar)
        #expect(try blocksBrowsers(backend, at: there), "One reading isn't arriving")
        let confirmed = there.addingTimeInterval(25)
        #expect(try backend.reportPresence(report(4, uptime: 4_025, now: confirmed), session: session,
                                           now: confirmed, calendar: calendar).status == .applied)
        #expect(try !blocksBrowsers(backend, at: confirmed))
        let stored = try backend.snapshot(now: confirmed, calendar: calendar).committedRestrictions
            .first { $0.policyID == "goday-1" }
        #expect(stored?.goDay?.arrivedAt == confirmed)

        // Leaving, or a service restart, doesn't bring the lock back today.
        let later = at(15)
        _ = try backend.reportPresence(report(5, uptime: 9_000, now: later, atLibrary: false), session: session,
                                       now: later, calendar: calendar)
        _ = try backend.forgetPresence(now: later, calendar: calendar)
        _ = try backend.tick(now: later, calendar: calendar)
        #expect(try !blocksBrowsers(backend, at: later))
    }

    @Test func aServiceRestartBeforeArrivingKeepsTheLock() throws {
        let start = at(9)
        let backend = try seeded(start)
        try submit(backend, [.add(day(start))], now: start)
        let there = at(11)
        _ = try backend.reportPresence(report(1, uptime: 100, now: there), session: PresenceSession(bootSessionID: "boot-A"),
                                       now: there, calendar: calendar)
        // The restarted service has a new session: the earlier reading doesn't count.
        let restarted = PresenceSession(bootSessionID: "boot-A")
        let next = there.addingTimeInterval(25)
        _ = try backend.reportPresence(report(2, uptime: 125, now: next), session: restarted, now: next, calendar: calendar)
        #expect(try blocksBrowsers(backend, at: next))
        let confirmed = next.addingTimeInterval(25)
        _ = try backend.reportPresence(report(3, uptime: 150, now: confirmed), session: restarted, now: confirmed,
                                       calendar: calendar)
        #expect(try !blocksBrowsers(backend, at: confirmed))
    }

    @Test func undoWorksOnlyInTheFirstTwoMinutes() throws {
        let start = at(9)
        let backend = try seeded(start)
        try submit(backend, [.add(day(start))], now: start)
        let early = start.addingTimeInterval(60)
        try submit(backend, [.withdrawGoDay("goday-1")], now: early)
        #expect(try backend.snapshot(now: early, calendar: calendar).committedRestrictions.allSatisfy { !$0.isGoDay })

        let again = early.addingTimeInterval(10)
        try submit(backend, [.add(day(again, id: "goday-2"))], now: again)
        let late = again.addingTimeInterval(GoDayGate.undoWindow + 1)
        #expect(throws: FixtureBackendError.self) { try submit(backend, [.withdrawGoDay("goday-2")], now: late) }
        #expect(throws: FixtureBackendError.self) {
            try submit(backend, [.release("goday-2", at: late.addingTimeInterval(86_400))], now: late)
        }
        #expect(try blocksBrowsers(backend, at: late))
    }

    @Test func theDayEndsOnItsOwnAndLeavesNoTrace() throws {
        let start = at(9)
        let backend = try seeded(start)
        try submit(backend, [.add(day(start, until: at(21)))], now: start)
        #expect(try backend.snapshot(now: start, calendar: calendar).committedRestrictions.contains(where: \.isGoDay))
        let after = at(21, 1)
        _ = try backend.tick(now: after, calendar: calendar)
        let snapshot = try backend.snapshot(now: after, calendar: calendar)
        let dayKept = snapshot.committedRestrictions.contains { $0.isGoDay }
        #expect(!dayKept)
        #expect(try !blocksBrowsers(backend, at: after))
        #expect(BackendDocument.version(restrictions: snapshot.committedRestrictions, schedules: snapshot.committedSchedules,
                                        pendingReleases: snapshot.pendingReleases) == 2, "Back to the earlier format")
    }

    @Test func tonightsClockChangeDoesNotMoveTheEnd() throws {
        // Clocks go back at 2 AM on Nov 1: 1:30 AM happens twice. Instants don't move.
        let start = at(month: 11, day: 1, 0, 30)
        let end = start.addingTimeInterval(3 * 3_600)   // 2:30 AM CST, three real hours later
        let backend = try seeded(start)
        try submit(backend, [.add(day(start, until: end))], now: start)
        #expect(try blocksBrowsers(backend, at: start.addingTimeInterval(2 * 3_600)))
        #expect(try !blocksBrowsers(backend, at: end.addingTimeInterval(1)))
    }

    // MARK: Refused days

    @Test func refusesADayThatCouldNeverMeanGoing() throws {
        let start = at(9)
        let backend = try seeded(start)
        let nextDoor = GoDayGate.Place(name: "Café", latitude: home.latitude + 0.002, longitude: home.longitude,
                                       radiusMeters: 150)   // about 220 m from where the day began
        #expect(throws: FixtureBackendError.self) {
            try submit(backend, [.add(day(start, gate: gate(places: [nextDoor])))], now: start)
        }
        // A big circle that reaches back home counts as "already there".
        let wide = GoDayGate.Place(name: "Park", latitude: home.latitude + 0.0063, longitude: home.longitude,
                                   radiusMeters: 1_000)   // centre about 700 m away
        #expect(throws: FixtureBackendError.self) {
            try submit(backend, [.add(day(start, gate: gate(places: [wide])))], now: start)
        }
        // Shield must know where the day began.
        let blind = GoDayGate(places: [library], startTags: [], startFix: nil)
        #expect(throws: FixtureBackendError.self) { try submit(backend, [.add(day(start, gate: blind))], now: start) }
        let startsNow = DomainRestriction(owner: .temporary, policyID: "goday-now", title: "Go", domains: [],
                                      startsAt: start, endsAt: at(21), apps: [.webBrowsers], goDay: gate())
        #expect(throws: FixtureBackendError.self, "No undo window") { try submit(backend, [.add(startsNow)], now: start) }
        // Websites may be added and browsers are a choice, but a
        // day must block something, and only valid websites.
        let nothing = DomainRestriction(owner: .temporary, policyID: "goday-empty", title: "Go", domains: [],
                                        startsAt: start.addingTimeInterval(120), endsAt: at(21), apps: [],
                                        goDay: gate())
        #expect(throws: FixtureBackendError.self, "A day that blocks nothing") {
            try submit(backend, [.add(nothing)], now: start)
        }
        let badSite = DomainRestriction(owner: .temporary, policyID: "goday-bad", title: "Go", domains: ["not a site"],
                                        startsAt: start.addingTimeInterval(120), endsAt: at(21), apps: [.webBrowsers],
                                        goDay: gate())
        #expect(throws: FixtureBackendError.self, "Only valid websites") {
            try submit(backend, [.add(badSite)], now: start)
        }
        let chrome = AppTarget(displayName: "Chrome", bundleID: "com.google.Chrome", teamID: "EQHXZ8M8AV")
        let oneBrowser = day(start, id: "goday-chrome", apps: [chrome])
        #expect(throws: FixtureBackendError.self, "Browsers only as all of them, never one by name") {
            try submit(backend, [.add(oneBrowser)], now: start)
        }
        try submit(backend, [.add(day(start))], now: start)
        #expect(throws: FixtureBackendError.self, "One running day at a time") {
            try submit(backend, [.add(day(start, id: "goday-2"))], now: start)
        }
    }

    @Test func browsersStayHeldEverywhereElse() throws {
        let start = at(9)
        let backend = try seeded(start)
        let sneaky = DomainRestriction(owner: .temporary, policyID: "focus-1", title: "Browsers", domains: [],
                                       startsAt: start, endsAt: at(21), apps: [.webBrowsers])
        #expect(throws: FixtureBackendError.self) { try submit(backend, [.add(sneaky)], now: start) }
        #expect(!PolicyValidation.validApp(.webBrowsers))
        let chrome = AppTarget(displayName: "Chrome", bundleID: "com.google.Chrome", teamID: "EQHXZ8M8AV")
        #expect(!PolicyValidation.validApp(chrome))
    }

    // MARK: What closes

    private func identity(_ bundleID: String, team: String? = "TEAM000001", web: Bool = false) -> AppIdentity {
        AppIdentity(bundleID: bundleID, teamID: team, signingID: bundleID, opensWebLinks: web)
    }

    @Test func theBrowserFamilyCatchesKnownAndNewBrowsersOnly() {
        #expect(AppMatcher.matches(.webBrowsers, identity("com.apple.Safari", team: nil)))
        #expect(AppMatcher.matches(.webBrowsers, identity("com.google.Chrome.helper.renderer")))
        #expect(AppMatcher.matches(.webBrowsers, identity("com.example.NewBrowser", web: true)), "Installed mid-day")
        #expect(!AppMatcher.matches(.webBrowsers, identity("com.hnc.Discord")))
        #expect(!AppMatcher.matches(.webBrowsers, identity("com.apple.finder", team: nil, web: true)))
        #expect(!AppMatcher.matches(.webBrowsers, identity("com.apple.CaptiveNetworkAssistant", team: nil, web: true)),
                "The library Wi-Fi login always opens")
        #expect(!AppMatcher.matches(.webBrowsers, identity("com.kairos.ShieldRC", web: true)))
        // Ordinary rules: known browsers stay held; other apps behave as before.
        let chrome = AppTarget(displayName: "Chrome", bundleID: "com.google.Chrome", teamID: "TEAM000001")
        #expect(!AppMatcher.matches(chrome, identity("com.google.Chrome")))
        #expect(AppMatcher.matches(discord, identity("com.hnc.Discord", team: "53Q6R32WPB", web: true)))
    }

    @Test func theSweepClosesBrowsersOnlyForAGoDay() {
        let now = at(10)
        let opened = now.addingTimeInterval(-100)   // already open when the day began: asked to quit first
        let safari = RunningApp(pid: 501, identity: identity("com.apple.Safari", team: nil), launchedAt: opened)
        let finder = RunningApp(pid: 502, identity: identity("com.apple.finder", team: nil), launchedAt: opened)
        let login = RunningApp(pid: 503, identity: identity("com.apple.CaptiveNetworkAssistant", team: nil, web: true),
                               launchedAt: opened)
        var sweep = AppSweep()
        let actions = sweep.decide(running: [safari, finder, login], blocked: [.webBrowsers], now: now, ownPID: 1)
        #expect(actions == [.askToQuit(pid: 501, targetID: AppTarget.webBrowsers.id)])
        var ordinary = AppSweep()
        let safariTarget = AppTarget(displayName: "Safari", bundleID: "com.apple.Safari", teamID: nil)
        #expect(ordinary.decide(running: [safari], blocked: [safariTarget], now: now, ownPID: 1).isEmpty)
    }

    @Test func readsWhetherAnAppOpensWebLinks() {
        let browser: [String: Any] = ["CFBundleURLTypes": [["CFBundleURLSchemes": ["HTTP", "https"]]]]
        let chat: [String: Any] = ["CFBundleURLTypes": [["CFBundleURLSchemes": ["discord"]]]]
        #expect(ProcessScanner.opensWebLinks(browser))
        #expect(!ProcessScanner.opensWebLinks(chat))
        #expect(!ProcessScanner.opensWebLinks(nil))
    }

    // MARK: Storage

    @Test func restrictionsWithoutADayEncodeExactlyAsBefore() throws {
        let plain = DomainRestriction(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, owner: .commitment,
                                      policyID: "tumblr", title: "Tumblr", domains: ["tumblr.com"])
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!json.contains("goDay"))
        let round = try JSONDecoder().decode(DomainRestriction.self, from: try JSONEncoder().encode(day(at(9))))
        #expect(round.goDay == gate())
        #expect(BackendDocument.version(restrictions: [plain], schedules: [], pendingReleases: []) == 2)
        #expect(BackendDocument.version(restrictions: [plain, day(at(9))], schedules: [], pendingReleases: []) == 5)
    }
}

private func goDayBackendDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShieldGoDayTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
    return root
}
