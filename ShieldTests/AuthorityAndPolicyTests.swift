import Foundation
import Testing
@testable import Shield

struct AuthorityAndPolicyTests {
    @Test func missingAuthorityFailsClosed() throws {
        let root = try temporaryDirectory()
        let status = AuthorityStateReader(
            fileURL: root.appendingPathComponent("missing.plist")
        ).read(now: .now)
        #expect(status == .unavailable(.missing))
    }

    @Test func zeroByteAuthorityFailsClosed() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("authority.plist")
        try Data().write(to: url)
        let status = AuthorityStateReader(fileURL: url).read(now: .now)
        #expect(status == .unavailable(.empty))
    }

    @Test func malformedAuthorityFailsClosed() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("authority.plist")
        try Data("not a plist".utf8).write(to: url)
        let status = AuthorityStateReader(fileURL: url).read(now: .now)
        guard case .unavailable(.malformed) = status else {
            Issue.record("Expected malformed authority state.")
            return
        }
    }

    @Test func unversionedLegacyAuthorityRequiresMigrationEvidence() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("authority.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: ["legacyBlocks": ["example.com"]],
                                                      format: .xml, options: 0)
        try data.write(to: url)
        #expect(AuthorityStateReader(fileURL: url).read(now: .now) == .unavailable(.unsupportedSchema(0)))
    }

    @Test func authorityRejectsInvalidDomainAndExpiredRestriction() throws {
        let now = Date()
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("authority.plist")
        for restriction in [
            DomainRestriction(owner: .permanent, policyID: "bad", title: "Bad", domains: ["bad name"]),
            DomainRestriction(owner: .temporary, policyID: "old", title: "Old", domains: ["example.com"],
                              startsAt: now.addingTimeInterval(-120), endsAt: now.addingTimeInterval(-1))
        ] {
            let state = AuthorityState(schemaVersion: 1, generation: 1, generatedAt: now,
                                       reconciliationID: UUID(), lastSuccessfulReconciliation: now,
                                       commitments: [], effectiveRestrictions: [restriction])
            try PropertyListEncoder().encode(state).write(to: url)
            guard case .unavailable(.incomplete) = AuthorityStateReader(fileURL: url).read(now: now) else {
                Issue.record("Invalid effective restriction was accepted.")
                return
            }
        }
    }

    @Test func authorityRejectsSymlink() throws {
        let now = Date()
        let root = try temporaryDirectory()
        let real = root.appendingPathComponent("real.plist")
        let link = root.appendingPathComponent("linked.plist")
        try writeAuthority(to: real, generatedAt: now)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        guard case .unavailable(.unreadable) = AuthorityStateReader(fileURL: link).read(now: now) else {
            Issue.record("Authority symlink was accepted.")
            return
        }
    }

    @Test func invalidFieldTypesFailClosed() throws {
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("authority.plist")
        let invalid: [String: Any] = [
            "schemaVersion": "one",
            "generation": 1,
            "generatedAt": Date(),
            "reconciliationID": UUID().uuidString
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: invalid,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
        let status = AuthorityStateReader(fileURL: url).read(now: .now)
        guard case .unavailable(.malformed) = status else {
            Issue.record("Expected type validation failure.")
            return
        }
    }

    @Test func staleAuthorityFailsClosed() throws {
        let now = Date()
        let root = try temporaryDirectory()
        let url = root.appendingPathComponent("authority.plist")
        try writeAuthority(to: url, generatedAt: now.addingTimeInterval(-600))
        let status = AuthorityStateReader(
            fileURL: url,
            maximumAge: 300
        ).read(now: now)
        guard case .unavailable(.stale) = status else {
            Issue.record("Expected stale authority state.")
            return
        }
    }

    @Test func corruptAuthorityCannotWeakenCommitments() {
        let status = AuthorityStatus.unavailable(.empty)
        #expect(throws: ReconciliationError.self) {
            try AuthorityRecoveryPolicy().plan(
                authority: status,
                requestedDomains: []
            )
        }
    }

    @Test func strengtheningIsImmediateAndWeakeningIsDelayed() {
        let now = Date()
        let state = makeAuthority(
            generatedAt: now,
            domains: ["permanent.example", "committed.example"]
        )
        let plan = try? AuthorityRecoveryPolicy().plan(
            authority: .valid(state),
            requestedDomains: ["permanent.example", "new.example"]
        )

        #expect(plan?.immediateStrengthening == ["new.example"])
        #expect(plan?.delayedWeakening == ["committed.example"])
        #expect(plan?.status == .strengtheningAndWeakeningDeferred)
        #expect(plan?.effectiveDomains == [
            "permanent.example", "committed.example", "new.example"
        ])
    }

    @Test func overlappingRestrictionsPreservePermanentOwner() {
        let now = Date()
        let permanent = DomainRestriction(
            owner: .permanent,
            policyID: "permanent",
            title: "Permanent",
            domains: ["shared.example"]
        )
        let temporary = DomainRestriction(
            owner: .temporary,
            policyID: "october",
            title: "October",
            domains: ["shared.example", "temporary.example"],
            startsAt: now.addingTimeInterval(-60),
            endsAt: now.addingTimeInterval(60)
        )
        let engine = UnifiedPolicyEngine()
        let during = engine.evaluate(
            restrictions: [permanent, temporary],
            schedules: [],
            at: now,
            calendar: .current
        )
        let after = engine.evaluate(
            restrictions: [permanent, temporary],
            schedules: [],
            at: now.addingTimeInterval(120),
            calendar: .current
        )

        #expect(during.domains == ["shared.example", "temporary.example"])
        #expect(after.domains == ["shared.example"])
    }

    @Test func octoberYouTubeRuleUnionsWithOriginalSchedule() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_760_400_000)
        let october = DomainRestriction(
            owner: .temporary,
            policyID: "october-study",
            title: "October Study Period",
            domains: ["x.com", "reddit.com", "netflix.com", "tiktok.com", "instagram.com", "pinterest.com", "youtube.com"],
            startsAt: now.addingTimeInterval(-3_600),
            endsAt: now.addingTimeInterval(3_600)
        )
        let result = UnifiedPolicyEngine().evaluate(
            restrictions: [october],
            schedules: [],
            at: now,
            calendar: calendar
        )
        #expect(result.domains.contains("youtube.com"))
        #expect(result.domains.contains("netflix.com"))
    }

    @Test func overnightWindowAndBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let schedule = DailySchedule(
            id: "night",
            title: "Night",
            domains: ["example.com"],
            startMinutes: 20 * 60,
            endMinutes: 8 * 60,
            isRequested: true
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let late = try #require(formatter.date(from: "2026-10-13T21:00:00-04:00"))
        let early = try #require(formatter.date(from: "2026-10-14T07:59:00-04:00"))
        let boundary = try #require(formatter.date(from: "2026-10-14T08:00:00-04:00"))

        #expect(schedule.contains(late, calendar: calendar))
        #expect(schedule.contains(early, calendar: calendar))
        #expect(!schedule.contains(boundary, calendar: calendar))
    }

    @Test func invalidScheduleDoesNotBecomeEffective() {
        let schedule = DailySchedule(id: "invalid", title: "Invalid", domains: ["example.com"],
                                     startMinutes: 1_500, endMinutes: 100, isRequested: true)
        let result = UnifiedPolicyEngine().evaluate(restrictions: [], schedules: [schedule],
                                                    at: .now, calendar: .current)
        #expect(result.domains.isEmpty)
        #expect(result.nextTransition == nil)
    }

    @Test func nextTransitionSurvivesDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let schedule = DailySchedule(
            id: "morning",
            title: "Morning",
            domains: ["example.com"],
            startMinutes: 7 * 60,
            endMinutes: 13 * 60,
            isRequested: true
        )
        let start = try #require(
            ISO8601DateFormatter().date(from: "2026-11-01T04:30:00Z")
        )
        let transition = try #require(
            schedule.nextTransition(after: start, calendar: calendar)
        )
        let clockChange = try #require(
            ISO8601DateFormatter().date(from: "2026-11-01T06:00:00Z")
        )
        #expect(transition == clockChange)
        #expect(!schedule.contains(transition, calendar: calendar))
    }

    @Test func legacyInspectionNeverPromotesUnknownCommitments() throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("historical-authority.plist")
        try Data().write(to: file)
        let empty = LegacyAuthorityInspector().inspect(file)
        #expect(empty.classification == "unknown")
        #expect(!empty.mayMigrateAutomatically)
        try Data("not a plist".utf8).write(to: file)
        let corrupt = LegacyAuthorityInspector().inspect(file)
        #expect(corrupt.classification == "unknown")
        #expect(!corrupt.mayMigrateAutomatically)
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("KairosTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}

private func makeAuthority(
    generatedAt: Date,
    domains: Set<String> = []
) -> AuthorityState {
    AuthorityState(
        schemaVersion: AuthorityState.currentSchemaVersion,
        generation: 1,
        generatedAt: generatedAt,
        reconciliationID: UUID(),
        lastSuccessfulReconciliation: generatedAt,
        commitments: [],
        effectiveRestrictions: [
            DomainRestriction(
                owner: .commitment,
                policyID: "fixture",
                title: "Fixture",
                domains: domains
            )
        ]
    )
}

private func writeAuthority(to url: URL, generatedAt: Date) throws {
    let data = try PropertyListEncoder().encode(
        makeAuthority(generatedAt: generatedAt)
    )
    try data.write(to: url)
}
