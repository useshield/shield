import Foundation
import Testing
@testable import Shield

/// Shield 1.1: Remove Shield waits like removing a permanent block, never
/// cuts a timed block short, and is refused while a never-removable block
/// exists. Keeping Shield applies at once.
struct ShieldRemovalRequestTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldRemovalRequest-\(UUID().uuidString)", isDirectory: true)
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

    private func rule(_ id: String, _ owner: PolicyOwner = .permanent, startsAt: Date, endsAt: Date? = nil)
        -> DomainRestriction {
        DomainRestriction(owner: owner, policyID: id, title: id, domains: ["\(id).example"], startsAt: startsAt,
                          endsAt: endsAt)
    }

    private func isDue(_ backend: FixtureBackend, at now: Date) throws -> Bool {
        let snapshot = try backend.snapshot(now: now, calendar: .current)
        return snapshot.permanentRemoval?.uninstallIsDue(restrictions: snapshot.committedRestrictions,
                                                        pending: snapshot.pendingReleases, at: now) == true
    }

    @Test func removalWaitsTheFullPermanentWait() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        try submit(backend, [.add(rule("focus-a", startsAt: now))], at: now)
        #expect(throws: FixtureBackendError.self) {
            try submit(backend, [.requestUninstall(at: now.addingTimeInterval(259_199))], at: now)
        }
        let date = now.addingTimeInterval(259_300)
        try submit(backend, [.requestUninstall(at: date)], at: now)
        #expect(try !isDue(backend, at: date.addingTimeInterval(-1)))
        #expect(try isDue(backend, at: date))
        #expect(throws: FixtureBackendError.self, "Asked once only") {
            try submit(backend, [.requestUninstall(at: date)], at: now)
        }
    }

    @Test func neverRemovableBlocksKeepShieldInstalled() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        try submit(backend, [.add(rule("owner-plan-adult-1", startsAt: now))], at: now)
        #expect(throws: FixtureBackendError.self) {
            try submit(backend, [.requestUninstall(at: now.addingTimeInterval(400_000))], at: now)
        }
    }

    @Test func aTimedBlockOrPendingChangeDelaysRemoval() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        let ends = now.addingTimeInterval(10 * 86_400)
        try submit(backend, [.add(rule("study", .commitment, startsAt: now, endsAt: ends))], at: now)
        let date = now.addingTimeInterval(259_300)
        try submit(backend, [.requestUninstall(at: date)], at: now)
        #expect(try !isDue(backend, at: date.addingTimeInterval(86_400)), "The timed block hasn't ended")
        #expect(try isDue(backend, at: ends))
    }

    @Test func somethingAddedLaterGetsItsOwnFullWait() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        try submit(backend, [.add(rule("focus-a", startsAt: now))], at: now)
        let date = now.addingTimeInterval(259_300)
        try submit(backend, [.requestUninstall(at: date)], at: now)
        let later = now.addingTimeInterval(2 * 86_400)
        try submit(backend, [.add(rule("focus-b", startsAt: later))], at: later)
        #expect(try !isDue(backend, at: date), "focus-b was added a day before")
        #expect(try isDue(backend, at: later.addingTimeInterval(259_200)))
    }

    @Test func keepingShieldAppliesAtOnce() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        try submit(backend, [.add(rule("focus-a", startsAt: now))], at: now)
        let date = now.addingTimeInterval(259_300)
        try submit(backend, [.requestUninstall(at: date)], at: now)
        try submit(backend, [.cancelUninstall], at: now.addingTimeInterval(60))
        let snapshot = try backend.snapshot(now: date, calendar: .current)
        #expect(snapshot.permanentRemoval?.uninstallAt == nil)
        #expect(try !isDue(backend, at: date))
        #expect(throws: FixtureBackendError.self, "Nothing to cancel") {
            try submit(backend, [.cancelUninstall], at: now.addingTimeInterval(120))
        }
    }
}
