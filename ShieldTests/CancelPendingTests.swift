import Foundation
import Testing
@testable import Shield

struct CancelPendingTests {
    private func backend() throws -> FixtureBackend {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CancelPending-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
        return try FixtureBackend(root: root)
    }

    private func request(_ generation: UInt64, _ commands: [BackendCommand], at now: Date) -> BackendRequest {
        BackendRequest(version: 1, id: UUID(), expectedGeneration: generation, submittedAt: now, commands: commands)
    }

    @Test func cancellingLooserHoursAndReleasesKeepsCurrentRulesAtOnce() throws {
        let backend = try backend()
        let now = Date()
        // Allowed 2–8 PM (blocked 8 PM → 2 PM).
        let hours = DailySchedule(id: "social-afternoon", title: "X / Reddit", domains: ["x.com"],
                                  startMinutes: 1200, endMinutes: 840, isRequested: true)
        let block = DomainRestriction(owner: .commitment, policyID: "focus-block", title: "tumblr.com",
                                      domains: ["tumblr.com"], startsAt: now)
        _ = try backend.apply(request(0, [.add(hours), .add(block)], at: now), now: now, calendar: .current)
        // Looser hours (allowed 1–8 PM) and a release, both waiting 24 hours.
        let looser = DailySchedule(id: hours.id, title: hours.title, domains: hours.domains,
                                   startMinutes: 1200, endMinutes: 780, isRequested: true)
        let due = now.addingTimeInterval(86_460)
        _ = try backend.apply(request(1, [.replace(looser, at: due), .release("focus-block", at: due)], at: now),
                              now: now, calendar: .current)
        #expect(try backend.snapshot(now: now, calendar: .current).pendingReleases.count == 2)

        let cancel = request(2, [.cancelPending("social-afternoon"), .cancelPending("focus-block")], at: now)
        _ = try backend.apply(cancel, now: now, calendar: .current)
        let after = try backend.snapshot(now: now, calendar: .current)
        #expect(after.pendingReleases.isEmpty)
        #expect(after.committedSchedules == [hours], "The current, stricter hours stay")
        #expect(after.committedRestrictions.contains { $0.policyID == "focus-block" })
        #expect(PendingPolicySubmission(version: 1, request: cancel, schedulePreferences: nil).isConfirmed(by: after))

        // A day later nothing loosens.
        _ = try backend.tick(now: due.addingTimeInterval(60), calendar: .current)
        let later = try backend.snapshot(now: due.addingTimeInterval(60), calendar: .current)
        #expect(later.committedSchedules == [hours])
        #expect(later.committedRestrictions.contains { $0.policyID == "focus-block" })
    }

    /// A cancel whose reply was lost must not read as confirmed just because
    /// the looser hours it meant to stop came due in the meantime.
    @Test func aLandedReplacementIsNotMistakenForAKeptSchedule() throws {
        let backend = try backend()
        let now = Date()
        let hours = DailySchedule(id: "youtube", title: "YouTube", domains: ["youtube.com"],
                                  startMinutes: 1200, endMinutes: 1080, isRequested: true)
        _ = try backend.apply(request(0, [.add(hours)], at: now), now: now, calendar: .current)
        let looser = DailySchedule(id: hours.id, title: hours.title, domains: hours.domains,
                                   startMinutes: 1200, endMinutes: 960, isRequested: true)
        let due = now.addingTimeInterval(86_460)
        _ = try backend.apply(request(1, [.replace(looser, at: due)], at: now), now: now, calendar: .current)
        let before = try backend.snapshot(now: now, calendar: .current)
        // The cancel is sent but never arrives; the replacement lands on its own.
        let cancel = request(before.generation, [.cancelPending("youtube")], at: now)
        let record = PendingPolicySubmission(version: 1, request: cancel, schedulePreferences: nil, before: before)
        #expect(record.keptSchedules == [hours])
        _ = try backend.tick(now: due.addingTimeInterval(60), calendar: .current)
        let landed = try backend.snapshot(now: due.addingTimeInterval(60), calendar: .current)
        #expect(landed.committedSchedules == [looser])
        #expect(!record.isConfirmed(by: landed), "The looser hours landed; the cancel did not apply")
        // A record saved before this field existed decodes and still works by receipt.
        let legacy = try PropertyListDecoder().decode(PendingPolicySubmission.self, from: PropertyListEncoder().encode(
            PendingPolicySubmission(version: 1, request: cancel, schedulePreferences: nil)))
        #expect(legacy.keptSchedules == nil)
    }

    @Test func cancellingNothingIsRefused() throws {
        let backend = try backend()
        let now = Date()
        _ = try backend.apply(request(0, [.add(DomainRestriction(owner: .commitment, policyID: "focus-a",
            title: "a.example", domains: ["a.example"], startsAt: now))], at: now), now: now, calendar: .current)
        #expect(throws: FixtureBackendError.self) {
            _ = try backend.apply(request(1, [.cancelPending("focus-a")], at: now), now: now, calendar: .current)
        }
        #expect(throws: FixtureBackendError.self) {
            _ = try backend.apply(request(1, [.cancelPending("missing")], at: now), now: now, calendar: .current)
        }
    }
}
