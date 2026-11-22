import Foundation
import Testing
@testable import Shield

struct ShieldPresentationTests {
    private var eastern: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private func schedule(_ id: String = "social-afternoon", title: String = "X / Reddit",
                          start: Int = 1200, end: Int = 840, requested: Bool = true) -> DailySchedule {
        DailySchedule(id: id, title: title, domains: ["x.com", "reddit.com"],
                      startMinutes: start, endMinutes: end, isRequested: requested)
    }
    private let examples: [(String, String, Int, Int)] = [
        ("social-afternoon", "X / Reddit", 1020, 1260),
        ("netflix-evening", "Netflix", 1200, 1320),
        ("youtube-evening", "YouTube", 1140, 1260),
        ("instagram-afternoon", "Instagram", 1020, 1260),
        ("tiktok-afternoon", "TikTok", 1020, 1260),
        ("pinterest-afternoon", "Pinterest", 900, 1020)
    ]

    @Test func allSixAllowedWindowsRoundTripWithoutChangingMetadata() throws {
        for (id, title, start, end) in examples {
            let original = schedule(id, title: title, start: end, end: start)
            let window = try #require(AllowedAccessWindow(blockedSchedule: original))
            #expect(window.startMinutes == start)
            #expect(window.endMinutes == end)
            #expect(window.blockedSchedule(basedOn: original) == original)
            let text = window.description(calendar: eastern, locale: Locale(identifier: "en_US"))
            #expect(text.hasPrefix("Allowed "))
            #expect(text.contains("PM"))
            #expect(!text.contains("next day"))
        }
    }

