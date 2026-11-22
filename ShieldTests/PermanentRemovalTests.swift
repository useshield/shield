import Foundation
import Testing
@testable import Shield

/// Shield 1.1: removing a permanent block waits 72 hours by
/// default; permanent blocks from before 1.1 stay never-removable; a new
/// block can be undone for 10 minutes.
struct PermanentRemovalTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldPermanentRemoval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
        return root
    }

    private func submit(_ backend: FixtureBackend, _ commands: [BackendCommand], at now: Date) throws {
        let generation = (try? backend.snapshot(now: now, calendar: .current).generation) ?? 0
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: generation,
                                             submittedAt: now, commands: commands), now: now, calendar: .current)
    }

    private func rule(_ id: String, _ owner: PolicyOwner = .permanent, startsAt: Date) -> DomainRestriction {
        DomainRestriction(owner: owner, policyID: id, title: id, domains: ["\(id).example"], startsAt: startsAt)
    }

    @Test func permanentBlocksFromBeforeTheUpdateStayNeverRemovable() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date().addingTimeInterval(-10 * 86_400)
        var old = try FixtureBackend(root: root)
        old.writesPreRemovalDocuments = true
        try submit(old, [.add(rule("focus-old", startsAt: start))], at: start)
        let before = try old.snapshot(now: start, calendar: .current)
        #expect(before.permanentRemoval?.lockedPolicyIDs == ["focus-old"], "Read as locked before any 1.1 request")

        let backend = try FixtureBackend(root: root)
        let now = start.addingTimeInterval(86_400)
        try submit(backend, [.add(rule("focus-new", startsAt: now))], at: now)
        let snapshot = try backend.snapshot(now: now, calendar: .current)
        let removal = try #require(snapshot.permanentRemoval)
        #expect(removal.lockedPolicyIDs == ["focus-old"])
        #expect(removal.wait == 259_200)
        #expect(throws: FixtureBackendError.self) {
            try submit(backend, [.release("focus-old", at: now.addingTimeInterval(400 * 86_400))], at: now)
        }
        // The new one is removable, but only after the full wait.
        #expect(throws: FixtureBackendError.self) {
            try submit(backend, [.release("focus-new", at: now.addingTimeInterval(259_199))], at: now)
        }
        let due = now.addingTimeInterval(259_260)
        try submit(backend, [.release("focus-new", at: due)], at: now)
        #expect(try backend.snapshot(now: now, calendar: .current).authority.effectiveRestrictions
            .contains { $0.policyID == "focus-new" }, "Still blocked while the wait runs")
        _ = try backend.tick(now: due, calendar: .current)
        let after = try backend.snapshot(now: due, calendar: .current)
        #expect(!after.committedRestrictions.contains { $0.policyID == "focus-new" })
        #expect(after.committedRestrictions.contains { $0.policyID == "focus-old" })
    }

    @Test func aFreshInstallLocksNothingButPlanOwnersStayPermanent() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        try submit(backend, [.add(rule("focus-a", startsAt: now)), .add(rule("owner-plan-adult-1", startsAt: now))], at: now)
        let removal = try #require(try backend.snapshot(now: now, calendar: .current).permanentRemoval)
        #expect(removal.lockedPolicyIDs.isEmpty)
        try submit(backend, [.release("focus-a", at: now.addingTimeInterval(259_300))], at: now)
        #expect(throws: FixtureBackendError.self) {
            try submit(backend, [.release("owner-plan-adult-1", at: now.addingTimeInterval(400 * 86_400))], at: now)
        }
    }

    @Test func aLongerWaitAppliesAtOnceAndAShorterOneOnlyAfterTheCurrentWait() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        try submit(backend, [.add(rule("focus-a", startsAt: now))], at: now)
        try submit(backend, [.setPermanentRemovalWait(7 * 86_400)], at: now)
        #expect(try backend.snapshot(now: now, calendar: .current).permanentRemoval?.wait == 7 * 86_400)
        #expect(throws: FixtureBackendError.self) {
            try submit(backend, [.release("focus-a", at: now.addingTimeInterval(259_300))], at: now)
        }
        try submit(backend, [.setPermanentRemovalWait(86_400)], at: now)
        let pending = try #require(try backend.snapshot(now: now, calendar: .current).permanentRemoval)
        #expect(pending.wait == 7 * 86_400 && pending.pendingWait == 86_400)
        #expect(pending.pendingWaitAt == now.addingTimeInterval(7 * 86_400))
        #expect(pending.currentWait(at: now.addingTimeInterval(7 * 86_400 - 1)) == 7 * 86_400)
        // Out of range is refused.
        for bad in [3_600.0, 31 * 86_400, .infinity] {
            #expect(throws: FixtureBackendError.self) { try submit(backend, [.setPermanentRemovalWait(bad)], at: now) }
        }
        let later = now.addingTimeInterval(7 * 86_400 + 60)
        try submit(backend, [.release("focus-a", at: later.addingTimeInterval(86_460))], at: later)
    }

    @Test func aNewBlockCanBeUndoneForTenMinutesOnly() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        try submit(backend, [.add(rule("seed", startsAt: now.addingTimeInterval(-3_600))),
                             .add(rule("focus-p", startsAt: now)), .add(rule("focus-c", .commitment, startsAt: now)),
                             .add(rule("focus-late", startsAt: now))], at: now)
        let soon = now.addingTimeInterval(599)
        try submit(backend, [.undoNew("focus-p"), .undoNew("focus-c")], at: soon)
        let ids = Set(try backend.snapshot(now: soon, calendar: .current).committedRestrictions.map(\.policyID))
        #expect(ids == ["seed", "focus-late"])
        let late = now.addingTimeInterval(601)
        for id in ["focus-late", "seed", "missing"] {
            #expect(throws: FixtureBackendError.self) { try submit(backend, [.undoNew(id)], at: late) }
        }
    }

    @Test func undoNeverReachesTimedBlocksLockInsOrNeverRemovableOnes() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date()
        var old = try FixtureBackend(root: root)
        old.writesPreRemovalDocuments = true
        try submit(old, [.add(rule("focus-old", startsAt: start))], at: start)
        let backend = try FixtureBackend(root: root)
        let now = start.addingTimeInterval(60)
        let timed = DomainRestriction(owner: .temporary, policyID: "focus-timed", title: "Timed",
                                      domains: ["t.example"], startsAt: now, endsAt: now.addingTimeInterval(3_600))
        try submit(backend, [.add(timed), .add(rule("lockin-x", .commitment, startsAt: now))], at: now)
        for id in ["focus-old", "focus-timed", "lockin-x"] {
            #expect(throws: FixtureBackendError.self) { try submit(backend, [.undoNew(id)], at: now) }
        }
    }

    @Test func correctingANeverRemovableBlockKeepsItsOtherSitesNeverRemovable() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date().addingTimeInterval(-3_600)
        var old = try FixtureBackend(root: root)
        old.writesPreRemovalDocuments = true
        let mistake = DomainRestriction(owner: .permanent, policyID: "focus-mistake", title: "Feeds",
                                        domains: ["a.example", "b.example"], startsAt: start)
        try submit(old, [.add(mistake)], at: start)
        let backend = try FixtureBackend(root: root)
        let now = Date()
        let kept = DomainRestriction(owner: .permanent, policyID: "focus-kept", title: "Feeds",
                                     domains: ["b.example"], startsAt: start)
        try submit(backend, [.add(kept), .correctRecentPermanent("focus-mistake", releaseAt: now.addingTimeInterval(86_460))],
                   at: now)
        let removal = try #require(try backend.snapshot(now: now, calendar: .current).permanentRemoval)
        #expect(removal.lockedPolicyIDs.contains("focus-kept"))
        #expect(throws: FixtureBackendError.self) {
            try submit(backend, [.release("focus-kept", at: now.addingTimeInterval(400 * 86_400))], at: now)
        }
    }

    @Test func aReusedRequestIDWithADifferentWaitIsRefused() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        try submit(backend, [.add(rule("focus-a", startsAt: now))], at: now)
        let id = UUID()
        _ = try backend.apply(BackendRequest(version: 1, id: id, expectedGeneration: 1, submittedAt: now,
                                             commands: [.setPermanentRemovalWait(7 * 86_400)]), now: now, calendar: .current)
        #expect(throws: FixtureBackendError.self) {
            _ = try backend.apply(BackendRequest(version: 1, id: id, expectedGeneration: 1, submittedAt: now,
                                                 commands: [.setPermanentRemovalWait(14 * 86_400)]), now: now, calendar: .current)
        }
    }
}
