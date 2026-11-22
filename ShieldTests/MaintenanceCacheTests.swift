import Foundation
import Testing
@testable import Shield

// R4: the service reuses its last verified snapshot only while none
// of the state files changed and nothing is due, and re-checks everything at
// least every 30 s.
struct MaintenanceCacheTests {
    private func backend() throws -> FixtureBackend {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldMaintenanceCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
        return try FixtureBackend(root: root)
    }

    private func seeded(_ backend: FixtureBackend, now: Date) throws -> BackendSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0, submittedAt: now, commands: [
            .add(DomainRestriction(owner: .permanent, policyID: "p", title: "P", domains: ["a.example"])),
            .add(DailySchedule(id: "s", title: "S", domains: ["b.example"], startMinutes: 1200, endMinutes: 840,
                               isRequested: true)),
        ]), now: now, calendar: calendar)
        return try backend.snapshot(now: now, calendar: calendar)
    }

    @Test func reusedOnlyWhileNothingChangedOrCameDue() throws {
        let backend = try backend()
        let now = Date()
        let snapshot = try seeded(backend, now: now)
        let stamp = backend.stateStamp()
        let cache = MaintenanceCache()
        #expect(cache.reusableSnapshot(now: now, stamp: stamp) == nil, "empty until a full check")
        cache.store(snapshot, evidence: snapshot.enforcement, stamp: stamp, at: now)
        #expect(cache.reusableSnapshot(now: now + 10, stamp: stamp)?.generation == snapshot.generation)
        #expect(cache.reusableSnapshot(now: now + MaintenanceCache.fullCheckInterval, stamp: stamp) == nil,
                "a full check at least every 30 s")
        #expect(cache.reusableSnapshot(now: now - 1, stamp: stamp) == nil, "clock set back")
        let refreshDue = snapshot.authority.generatedAt + FixtureBackend.authorityRefreshInterval
        if refreshDue < now + MaintenanceCache.fullCheckInterval {
            #expect(cache.reusableSnapshot(now: refreshDue, stamp: stamp) == nil, "the minute re-commit is never late")
        }
        if let next = snapshot.nextTransition, next < now + MaintenanceCache.fullCheckInterval {
            #expect(cache.reusableSnapshot(now: next, stamp: stamp) == nil, "a schedule edge is never skipped")
        }
        cache.invalidate()
        #expect(cache.reusableSnapshot(now: now + 1, stamp: stamp) == nil)
    }

    @Test func anyWriteToStateEndsReuse() throws {
        let backend = try backend()
        let now = Date()
        let snapshot = try seeded(backend, now: now)
        let stamp = backend.stateStamp()
        #expect(stamp == backend.stateStamp(), "reading doesn't change the stamp")
        let cache = MaintenanceCache()
        cache.store(snapshot, evidence: snapshot.enforcement, stamp: stamp, at: now)
        // The same bytes written again still count as a change.
        let document = backend.paths.document
        try Data(contentsOf: document).write(to: document)
        #expect(backend.stateStamp() != stamp)
        #expect(cache.reusableSnapshot(now: now + 1, stamp: backend.stateStamp()) == nil)
    }

    @Test func pollsAreAnsweredOnlyFromARecentPass() throws {
        let backend = try backend()
        let now = Date()
        let snapshot = try seeded(backend, now: now)
        let stamp = backend.stateStamp()
        let cache = MaintenanceCache()
        cache.store(snapshot, evidence: snapshot.enforcement, stamp: stamp, at: now)
        #expect(cache.latest(now: now + 1, stamp: stamp) != nil)
        #expect(cache.latest(now: now + MaintenanceCache.pollAnswerAge + 1, stamp: stamp) == nil,
                "a stalled maintenance pass never answers polls")
        cache.recordEvidence(snapshot.enforcement, at: now + 4)
        #expect(cache.latest(now: now + 5, stamp: stamp) != nil)
    }
}
