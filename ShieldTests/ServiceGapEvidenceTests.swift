import Foundation
import Testing
@testable import Shield

struct ServiceGapEvidenceTests {
    private let boot = Date(timeIntervalSince1970: 1_792_774_807)
    private let second: UInt64 = 1_000_000_000

    private func beat(wall: Date, awake: UInt64, elapsed: UInt64, boot: Date? = nil) -> AuthorityHeartbeat {
        AuthorityHeartbeat(wallClock: wall, bootTime: boot ?? self.boot,
                           awakeNanoseconds: awake * second, elapsedNanoseconds: elapsed * second)
    }

    @Test func stoppedWhileAwakeIsRecordedWithMonotonicDuration() throws {
        // Tonight's shape: last heartbeat 8:41 PM, service back 10:07 PM, no sleep.
        let before = beat(wall: Date(timeIntervalSince1970: 1_793_151_660), awake: 10_000, elapsed: 50_000)
        let after = beat(wall: Date(timeIntervalSince1970: 1_793_156_820), awake: 15_160, elapsed: 55_160)
        let gap = try #require(ServiceGapClassifier.gap(from: before, to: after))
        #expect(gap.awakeSeconds == 5_160)
        #expect(!gap.macSlept)
        #expect(gap.silentFrom == before.wallClock)
        #expect(gap.resumedAt == after.wallClock)
    }

    @Test func normalTicksAndSleepAreNotRecorded() {
        let start = beat(wall: .now, awake: 1_000, elapsed: 2_000)
        #expect(ServiceGapClassifier.gap(from: start, to: beat(wall: .now, awake: 1_030, elapsed: 2_030)) == nil)
        // Eight hours asleep with one awake minute is ordinary sleep, not a stop.
        #expect(ServiceGapClassifier.gap(from: start, to: beat(wall: .now, awake: 1_060, elapsed: 30_860)) == nil)
    }

    @Test func awakeTimeAroundSleepIsStillRecorded() throws {
        let start = beat(wall: .now, awake: 1_000, elapsed: 2_000)
        let gap = try #require(ServiceGapClassifier.gap(from: start, to: beat(wall: .now, awake: 2_200, elapsed: 30_000)))
        #expect(gap.awakeSeconds == 1_200)
        #expect(gap.macSlept)
    }

    @Test func restartsAndClockChangesCannotForgeOrHideAGap() throws {
        let start = beat(wall: .now, awake: 1_000, elapsed: 2_000)
        // A new boot resets the counters: not classified either way.
        #expect(ServiceGapClassifier.gap(from: start,
            to: beat(wall: .now, awake: 40, elapsed: 40, boot: boot.addingTimeInterval(86_400))) == nil)
        // Setting the wall clock back an hour does not hide a 20-minute stop.
        let rolledBack = beat(wall: start.wallClock.addingTimeInterval(-3_600), awake: 2_200, elapsed: 3_200)
        #expect(try #require(ServiceGapClassifier.gap(from: start, to: rolledBack)).awakeSeconds == 1_200)
        // Jumping the wall clock forward a day does not invent one.
        let jumped = beat(wall: start.wallClock.addingTimeInterval(86_400), awake: 1_010, elapsed: 2_010)
        #expect(ServiceGapClassifier.gap(from: start, to: jumped) == nil)
    }

    @Test func backendPersistsHeartbeatAndBoundedGapHistory() throws {
        let backend = try FixtureBackend(root: gapDirectory())
        #expect(backend.loadHeartbeat() == nil)
        #expect(backend.serviceGaps().isEmpty)
        let heartbeat = beat(wall: Date(timeIntervalSince1970: 1_793_000_000), awake: 5, elapsed: 6)
        try backend.recordHeartbeat(heartbeat)
        #expect(backend.loadHeartbeat() == heartbeat)
        for index in 0..<(ServiceGapClassifier.retainedGaps + 5) {
            try backend.appendServiceGap(ServiceGap(silentFrom: Date(timeIntervalSince1970: Double(index)),
                resumedAt: Date(timeIntervalSince1970: Double(index) + 500), awakeSeconds: 500, macSlept: false))
        }
        let gaps = backend.serviceGaps()
        #expect(gaps.count == ServiceGapClassifier.retainedGaps)
        #expect(gaps.first?.silentFrom == Date(timeIntervalSince1970: 5))
    }

    @Test func monitorRecordsAStopFromThePersistedHeartbeatOnce() throws {
        let backend = try FixtureBackend(root: gapDirectory())
        let now = try #require(AuthorityHeartbeat.now())
        guard now.awakeNanoseconds > 1_200 * second else { return }
        try backend.recordHeartbeat(AuthorityHeartbeat(wallClock: now.wallClock.addingTimeInterval(-600),
            bootTime: now.bootTime, awakeNanoseconds: now.awakeNanoseconds - 600 * second,
            elapsedNanoseconds: now.elapsedNanoseconds - 600 * second))
        let monitor = ServiceGapMonitor(backend: backend)
        monitor.start()
        monitor.beat()
        let gaps = backend.serviceGaps()
        #expect(gaps.count == 1)
        #expect((gaps.first?.awakeSeconds ?? 0) >= 600)
        #expect(backend.loadHeartbeat().map { $0.awakeNanoseconds >= now.awakeNanoseconds } == true)
    }

    @Test func summaryStatesAwakeDurationPlainly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let gap = ServiceGap(silentFrom: Date(timeIntervalSince1970: 1_793_151_660),
                             resumedAt: Date(timeIntervalSince1970: 1_793_156_820),
                             awakeSeconds: 5_160, macSlept: false)
        let text = ServiceGapPresentation.summary(gap, calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(text.contains("9:41"))
        #expect(text.contains("11:07"))
        #expect(text.hasSuffix("not running for 1 h 26 min while this Mac was awake."))
        #expect(ServiceGapPresentation.duration(30) == "1 min")
        #expect(ServiceGapPresentation.duration(7_200) == "2 h")
    }
}

private func gapDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShieldGapTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
    return root
}