    @Test func everyWallClockMinuteHasExactlyOneOfAllowedOrBlocked() throws {
        for (_, _, start, end) in examples + [("midnight", "Midnight", 0, 60), ("overnight", "Overnight", 1380, 60)] {
            let blocked = schedule(start: end, end: start)
            let window = try #require(AllowedAccessWindow(blockedSchedule: blocked))
            for minute in 0..<1440 {
                let time = try #require(eastern.date(from: DateComponents(year: 2026, month: 10, day: 22,
                                                                         hour: minute / 60, minute: minute % 60)))
                let allowed = start < end ? minute >= start && minute < end : minute >= start || minute < end
                #expect(blocked.contains(time, calendar: eastern) != allowed)
            }
            #expect(window.blockedSchedule(basedOn: blocked) == blocked)
        }
    }

    @Test func equalEndpointsAndOutOfRangeAreRejected() {
        for (start, end) in [(0, 0), (840, 840), (-1, 60), (0, 1440), (1440, 0)] {
            #expect(AllowedAccessWindow(startMinutes: start, endMinutes: end) == nil)
            #expect(AllowedAccessWindow(blockedSchedule: schedule(start: end, end: start)) == nil)
        }
    }

    @Test func midpointAndMidnightFormattingNeverUsesHostTimezone() throws {
        let window = try #require(AllowedAccessWindow(startMinutes: 1380, endMinutes: 0))
        let text = window.description(calendar: eastern, locale: Locale(identifier: "en_US"))
        #expect(text.contains("11:00"))
        #expect(text.contains("12:00"))
        #expect(text.contains("until next day"))
        let french = window.description(calendar: eastern, locale: Locale(identifier: "fr_FR"))
        #expect(french.contains("23:00"))
    }

    @Test func dstRepeatedAndMissingHoursStayWallClockComplements() throws {
        let blocked = schedule(start: 150, end: 60)
        let window = try #require(AllowedAccessWindow(blockedSchedule: blocked))
        let allowed = schedule(start: window.startMinutes, end: window.endMinutes)
        let iso = ISO8601DateFormatter()
        for day in ["2026-03-08T06:00:00Z", "2026-11-01T05:00:00Z"] {
            let midnight = try #require(iso.date(from: day))
            for minute in 0..<1560 {
                let instant = midnight.addingTimeInterval(Double(minute * 60))
                #expect(blocked.contains(instant, calendar: eastern) != allowed.contains(instant, calendar: eastern))
            }
        }
        #expect(window.blockedSchedule(basedOn: blocked) == blocked)
    }

    @Test func lessAccessStrengthensButMoreOrMovedAccessDoesNot() throws {
        let original = schedule()
        let less = try #require(AllowedAccessWindow(startMinutes: 900, endMinutes: 1140))
        let more = try #require(AllowedAccessWindow(startMinutes: 780, endMinutes: 1260))
        let moved = try #require(AllowedAccessWindow(startMinutes: 720, endMinutes: 1080))
        #expect(less.blockedSchedule(basedOn: original).isImmediateStrengthening(of: original))
        #expect(!more.blockedSchedule(basedOn: original).isImmediateStrengthening(of: original))
        #expect(!moved.blockedSchedule(basedOn: original).isImmediateStrengthening(of: original))
    }

    @Test func conversionPreservesDisabledIntentAndArbitraryDomains() throws {
        let original = schedule("future", title: "Custom title", start: 1, end: 1439, requested: false)
        #expect(try #require(AllowedAccessWindow(blockedSchedule: original)).blockedSchedule(basedOn: original) == original)
    }

    @Test func socialAndVideoContainEveryOriginalScheduleExactlyOnce() {
        let schedules = examples.map { schedule($0.0, title: $0.1, start: $0.3, end: $0.2) }
        let groups = ShieldGrouping.groups(schedules: schedules, restrictions: [], pending: [])
        #expect(groups.map(\.kind) == [.social, .video])
        #expect(groups[0].schedules.map(\.id) == ["social-afternoon", "instagram-afternoon", "tiktok-afternoon", "pinterest-afternoon"])
        #expect(groups[1].schedules.map(\.id) == ["netflix-evening", "youtube-evening"])
        #expect(Set(groups.flatMap(\.schedules)) == Set(schedules))
    }

    @Test func adultChunksAreOneGroupWithBothOriginalOwnersUnchanged() throws {
        let first = DomainRestriction(owner: .permanent, policyID: "owner-plan-adult-1", title: "Adult content", domains: ["one.example", "shared.example"])
        let second = DomainRestriction(owner: .permanent, policyID: "owner-plan-adult-2", title: "Adult content", domains: ["two.example", "shared.example"])
        let groups = ShieldGrouping.groups(schedules: [], restrictions: [first, second], pending: [])
        #expect(groups.count == 1)
        let group = try #require(groups.first)
        #expect(group.kind == .adult)
        #expect(group.restrictions == [first, second])
        #expect(group.domains == ["one.example", "two.example", "shared.example"])
        #expect(group.summary == "Always blocked · 3 websites")
    }

    @Test func foodAndCustomArePermanentGroupsWithoutInventedRoots() {
        let food = DomainRestriction(owner: .permanent, policyID: "owner-plan-food-1", title: "Food ordering", domains: ["food.example"])
        let custom = DomainRestriction(owner: .permanent, policyID: "owner-plan-custom-1", title: "Custom permanent sites", domains: ["stream.example", "takeout.example", "order.takeout.example"])
        let groups = ShieldGrouping.groups(schedules: [], restrictions: [food, custom], pending: [])
        #expect(groups.map(\.kind) == [.food, .custom])
        #expect(groups[1].restrictions == [custom])
        #expect(!groups.flatMap { $0.domains }.contains("instacart.com"))
    }

    @Test func unknownDuplicateTitlesAndTemporaryRulesSurviveGrouping() {
        let a = DomainRestriction(owner: .temporary, policyID: "temporary-a", title: "Adult content", domains: ["a.example"], endsAt: .distantFuture)
        let b = DomainRestriction(owner: .commitment, policyID: "commitment-b", title: "Adult content", domains: ["b.example"])
        let extra = schedule("unknown", title: "Unfamiliar category")
        let groups = ShieldGrouping.groups(schedules: [extra], restrictions: [a, b], pending: [])
        #expect(groups.count == 1)
        #expect(groups[0].kind == .other)
        #expect(groups[0].restrictions == [a, b])
        #expect(groups[0].schedules == [extra])
        #expect(groups[0].count == 3)
    }

    @Test func pendingUnmatchedOwnersRemainVisibleWithoutDuplicatingKnownOwners() {
        let known = schedule()
        let pending = [ShieldPendingChange(policyID: known.id, effectiveAt: .distantFuture, replacementSchedule: known),
                       ShieldPendingChange(policyID: "missing-metadata", effectiveAt: .distantFuture, replacementSchedule: nil)]
        let groups = ShieldGrouping.groups(schedules: [known], restrictions: [], pending: pending)
        #expect(groups.map(\.kind) == [.social, .other])
        #expect(groups[0].unmatchedChanges.isEmpty)
        #expect(groups[1].unmatchedChanges.map(\.id) == ["missing-metadata"])
        #expect(groups[1].unmatchedChanges[0].effectiveAt == .distantFuture)
    }

    @Test func emptyAndLegacyDataStayDiscoverable() {
        #expect(ShieldGrouping.groups(schedules: [], restrictions: [], pending: []).isEmpty)
        #expect(ShieldGrouping.kind(for: schedule("social-night", title: "X / Reddit — Night")) == .social)
        #expect(ShieldGrouping.kind(for: schedule("youtube", title: "Video sites")) == .video)
        #expect(ShieldGrouping.title("Video sites") == "YouTube")
        #expect(ShieldGrouping.title("Social feeds") == "X / Reddit")
        #expect(ShieldGrouping.title("A new category") == "A new category")
    }

    @Test func allowedNowIsNeutralAndPendingTakesPriorityOverBlocked() {
        let original = schedule()
        #expect(ShieldGrouping.scheduleStatus(original, evidence: .confirmed, effectiveIDs: [], pendingIDs: []) == .allowed)
        #expect(ShieldGrouping.scheduleStatus(original, evidence: .confirmed, effectiveIDs: [original.id], pendingIDs: []) == .protected)
        #expect(ShieldGrouping.scheduleStatus(original, evidence: .confirmed, effectiveIDs: [original.id], pendingIDs: [original.id]) == .pending)
        #expect(ShieldGrouping.scheduleStatus(schedule(requested: false), evidence: .confirmed, effectiveIDs: [], pendingIDs: []) == .inactive)
    }

    @Test func overlappingOwnerCannotLookLikeUnrestrictedAccess() {
        let original = schedule()
        #expect(ShieldGrouping.scheduleStatus(original, evidence: .confirmed, effectiveIDs: ["extra"], pendingIDs: [],
                                             otherBlockedDomains: ["x.com"]) == .overlapping)
        #expect(ShieldGrouping.scheduleStatus(original, evidence: .confirmed, effectiveIDs: ["extra"], pendingIDs: [],
                                             otherBlockedDomains: ["unrelated.example"]) == .allowed)
    }

    @Test func unavailableAndPreviewNeverAppearGreenEvenWithCachedPolicies() {
        let original = schedule()
        for evidence in [ShieldEvidence.preview, .attention, .unavailable] {
            #expect(ShieldGrouping.scheduleStatus(original, evidence: evidence, effectiveIDs: [original.id], pendingIDs: []) == evidence.status)
            #expect(ShieldGrouping.groupStatus([.protected, .allowed, .permanent], evidence: evidence) == evidence.status)
        }
        #expect(ShieldGrouping.groupStatus([.allowed, .allowed], evidence: .confirmed) == .allowed)
        #expect(ShieldGrouping.groupStatus([.protected, .allowed], evidence: .confirmed) == .confirmed)
        #expect(ShieldGrouping.groupStatus([.protected, .pending], evidence: .confirmed) == .pending)
    }

    @Test func permanentScheduledAndPendingReleaseStatusesRespectEvidence() {
        let now = Date()
        let permanent = DomainRestriction(owner: .permanent, policyID: "adult", title: "Adult", domains: ["one.example"])
        let later = DomainRestriction(owner: .temporary, policyID: "later", title: "Later", domains: ["one.example"], startsAt: now.addingTimeInterval(3600))
        #expect(ShieldGrouping.restrictionStatus(permanent, evidence: .confirmed, effectiveIDs: ["adult"], pendingIDs: [], now: now) == .permanent)
        #expect(ShieldGrouping.restrictionStatus(permanent, evidence: .unavailable, effectiveIDs: ["adult"], pendingIDs: [], now: now) == .unavailable)
        #expect(ShieldGrouping.restrictionStatus(later, evidence: .confirmed, effectiveIDs: [], pendingIDs: [], now: now) == .scheduled)
        // "Pending" only while the rule is blocking; a not-yet-started rule stays "Scheduled".
        #expect(ShieldGrouping.restrictionStatus(later, evidence: .confirmed, effectiveIDs: [], pendingIDs: ["later"], now: now) == .scheduled)
        #expect(ShieldGrouping.restrictionStatus(later, evidence: .confirmed, effectiveIDs: ["later"], pendingIDs: ["later"], now: now) == .pending)
        #expect(ShieldRuleStatus.pending.title == "Blocking · change pending")
    }

    @Test func serviceEvidenceRequiresFreshMatchingAuthorityAndEnforcement() {
        let now = Date()
        let state = AuthorityState(schemaVersion: 1, generation: 9, generatedAt: now, reconciliationID: UUID(),
                                   lastSuccessfulReconciliation: now, commitments: [], effectiveRestrictions: [])
        func resolve(_ authority: AuthorityStatus = .valid(state), _ enforcement: EvidenceState = .verified,
                     snapshot: Bool = true, live: Bool = true, age: TimeInterval = 0, match: Bool = true) -> ShieldEvidence {
            ShieldEvidence.resolve(authority: authority, enforcement: enforcement, hasSnapshot: snapshot,
                                   isLiveService: live, observedAt: now.addingTimeInterval(-age), generationsMatch: match, now: now)
        }
        #expect(resolve() == .confirmed)
        #expect(resolve(snapshot: false) == .unavailable)
        #expect(resolve(.unavailable(.missing)) == .unavailable)
        #expect(resolve(.valid(state), .mismatch("missing hosts")) == .attention)
        #expect(resolve(.valid(state), .unavailable("disconnected")) == .unavailable)
        // A slow reply or a short reconnect is ridden out; older evidence is not.
        #expect(ShieldEvidence.maximumAge == 75)
        #expect(resolve(age: 31) == .confirmed)
        #expect(resolve(age: 74) == .confirmed)
        #expect(resolve(age: 76) == .attention)
        #expect(resolve(age: -76) == .attention)
        #expect(resolve(match: false) == .attention)
        #expect(resolve(live: false) == .preview)
    }

    /// One slow reply blanked the page with "Protection
    /// unavailable". Only a missed reply shortly after a verified answer keeps
    /// the last rules; every other failure still rejects at once.
    @Test func briefNoReplyKeepsTheLastVerifiedRules() {
        let now = Date()
        let noReply = FixtureBackendError.uncertain("The service disconnected or timed out.")
        func rides(_ error: Error = noReply, snapshot: Bool = true, answered: TimeInterval? = 6) -> Bool {
            ShieldViewModel.ridesOut(error, hasSnapshot: snapshot,
                                     lastAnswered: answered.map { now.addingTimeInterval(-$0) }, now: now)
        }
        #expect(ShieldViewModel.connectionGrace == 60)
        #expect(rides())
        #expect(rides(answered: 59))
        #expect(!rides(answered: 61))            // a longer silence is shown
        #expect(!rides(answered: -5))            // an answer "from the future" proves nothing
        #expect(!rides(answered: nil))           // never answered: nothing to keep
        #expect(!rides(snapshot: false))         // nothing on screen to keep
        #expect(!rides(FixtureBackendError.invalidReceipt))
        #expect(!rides(FixtureBackendError.generationConflict))
        #expect(!rides(FixtureBackendError.invalidRequest("bad")))
        #expect(rides(FixtureBackendError.uncertain("The connection to service named com.kairos.ShieldAuthority was interrupted.")))
        // The same macOS error on a Mac set to another language.
        #expect(rides(FixtureBackendError.uncertain("La connexion au service nommé com.kairos.ShieldAuthority a été interrompue.")))
        // Errors the service itself sent back always show at once.
        #expect(!rides(FixtureBackendError.uncertain("The service returned a stale generation.")))
        #expect(!rides(FixtureBackendError.uncertain(FixtureBackendError.uncertain("authority missing").localizedDescription)))
        #expect(!rides(FixtureBackendError.uncertain(FixtureBackendError.invalidReceipt.localizedDescription)))
        #expect(!rides(FixtureBackendError.uncertain(FixtureBackendError.generationConflict.localizedDescription)))
        #expect(!rides(FixtureBackendError.uncertain(FixtureBackendError.invalidRequest("bad").localizedDescription)))
    }
}
