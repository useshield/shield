import Foundation
import Testing
@testable import Shield

/// Shield 1.1: schedules follow this Mac's time zone. A zone macOS set from
/// Location applies at once; one changed by hand waits 24 hours.
struct ScheduleZoneTests {
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var value: ObservedZone?
        func set(_ zone: ObservedZone?) { lock.withLock { value = zone } }
        func get() -> ObservedZone? { lock.withLock { value } }
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // 06:00 UTC: inside a midnight-to-noon block in UTC, 15:00 in Tokyo.
    private let start = ISO8601DateFormatter().date(from: "2026-11-10T06:00:00Z")!

    private func backend(_ seen: Seen) throws -> (FixtureBackend, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldScheduleZone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
        var backend = try FixtureBackend(root: root)
        backend.observeZone = { seen.get() }
        let schedule = DailySchedule(id: "mornings", title: "Mornings", domains: ["news.example"],
                                     startMinutes: 0, endMinutes: 720, isRequested: true)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0, submittedAt: start,
                                             commands: [.add(schedule)]), now: start, calendar: utc)
        return (backend, root)
    }

    private func blocked(_ backend: FixtureBackend, at now: Date) throws -> Bool {
        _ = try backend.tick(now: now, calendar: utc)
        return try backend.snapshot(now: now, calendar: utc).authority.effectiveRestrictions
            .contains { $0.domains.contains("news.example") }
    }

    private func zone(_ backend: FixtureBackend, at now: Date) throws -> ScheduleZone? {
        try backend.snapshot(now: now, calendar: utc).scheduleZone
    }

    @Test func aZoneSetFromLocationAppliesAtOnce() throws {
        let seen = Seen()
        let (backend, root) = try backend(seen)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try blocked(backend, at: start), "Morning in UTC")
        seen.set(ObservedZone(identifier: "UTC", automatic: true))
        #expect(try blocked(backend, at: start), "Same zone: nothing changes")
        #expect(try zone(backend, at: start) == nil)

        seen.set(ObservedZone(identifier: "Asia/Tokyo", automatic: true))
        #expect(try !blocked(backend, at: start.addingTimeInterval(60)), "Afternoon in Tokyo")
        #expect(try backend.snapshot(now: start.addingTimeInterval(60), calendar: utc).timeZoneIdentifier == "Asia/Tokyo")

        // A restarted service without a reading still verifies the stored zone.
        let restarted = try FixtureBackend(root: root)
        #expect(try restarted.snapshot(now: start.addingTimeInterval(120), calendar: utc)
            .authority.effectiveRestrictions.isEmpty)
    }

    @Test func aZoneChangedByHandWaits24Hours() throws {
        let seen = Seen()
        let (backend, root) = try backend(seen)
        defer { try? FileManager.default.removeItem(at: root) }
        seen.set(ObservedZone(identifier: "Asia/Tokyo", automatic: false))
        #expect(try blocked(backend, at: start.addingTimeInterval(60)), "Still UTC for 24 hours")
        let waiting = try #require(try zone(backend, at: start.addingTimeInterval(60)))
        #expect(waiting.identifier == "GMT" && waiting.pendingIdentifier == "Asia/Tokyo")
        #expect(waiting.pendingAt == start.addingTimeInterval(60 + 86_400))
        #expect(try blocked(backend, at: start.addingTimeInterval(86_400)), "Next morning in UTC, not yet due")
        #expect(try !blocked(backend, at: start.addingTimeInterval(86_400 + 120)), "Landed: afternoon in Tokyo")
    }

    @Test func goingBackCancelsAChangeByHand() throws {
        let seen = Seen()
        let (backend, root) = try backend(seen)
        defer { try? FileManager.default.removeItem(at: root) }
        seen.set(ObservedZone(identifier: "Asia/Tokyo", automatic: false))
        _ = try blocked(backend, at: start.addingTimeInterval(60))
        seen.set(ObservedZone(identifier: "UTC", automatic: false))
        _ = try blocked(backend, at: start.addingTimeInterval(120))
        #expect(try zone(backend, at: start.addingTimeInterval(120))?.pendingIdentifier == nil)
        #expect(try blocked(backend, at: start.addingTimeInterval(86_400 + 180)), "Still UTC")
    }

    @Test func observingIsPureAndRejectsUnknownZones() {
        let now = start
        let zone = ScheduleZone(identifier: "GMT")
        #expect(zone.observing(ObservedZone(identifier: "Nowhere/Fake", automatic: true), at: now) == zone)
        let waiting = zone.observing(ObservedZone(identifier: "Europe/Paris", automatic: false), at: now)
        #expect(waiting.pendingIdentifier == "Europe/Paris" && waiting.isWellFormed)
        #expect(waiting.observing(ObservedZone(identifier: "Europe/Paris", automatic: false),
                                  at: now.addingTimeInterval(3600)) == waiting, "The wait doesn't restart")
        #expect(waiting.settled(at: now.addingTimeInterval(86_400)).identifier == "Europe/Paris")
    }
}
