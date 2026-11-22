import Foundation
import Testing
@testable import Shield

/// A daily window closing must count as a change for tab closing and the
/// Reopen notice.
struct BlockBoundaryTests {
    @Test func aWindowClosingCountsAsAChange() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BlockBoundary-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
        let backend = try FixtureBackend(root: root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 12))!
        func at(_ hour: Int, _ minute: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        // Pinterest allowed 4–6 PM: stored as blocked 6 PM → 4 PM.
        let pinterest = DailySchedule(id: "pinterest-afternoon", title: "Pinterest", domains: ["pinterest.com"],
                                      startMinutes: 1080, endMinutes: 960, isRequested: true)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0, submittedAt: at(17, 0),
                                             commands: [.add(pinterest)]), now: at(17, 0), calendar: calendar)

        _ = try backend.tick(now: at(17, 59), calendar: calendar)
        let open = try backend.snapshot(now: at(17, 59), calendar: calendar)
        _ = try backend.tick(now: at(18, 1), calendar: calendar)
        let blocked = try backend.snapshot(now: at(18, 1), calendar: calendar)

        #expect(!open.authority.effectiveRestrictions.contains { $0.domains.contains("pinterest.com") })
        #expect(blocked.authority.effectiveRestrictions.contains { $0.domains.contains("pinterest.com") })
        #expect(ShieldViewModel.BookkeepingKey(open) != ShieldViewModel.BookkeepingKey(blocked),
                "The block starting must run the tab closing")
        // An ordinary poll with nothing new still skips the bookkeeping.
        let again = try backend.snapshot(now: at(18, 2), calendar: calendar)
        #expect(ShieldViewModel.BookkeepingKey(again) == ShieldViewModel.BookkeepingKey(blocked))

        // The window redraws for the change, not for every 5 s poll, and
        // still shows fresh check times at least once a minute.
        #expect(ShieldViewModel.pollNeedsRedraw(shown: open, incoming: blocked, shownAt: at(17, 59), now: at(18, 1)))
        let shownAt = at(18, 1)
        #expect(!ShieldViewModel.pollNeedsRedraw(shown: blocked, incoming: again, shownAt: shownAt,
                                                 now: shownAt.addingTimeInterval(5)))
        #expect(ShieldViewModel.pollNeedsRedraw(shown: blocked, incoming: again, shownAt: shownAt,
                                                now: shownAt.addingTimeInterval(60)))
        #expect(ShieldViewModel.pollNeedsRedraw(shown: nil, incoming: again, shownAt: nil, now: shownAt))
    }
}
