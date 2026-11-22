import Foundation
import Testing
@testable import Shield

struct PolicyCampaignTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldPolicyCampaign-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
        return root
    }

    private func request(_ commands: [BackendCommand], generation: UInt64, at now: Date) -> BackendRequest {
        BackendRequest(version: 1, id: UUID(), expectedGeneration: generation,
                       submittedAt: now, commands: commands)
    }

    @Test func timedCommitmentRefusesReleaseAndExpiresWithoutLosingOtherOwners() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        let permanent = DomainRestriction(owner: .permanent, policyID: "permanent", title: "Keep",
                                          domains: ["shared.invalid"])
        let timed = DomainRestriction(owner: .commitment, policyID: "timed", title: "Timed",
            domains: ["shared.invalid", "timed.invalid"], endsAt: now.addingTimeInterval(3_600))
        _ = try backend.apply(request([.add(permanent), .add(timed)], generation: 0, at: now),
                              now: now, calendar: .current)
        // Timed blocks end on their own; a release request is refused.
        let release = request([.release("timed", at: now.addingTimeInterval(86_400))], generation: 1, at: now)
        #expect(throws: FixtureBackendError.self) { _ = try backend.apply(release, now: now, calendar: .current) }
        let later = now.addingTimeInterval(7_200)
        _ = try backend.tick(now: later, calendar: .current)
        let reopened = try FixtureBackend(root: root)
        let snapshot = try reopened.snapshot(now: later, calendar: .current)
        #expect(snapshot.committedRestrictions == [permanent])
        #expect(snapshot.pendingReleases.isEmpty)
        #expect(snapshot.enforcement.blockedDomains == ["shared.invalid"])
        // An unchanged authority is re-committed every `authorityRefreshInterval`.
        _ = try reopened.tick(now: later.addingTimeInterval(FixtureBackend.authorityRefreshInterval + 60),
                              calendar: .current)
        #expect(try reopened.verifiedReceipt().payload.generation == snapshot.generation + 1)
    }

    @Test func lateJournalRecoverySettlesDueReleaseAndRetainsExactReplay() throws {
        for fault in [FixtureBackendFault.afterJournal, .afterHosts] {
            let root = try directory()
            defer { try? FileManager.default.removeItem(at: root) }
            let backend = try FixtureBackend(root: root)
            let now = Date()
            let permanent = DomainRestriction(owner: .permanent, policyID: "keep", title: "Keep",
                                              domains: ["shared.invalid"])
            let commitment = DomainRestriction(owner: .commitment, policyID: "release", title: "Release",
                                                domains: ["shared.invalid", "released.invalid"])
            _ = try backend.apply(request([.add(permanent), .add(commitment)], generation: 0, at: now),
                                  now: now, calendar: .current)
            let due = now.addingTimeInterval(86_400)
            let release = request([.release("release", at: due)], generation: 1, at: now)
            let interrupted = try FixtureBackend(root: root, fault: fault)
            #expect(throws: FixtureBackendError.self) {
                try interrupted.apply(release, now: now, calendar: .current)
            }
            let later = due.addingTimeInterval(600)
            let recovered = try backend.recover(now: later, calendar: .current)
            #expect(recovered.status == .recovered)
            #expect(recovered.receipt.payload.requestID == release.id)
            #expect(recovered.receipt.payload.generation == 3)
            let snapshot = try backend.snapshot(now: later, calendar: .current)
            #expect(snapshot.pendingReleases.isEmpty)
            #expect(snapshot.committedRestrictions == [permanent])
            #expect(snapshot.enforcement.blockedDomains == ["shared.invalid"])
            #expect(try backend.apply(release, now: later, calendar: .current).status == .alreadyApplied)
            #expect(!FileManager.default.fileExists(atPath: backend.paths.journal.path))
        }
    }

    @Test func newMutationSettlesDueReleaseBeforeCreatingAnotherAuthority() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        let commitment = DomainRestriction(owner: .commitment, policyID: "old", title: "Old",
                                            domains: ["old.invalid"])
        _ = try backend.apply(request([.add(commitment)], generation: 0, at: now), now: now, calendar: .current)
        let due = now.addingTimeInterval(86_400)
        _ = try backend.apply(request([.release("old", at: due)], generation: 1, at: now),
                              now: now, calendar: .current)
        // No heartbeat has run when another authorized operation arrives.
        let added = DomainRestriction(owner: .permanent, policyID: "new", title: "New", domains: ["new.invalid"])
        _ = try backend.apply(request([.add(added)], generation: 2, at: due), now: due, calendar: .current)
        let snapshot = try backend.snapshot(now: due, calendar: .current)
        #expect(snapshot.committedRestrictions == [added])
        #expect(snapshot.pendingReleases.isEmpty)
        #expect(snapshot.enforcement.blockedDomains == ["new.invalid"])
        #expect(snapshot.generation == 3)
    }

    @Test func backwardsClockCannotRewriteRecoveryArtifacts() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let interrupted = try FixtureBackend(root: root, fault: .afterJournal)
        let rule = DomainRestriction(owner: .permanent, policyID: "keep", title: "Keep", domains: ["keep.invalid"])
        #expect(throws: FixtureBackendError.self) {
            try interrupted.apply(request([.add(rule)], generation: 0, at: now), now: now, calendar: .current)
        }
        let journal = try Data(contentsOf: interrupted.paths.journal)
        let hosts = try Data(contentsOf: interrupted.paths.hosts)
        let restarted = try FixtureBackend(root: root)
        #expect(throws: FixtureBackendError.self) {
            try restarted.recover(now: now.addingTimeInterval(-60), calendar: .current)
        }
        #expect(try Data(contentsOf: interrupted.paths.journal) == journal)
        #expect(try Data(contentsOf: interrupted.paths.hosts) == hosts)
        #expect(try restarted.recover(now: now, calendar: .current).status == .recovered)
    }

    @Test func oversizedResultIsRejectedBeforeChangingDurablePolicyOrJournal() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        let seed = DomainRestriction(owner: .permanent, policyID: "seed", title: "Seed", domains: ["seed.invalid"])
        _ = try backend.apply(request([.add(seed)], generation: 0, at: now), now: now, calendar: .current)
        let paths = [backend.paths.document, backend.paths.authority, backend.paths.hosts,
                     backend.paths.receipt, backend.paths.key]
        let bytes = try paths.map { try Data(contentsOf: $0) }
        // Over the Nov 13 limits (16 MiB state, 6 MB of hosts): 120,000 long
        // names at the per-list maximum of 2,000 websites.
        let longLabel = String(repeating: "a", count: 63)
        let commands = (0..<60).map { owner in
            BackendCommand.add(DomainRestriction(owner: .permanent, policyID: "bulk-\(owner)", title: "Bulk",
                domains: Set((0..<PolicyValidation.maximumDomains).map {
                    "r\(owner)-\($0).\(longLabel).\(longLabel).\(longLabel).invalid"
                })))
        }
        #expect(throws: FixtureBackendError.self) {
            try backend.apply(request(commands, generation: 1, at: now), now: now, calendar: .current)
        }
        #expect(try paths.map { try Data(contentsOf: $0) } == bytes)
        #expect(!FileManager.default.fileExists(atPath: backend.paths.journal.path))
        #expect(try backend.snapshot(now: now, calendar: .current).committedRestrictions == [seed])
    }

    @Test func repeatedDSTHourIncludesBothStartsAndEnds() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let parser = ISO8601DateFormatter()
        let schedule = DailySchedule(id: "repeat", title: "Repeat", domains: ["repeat.invalid"],
                                     startMinutes: 90, endMinutes: 105, isRequested: true)
        let beforeFirst = try #require(parser.date(from: "2026-11-01T05:20:00Z"))
        let firstStart = try #require(parser.date(from: "2026-11-01T05:30:00Z"))
        let between = try #require(parser.date(from: "2026-11-01T06:20:00Z"))
        let secondStart = try #require(parser.date(from: "2026-11-01T06:30:00Z"))
        let secondEnd = try #require(parser.date(from: "2026-11-01T06:45:00Z"))
        #expect(schedule.nextTransition(after: beforeFirst, calendar: calendar) == firstStart)
        #expect(schedule.nextTransition(after: between, calendar: calendar) == secondStart)
        #expect(schedule.nextTransition(after: secondStart, calendar: calendar) == secondEnd)
        #expect(schedule.contains(firstStart, calendar: calendar))
        #expect(schedule.contains(secondStart, calendar: calendar))
        #expect(!schedule.contains(secondEnd, calendar: calendar))
    }

    @Test func nonFinitePolicyDatesCannotCreateDurableArtifacts() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        let rule = DomainRestriction(owner: .temporary, policyID: "invalid", title: "Invalid",
            domains: ["invalid.invalid"], endsAt: Date(timeIntervalSinceReferenceDate: .infinity))
        #expect(throws: FixtureBackendError.self) {
            try backend.apply(request([.add(rule)], generation: 0, at: now), now: now, calendar: .current)
        }
        #expect(!FileManager.default.fileExists(atPath: backend.paths.document.path))
        #expect(!FileManager.default.fileExists(atPath: backend.paths.key.path))
        #expect(!FileManager.default.fileExists(atPath: backend.paths.journal.path))
    }
}
