import Foundation
import Testing
@testable import Shield

// Big block lists: about 50,000 websites fit, more are refused, and
// the shortcuts that keep big lists cheap give exactly the answers the full
// work would, and never hide a changed or tampered file.
struct BigListLimitTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func backend() throws -> FixtureBackend {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldBigList-\(UUID().uuidString)", isDirectory: true)
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

    private func imported(_ sites: [String], prefix: String) -> [BackendCommand] {
        WebsiteListImport.lists(sites).enumerated().map { index, domains in
            .add(DailySchedule(id: "\(prefix)-\(index)", title: "Import \(index)", domains: domains,
                               startMinutes: 0, endMinutes: 1_439, isRequested: true))
        }
    }

    @Test func fiftyThousandSitesFitAndMoreAreRefused() throws {
        let backend = try backend()
        let now = Date()
        let sites = (0..<50_000).map { "site\($0).example" }
        #expect(WebsiteListImport.lists(sites).count <= WebsiteListImport.maximumLists,
                "one import takes 50,000 sites")
        try submit(backend, imported(sites, prefix: "big"), now: now)
        let snapshot = try backend.snapshot(now: now, calendar: calendar)
        #expect(snapshot.enforcement.blockedDomains.count == 100_000, "every site and its www twin is in hosts")
        // The re-commit of a big document still verifies and reads back.
        _ = try backend.tick(now: now + FixtureBackend.authorityRefreshInterval + 1, calendar: calendar)
        #expect(try backend.snapshot(now: now + FixtureBackend.authorityRefreshInterval + 1, calendar: calendar)
            .generation == snapshot.generation + 1)
        let more = (0..<10_000).map { "more\($0).example" }
        #expect(throws: FixtureBackendError.self) {
            try submit(backend, imported(more, prefix: "more"), now: now + FixtureBackend.authorityRefreshInterval + 2)
        }
    }

    // Import Website List can also block all day: the same rule shape
    // as New Block or Lock In Forever, split into lists. A permanent import
    // keeps its 72-hour correction and is permanent after it.
    @Test func importedAllDayListsAreAcceptedAsTheirOwnKind() throws {
        let backend = try backend()
        let now = Date()
        let sites = (0..<5_322).map { "adult\($0).example" }
        for (owner, prefix) in [(PolicyOwner.commitment, "off"), (.permanent, "forever")] {
            let rules = WebsiteListImport.lists(sites.map { "\(prefix)-\($0)" }).enumerated().map { index, domains in
                DomainRestriction(owner: owner, policyID: "focus-\(prefix)-\(index)", title: "Import \(index)",
                                  domains: domains, startsAt: now)
            }
            #expect(rules.count > 1)
            try submit(backend, rules.map { .add($0) }, now: now)
        }
        let snapshot = try backend.snapshot(now: now, calendar: calendar)
        #expect(snapshot.enforcement.blockedDomains.count == 4 * 5_322, "both lists, every www twin")
        let permanents = snapshot.committedRestrictions.filter { $0.owner == .permanent }
        #expect(!permanents.isEmpty && permanents.allSatisfy { $0.endsAt == nil && $0.isCorrectablePermanent(at: now) })
        #expect(permanents.allSatisfy { !$0.isCorrectablePermanent(at: now + DomainRestriction.permanentCorrectionWindow + 1) })
    }

    @Test func transitionAloneMatchesFullEvaluation() {
        let engine = UnifiedPolicyEngine()
        // Around the Nov 1 clock change, with overnight, daytime and off schedules.
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 0))!
        let schedules = [
            DailySchedule(id: "a", title: "A", domains: ["a.example"], startMinutes: 1_200, endMinutes: 840, isRequested: true),
            DailySchedule(id: "b", title: "B", domains: ["b.example"], startMinutes: 60, endMinutes: 150, isRequested: true),
            DailySchedule(id: "c", title: "C", domains: ["c.example"], startMinutes: 600, endMinutes: 700, isRequested: false),
        ]
        let restrictions = [
            DomainRestriction(owner: .permanent, policyID: "p", title: "P", domains: ["p.example"]),
            DomainRestriction(owner: .commitment, policyID: "t", title: "T", domains: ["t.example"],
                              startsAt: start + 3_600, endsAt: start + 90_000),
        ]
        let conditions = ConditionalPolicy(
            places: [RulePlace(id: "home", name: "Home", latitude: 40.7812, longitude: -73.9665, radiusMeters: 100,
                               wifiTags: ["home-ap"], isHome: true)],
            rules: [ConditionalRule(id: "home-night", title: "Home", domains: ["r.example"], effect: .block,
                                    conditions: [.atPlace(placeID: "home", minimumDwellMinutes: 0)],
                                    committedAt: .distantPast)])
        for step in 0..<(3 * 24 * 60 / 17) {
            let date = start + TimeInterval(step * 17 * 60)
            for policy in [nil, conditions] {
                #expect(engine.nextTransition(restrictions: restrictions, schedules: schedules, at: date,
                                              calendar: calendar, conditions: policy) ==
                        engine.evaluate(restrictions: restrictions, schedules: schedules, at: date,
                                        calendar: calendar, conditions: policy).nextTransition)
            }
        }
    }

    @Test func aSwappedAuthorityIsStillCaughtAfterAVerifiedPass() throws {
        let now = Date()
        let real = try backend()
        try submit(real, [.add(DomainRestriction(owner: .permanent, policyID: "p", title: "P", domains: ["a.example"]))],
                   now: now)
        _ = try real.tick(now: now + 2, calendar: calendar)   // verified once; the agreement is remembered
        let other = try backend()
        try submit(other, [.add(DomainRestriction(owner: .permanent, policyID: "p", title: "P", domains: ["b.example"]))],
                   now: now)
        try Data(contentsOf: other.paths.authority).write(to: real.paths.authority)
        #expect(throws: FixtureBackendError.self) { _ = try real.tick(now: now + 4, calendar: calendar) }
        #expect(throws: FixtureBackendError.self) { _ = try real.snapshot(now: now + 4, calendar: calendar) }
    }

    @Test func decodedValuesAreKeptOnlyForTheExactBytes() {
        let cache = DecodedBytesCache<Int>()
        let bytes = Data("abc".utf8)
        cache.store(bytes, 1)
        #expect(cache.lookup(Data("abc".utf8)) == 1)
        #expect(cache.lookup(Data("abd".utf8)) == nil)
        #expect(cache.lookup(Data("abcd".utf8)) == nil)

        let memo = AgreementMemo()
        memo.store(document: Data("d".utf8), authority: Data("a".utf8), calendar: calendar)
        #expect(memo.contains(document: Data("d".utf8), authority: Data("a".utf8), calendar: calendar))
        #expect(!memo.contains(document: Data("e".utf8), authority: Data("a".utf8), calendar: calendar))
        #expect(!memo.contains(document: Data("d".utf8), authority: Data("b".utf8), calendar: calendar))
        var elsewhere = calendar
        elsewhere.timeZone = TimeZone(identifier: "Europe/London")!
        #expect(!memo.contains(document: Data("d".utf8), authority: Data("a".utf8), calendar: elsewhere))
    }
}
