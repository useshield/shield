import Foundation
import Testing
@testable import Shield

struct ConditionalRulesTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private let library = RulePlace(id: "library", name: "Library", latitude: 40.7532, longitude: -73.9822,
                                    radiusMeters: 120, wifiTags: ["lib-ap-1", "lib-ap-2", "lib-ap-3", "lib-ap-4"])
    private let home = RulePlace(id: "home", name: "Home", latitude: 40.7812, longitude: -73.9665,
                                 radiusMeters: 100, wifiTags: ["home-ap"], isHome: true)

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: hour, minute: minute))!
    }

    private func evidence(atLibrary: Bool, now: Date, accuracy: Double = 20, simulated: Bool = false,
                          wifi: String? = "lib-ap-1", visible: Set<String> = [], slept: Bool = false) -> PresenceEvidence {
        let (lat, lon) = atLibrary ? (library.latitude, library.longitude) : (home.latitude, home.longitude)
        return PresenceEvidence(observedAt: now,
            fix: .init(latitude: lat, longitude: lon, horizontalAccuracy: accuracy, observedAt: now,
                       isSimulated: simulated, fullAccuracy: true),
            connectedWiFiTag: wifi, visibleWiFiTags: visible, sleptSinceLastEvidence: slept)
    }

    private func context(_ now: Date, _ evidence: PresenceEvidence?, tracker: PresenceTracker = .init(),
                         study: Int? = nil) -> RuleContext {
        RuleContext(now: now, calendar: calendar, places: [library, home], evidence: evidence,
                    tracker: tracker, studyMinutesToday: study)
    }

    private func tracker(dwellMinutes: Int, endingAt now: Date) -> PresenceTracker {
        var tracker = PresenceTracker()
        for minute in stride(from: dwellMinutes, through: 0, by: -1) {
            let t = now.addingTimeInterval(TimeInterval(-minute * 60))
            tracker.observe(evidence(atLibrary: true, now: t), places: [library, home], now: t, calendar: calendar)
        }
        return tracker
    }

    private let committedLongAgo = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func exceptionNeedsStrongEvidenceDwellAndPrecommitment() {
        let now = at(15)
        let rule = ConditionalRule(id: "yt-library", title: "YouTube at the library", domains: ["youtube.com"],
                                   effect: .allow, conditions: [.atPlace(placeID: "library", minimumDwellMinutes: 10)],
                                   committedAt: committedLongAgo)
        let base: Set<String> = ["youtube.com", "x.com"]
        let open = ConditionalRuleEngine.evaluate(baseBlocked: base, neverRelaxable: [], rules: [rule],
            context: context(now, evidence(atLibrary: true, now: now), tracker: tracker(dwellMinutes: 12, endingAt: now)))
        #expect(open.blocked == ["x.com"])
        #expect(open.openedBy["youtube.com"] == "yt-library")
        // Too short a stay, a simulated fix, poor accuracy, no Wi-Fi, a sleep, or no evidence: stays blocked.
        let failing: [RuleContext] = [
            context(now, evidence(atLibrary: true, now: now), tracker: tracker(dwellMinutes: 5, endingAt: now)),
            context(now, evidence(atLibrary: true, now: now, simulated: true), tracker: tracker(dwellMinutes: 12, endingAt: now)),
            context(now, evidence(atLibrary: true, now: now, accuracy: 90), tracker: tracker(dwellMinutes: 12, endingAt: now)),
            context(now, evidence(atLibrary: true, now: now, wifi: nil), tracker: tracker(dwellMinutes: 12, endingAt: now)),
            context(now, evidence(atLibrary: true, now: now, slept: true), tracker: tracker(dwellMinutes: 12, endingAt: now)),
            context(now, nil, tracker: tracker(dwellMinutes: 12, endingAt: now)),
        ]
        for item in failing {
            #expect(ConditionalRuleEngine.evaluate(baseBlocked: base, neverRelaxable: [], rules: [rule], context: item).blocked == base)
        }
        // A brand-new exception waits 24 hours before it can open anything.
        let fresh = ConditionalRule(id: rule.id, title: rule.title, domains: rule.domains, effect: .allow,
                                    conditions: rule.conditions, committedAt: now.addingTimeInterval(-3_600))
        #expect(ConditionalRuleEngine.evaluate(baseBlocked: base, neverRelaxable: [], rules: [fresh],
            context: context(now, evidence(atLibrary: true, now: now), tracker: tracker(dwellMinutes: 12, endingAt: now))).blocked == base)
    }

    @Test func homeWiFiVetoesEveryException() {
        let now = at(15)
        let rule = ConditionalRule(id: "yt", title: "", domains: ["youtube.com"], effect: .allow,
                                   conditions: [.atPlace(placeID: "library", minimumDwellMinutes: 0)], committedAt: committedLongAgo)
        let spoof = evidence(atLibrary: true, now: now, wifi: "home-ap", visible: ["lib-ap-1", "lib-ap-2", "lib-ap-3"])
        #expect(ConditionalRuleEngine.evaluate(baseBlocked: ["youtube.com"], neverRelaxable: [], rules: [rule],
                                               context: context(now, spoof)).blocked == ["youtube.com"])
    }

    @Test func permanentBlocksAndBlockRulesAlwaysWinOverExceptions() {
        let now = at(15)
        let allow = ConditionalRule(id: "a", title: "Allow", domains: ["pornhub.com", "youtube.com"], effect: .allow,
                                    conditions: [], committedAt: committedLongAgo)
        let block = ConditionalRule(id: "b", title: "", domains: ["youtube.com"], effect: .block,
                                    conditions: [.timeWindow(startMinute: 14 * 60, endMinute: 16 * 60, weekdays: [])],
                                    committedAt: now)
        let decision = ConditionalRuleEngine.evaluate(baseBlocked: ["pornhub.com", "youtube.com"],
            neverRelaxable: ["pornhub.com"], rules: [allow, block], context: context(now, nil))
        #expect(decision.blocked == ["pornhub.com", "youtube.com"])
        #expect(decision.openedBy.isEmpty)
    }

    @Test func blockedUntilIArriveLiftsOnlyAfterVerifiedTimeThere() {
        let rule = ConditionalRule(id: "until-library", title: "Everything blocked until the library",
                                   domains: ["youtube.com", "netflix.com"], effect: .block,
                                   conditions: [.arrivedToday(placeID: "library", minimumMinutes: 15)], committedAt: at(8))
        let before = ConditionalRuleEngine.evaluate(baseBlocked: [], neverRelaxable: [], rules: [rule],
                                                    context: context(at(10), nil))
        #expect(before.blocked == ["youtube.com", "netflix.com"])
        let now = at(11)
        let after = ConditionalRuleEngine.evaluate(baseBlocked: [], neverRelaxable: [], rules: [rule],
            context: context(now, evidence(atLibrary: false, now: now, wifi: nil), tracker: tracker(dwellMinutes: 20, endingAt: at(10, 30))))
        #expect(after.blocked.isEmpty)
    }

    @Test func stricterAtHomeAppliesOnWeakEvidenceOrNoEvidence() {
        let rule = ConditionalRule(id: "home-night", title: "", domains: ["x.com"], effect: .block,
            conditions: [.atPlace(placeID: "home", minimumDwellMinutes: 0),
                         .timeWindow(startMinute: 22 * 60, endMinute: 6 * 60, weekdays: [])], committedAt: at(8))
        let night = at(23)
        let weakHome = PresenceEvidence(observedAt: night, fix: nil, connectedWiFiTag: "home-ap",
                                        visibleWiFiTags: [], sleptSinceLastEvidence: false)
        #expect(ConditionalRuleEngine.evaluate(baseBlocked: [], neverRelaxable: [], rules: [rule],
                                               context: context(night, weakHome)).blocked == ["x.com"])
        #expect(ConditionalRuleEngine.evaluate(baseBlocked: [], neverRelaxable: [], rules: [rule],
                                               context: context(night, nil)).blocked == ["x.com"])
        #expect(ConditionalRuleEngine.evaluate(baseBlocked: [], neverRelaxable: [], rules: [rule],
                                               context: context(at(15), weakHome)).blocked.isEmpty)
    }

    @Test func studyEarnedAccessAndWrappingWindows() {
        let rule = ConditionalRule(id: "netflix-earned", title: "", domains: ["netflix.com"], effect: .allow,
            conditions: [.studiedToday(minimumMinutes: 45)], committedAt: committedLongAgo)
        func blocked(_ study: Int?) -> Bool {
            ConditionalRuleEngine.evaluate(baseBlocked: ["netflix.com"], neverRelaxable: [], rules: [rule],
                                           context: context(at(18), nil, study: study)).blocked.contains("netflix.com")
        }
        #expect(blocked(nil)); #expect(blocked(44)); #expect(!blocked(45))
        // 22:00–06:00 window that started on Tuesday still holds at 01:00 Wednesday only.
        let wednesday1am = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 1))!
        #expect(ConditionalRuleEngine.timeWindowContains(22 * 60, 6 * 60, weekdays: [3], at: wednesday1am, calendar: calendar))
        #expect(!ConditionalRuleEngine.timeWindowContains(22 * 60, 6 * 60, weekdays: [4], at: wednesday1am, calendar: calendar))
    }

    @Test func weakeningChangesWaitAndStrengtheningIsImmediate() {
        let allow = ConditionalRule(id: "a", title: "Allow", domains: ["youtube.com", "netflix.com"], effect: .allow,
                                    conditions: [.atPlace(placeID: "library", minimumDwellMinutes: 10)], committedAt: committedLongAgo)
        var fewer = allow; fewer.domains = ["youtube.com"]
        var moreConditions = allow; moreConditions.conditions.append(.studiedToday(minimumMinutes: 30))
        var shorterDwell = allow; shorterDwell.conditions = [.atPlace(placeID: "library", minimumDwellMinutes: 5)]
        #expect(RuleChangeClassifier.classify(old: nil, new: allow) == .delayed)
        #expect(RuleChangeClassifier.classify(old: allow, new: nil) == .immediate)
        #expect(RuleChangeClassifier.classify(old: allow, new: fewer) == .immediate)
        #expect(RuleChangeClassifier.classify(old: allow, new: moreConditions) == .immediate)
        #expect(RuleChangeClassifier.classify(old: allow, new: shorterDwell) == .delayed)
        let block = ConditionalRule(id: "b", title: "", domains: ["x.com"], effect: .block, conditions: [], committedAt: at(8))
        var wider = block; wider.domains.insert("reddit.com")
        #expect(RuleChangeClassifier.classify(old: nil, new: block) == .immediate)
        #expect(RuleChangeClassifier.classify(old: block, new: wider) == .immediate)
        #expect(RuleChangeClassifier.classify(old: block, new: nil) == .delayed)
    }

    @Test func summariesReadPlainly() {
        let rule = ConditionalRule(id: "a", title: "Allow", domains: ["youtube.com"], effect: .allow,
            conditions: [.atPlace(placeID: "library", minimumDwellMinutes: 10),
                         .timeWindow(startMinute: 14 * 60, endMinute: 20 * 60, weekdays: [])], committedAt: committedLongAgo)
        #expect(ConditionalRulePresentation.summary(rule, places: [library]) ==
                "Allow youtube.com — at Library for 10 min, 2 PM–8 PM")
        let until = ConditionalRule(id: "u", title: "", domains: ["x.com"], effect: .block,
            conditions: [.arrivedToday(placeID: "library", minimumMinutes: 15)], committedAt: committedLongAgo)
        #expect(ConditionalRulePresentation.summary(until, places: [library]) ==
                "Block x.com — until 15 min at Library today")
    }

    @Test func recordedPresenceReplaysWithoutCoordinatesAndExpires() throws {
        let rule = ConditionalRule(id: "lib", title: "", domains: ["youtube.com"], effect: .allow,
            conditions: [.atPlace(placeID: "library", minimumDwellMinutes: 10)], committedAt: committedLongAgo)
        let now = at(15)
        let snapshot = PresenceSnapshot.capture(evidence: evidence(atLibrary: true, now: now, visible: []),
            places: [library, home], tracker: tracker(dwellMinutes: 12, endingAt: now), studyMinutesToday: nil, now: now)
        // The stored form holds verdicts only.
        let stored = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        #expect(!stored.contains("40.75") && !stored.contains("lib-ap"))
        let replayed = try JSONDecoder().decode(PresenceSnapshot.self, from: JSONEncoder().encode(snapshot))
        func blocked(_ time: Date) -> Set<String> {
            ConditionalRuleEngine.evaluate(baseBlocked: ["youtube.com"], neverRelaxable: [], rules: [rule],
                context: RuleContext(now: time, calendar: calendar, places: [library, home], snapshot: replayed)).blocked
        }
        #expect(blocked(now).isEmpty)
        // A record older than two minutes is unknown again, so the block returns.
        #expect(blocked(now.addingTimeInterval(PresenceSnapshot.maximumAge + 1)) == ["youtube.com"])
    }

    @Test func earnedTimeAtAPlaceCountsOnlyThatDay() {
        let rule = ConditionalRule(id: "until", title: "", domains: ["x.com"], effect: .block,
            conditions: [.arrivedToday(placeID: "library", minimumMinutes: 15)], committedAt: at(8))
        let snapshot = PresenceSnapshot.capture(evidence: nil, places: [library, home],
            tracker: tracker(dwellMinutes: 20, endingAt: at(23, 30)), studyMinutesToday: nil, now: at(23, 40))
        func blocked(_ time: Date) -> Set<String> {
            ConditionalRuleEngine.evaluate(baseBlocked: [], neverRelaxable: [], rules: [rule],
                context: RuleContext(now: time, calendar: calendar, places: [library, home], snapshot: snapshot)).blocked
        }
        #expect(blocked(at(23, 45)).isEmpty)
        #expect(blocked(at(23, 45).addingTimeInterval(3_600)) == ["x.com"]) // after midnight
    }

    @Test func reportGateRejectsReplaysOtherBootsAndOldReports() {
        var gate = PresenceReportGate()
        let now = at(12)
        func report(_ sequence: UInt64, uptime: UInt64, boot: String = "boot-1", observed: Date? = nil) -> PresenceReport {
            PresenceReport(sequence: sequence, bootSessionID: boot, uptimeNanoseconds: uptime,
                evidence: PresenceEvidenceRecord(latitude: 0, longitude: 0, horizontalAccuracy: 30,
                    fixObservedAt: observed ?? now, isSimulated: false, fullAccuracy: true, observedAt: observed ?? now,
                    connectedWiFiTag: nil, visibleWiFiTags: [], sleptSinceLastEvidence: false))
        }
        #expect((try? gate.accept(report(1, uptime: 100), serviceBootSessionID: "boot-1", now: now).get()) != nil)
        #expect(gate.accept(report(1, uptime: 200), serviceBootSessionID: "boot-1", now: now) == .failure(.replayed))
        #expect(gate.accept(report(2, uptime: 50), serviceBootSessionID: "boot-1", now: now) == .failure(.clockWentBackwards))
        #expect(gate.accept(report(3, uptime: 300, boot: "boot-0"), serviceBootSessionID: "boot-1", now: now) == .failure(.notCurrent))
        #expect(gate.accept(report(4, uptime: 400, observed: now.addingTimeInterval(-600)),
                            serviceBootSessionID: "boot-1", now: now) == .failure(.notCurrent))
        var bad = report(5, uptime: 500)
        bad = PresenceReport(sequence: 5, bootSessionID: "boot-1", uptimeNanoseconds: 500,
            evidence: PresenceEvidenceRecord(latitude: 91, longitude: 0, horizontalAccuracy: 30, fixObservedAt: now,
                isSimulated: false, fullAccuracy: true, observedAt: now, connectedWiFiTag: nil,
                visibleWiFiTags: [], sleptSinceLastEvidence: false))
        #expect(gate.accept(bad, serviceBootSessionID: "boot-1", now: now) == .failure(.malformed))
        // After a restart, a new boot session starts a new sequence.
        var restarted = PresenceReportGate()
        #expect((try? restarted.accept(report(1, uptime: 10, boot: "boot-2"), serviceBootSessionID: "boot-2", now: now).get()) != nil)
    }

    @Test func placeLimitsAndPlaceEditsWait() {
        let allow = ConditionalRule(id: "a", title: "Allow", domains: ["x.com"], effect: .allow,
            conditions: [.atPlace(placeID: "library", minimumDwellMinutes: 10)], committedAt: committedLongAgo)
        #expect(RulePlaceValidator.problems(places: [library, home], rules: [allow]).isEmpty)
        #expect(RulePlaceValidator.problems(places: [library], rules: [allow]) == [.homeCount])
        var tiny = library; tiny.radiusMeters = 30
        #expect(RulePlaceValidator.problems(places: [tiny, home], rules: []) == [.radius])
        let orphan = ConditionalRule(id: "o", title: "Orphan", domains: ["x.com"], effect: .block,
            conditions: [.notAtPlace(placeID: "gym")], committedAt: at(8))
        #expect(RulePlaceValidator.problems(places: [library, home], rules: [orphan]) == [.unknownPlace])

        var renamed = library; renamed.name = "Main library"
        var moved = library; moved.latitude += 0.001
        var retagged = library; retagged.wifiTags.insert("lib-ap-9")
        #expect(PlaceChangeClassifier.classify(old: nil, new: library) == .immediate)
        #expect(PlaceChangeClassifier.classify(old: library, new: renamed) == .immediate)
        #expect(PlaceChangeClassifier.classify(old: library, new: moved) == .delayed)
        #expect(PlaceChangeClassifier.classify(old: library, new: retagged) == .delayed)
        #expect(PlaceChangeClassifier.classify(old: library, new: nil) == .delayed)
    }
}
