import Darwin
import Foundation
import Testing
@testable import Shield

// Apps carried by ordinary rules through the backend, and real app closing
// against a child process of this test (never any other process).
struct AppBlockingPolicyTests {
    private let game = AppTarget(displayName: "Example Game", bundleID: "com.example.game", teamID: "TEAM000001")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 30) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func backend() throws -> FixtureBackend {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldAppBlocking-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
        return try FixtureBackend(root: root)
    }

    private func request(_ commands: [BackendCommand], after generation: UInt64, at now: Date) -> BackendRequest {
        BackendRequest(version: 1, id: UUID(), expectedGeneration: generation, submittedAt: now, commands: commands)
    }

    @Test func rulesWithoutAppsKeepTheirExactEncoding() throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let rule = DomainRestriction(owner: .permanent, policyID: "p", title: "P", domains: ["a.example"])
        let xml = String(decoding: try encoder.encode(rule), as: UTF8.self)
        #expect(!xml.contains("<key>apps</key>"))
        let withApps = DomainRestriction(owner: .permanent, policyID: "p", title: "P", domains: [], apps: [game])
        let decoded = try PropertyListDecoder().decode(DomainRestriction.self, from: encoder.encode(withApps))
        #expect(decoded == withApps)
        let schedule = DailySchedule(id: "s", title: "S", domains: ["a.example"], startMinutes: 60, endMinutes: 120,
                                     isRequested: true)
        #expect(!String(decoding: try encoder.encode(schedule), as: UTF8.self).contains("<key>apps</key>"))
    }

    @Test func anAppOnlyBlockCommitsAndIsEnforcedFromTheAuthority() throws {
        let backend = try backend()
        let now = at(12)
        _ = try backend.apply(request([.add(DomainRestriction(owner: .permanent, policyID: "focus-game", title: "Games",
            domains: [], startsAt: now, apps: [game]))], after: 0, at: now), now: now, calendar: calendar)
        let snapshot = try backend.snapshot(now: now, calendar: calendar)
        #expect(snapshot.committedRestrictions.first?.apps == [game])
        #expect(snapshot.authority.effectiveRestrictions.flatMap(\.apps) == [game])
        // A document holding apps is written as version 3 or later, so older
        // services refuse it. (Shield 1.1 always writes 6: its removal record.)
        let document = try PropertyListDecoder().decode(BackendDocument.self, from: Data(contentsOf: backend.paths.document))
        #expect(document.version == 6 && document.permanentRemoval != nil)
        #expect(BackendDocument.version(restrictions: document.restrictions, schedules: document.schedules,
                                        pendingReleases: document.pendingReleases) == 3)
    }

    @Test func documentsWithoutAppsStayVersionTwo() throws {
        let backend = try backend()
        let now = at(12)
        _ = try backend.apply(request([.add(DomainRestriction(owner: .permanent, policyID: "focus-site", title: "Site",
            domains: ["a.example"], startsAt: now))], after: 0, at: now), now: now, calendar: calendar)
        let document = try PropertyListDecoder().decode(BackendDocument.self, from: Data(contentsOf: backend.paths.document))
        // Shield 1.1 writes 6 for its removal record; without apps, nothing else raises it.
        #expect(document.version == 6)
        #expect(BackendDocument.version(restrictions: document.restrictions, schedules: document.schedules,
                                        pendingReleases: document.pendingReleases) == 2)
    }

    @Test func neverBlockableAppsAndEmptyRulesAreRefused() throws {
        let backend = try backend()
        let now = at(12)
        let finder = AppTarget(displayName: "Finder", bundleID: "com.apple.finder", teamID: nil)
        #expect(throws: (any Error).self) {
            _ = try backend.apply(request([.add(DomainRestriction(owner: .permanent, policyID: "focus-x", title: "X",
                domains: [], startsAt: now, apps: [finder]))], after: 0, at: now), now: now, calendar: calendar)
        }
        #expect(throws: (any Error).self) {
            _ = try backend.apply(request([.add(DomainRestriction(owner: .permanent, policyID: "focus-y", title: "Y",
                domains: [], startsAt: now))], after: 0, at: now), now: now, calendar: calendar)
        }
    }

    @Test func removingAnAppFromASchedulePassesThroughTheDelay() throws {
        let backend = try backend()
        let now = at(12)
        // Allowed 6–8 PM: blocked 8 PM to 6 PM.
        let schedule = DailySchedule(id: "games", title: "Games", domains: [], startMinutes: 20 * 60,
                                     endMinutes: 18 * 60, isRequested: true, apps: [game])
        let first = try backend.apply(request([.add(schedule)], after: 0, at: now), now: now, calendar: calendar)
        #expect(try backend.snapshot(now: now, calendar: calendar).authority.effectiveRestrictions.flatMap(\.apps) == [game])
        let other = AppTarget(displayName: "Other", bundleID: "com.example.other", teamID: "TEAM000001")
        let more = DailySchedule(id: "games", title: "Games", domains: [], startMinutes: 20 * 60, endMinutes: 18 * 60,
                                 isRequested: true, apps: [game, other])
        #expect(more.isImmediateStrengthening(of: schedule))
        #expect(!schedule.isImmediateStrengthening(of: more), "Dropping an app is never immediate")
        let fewer = DailySchedule(id: "games", title: "Games", domains: [], startMinutes: 20 * 60, endMinutes: 18 * 60,
                                  isRequested: true, apps: [])
        // An empty rule is refused outright; dropping apps can only wait.
        #expect(throws: (any Error).self) {
            _ = try backend.apply(request([.strengthen(fewer)], after: first.receipt.payload.generation, at: now),
                                  now: now, calendar: calendar)
        }
        // More allowed time is looser: it waits, and the app stays blocked meanwhile.
        let longer = schedule.withHours(start: 21 * 60, end: 18 * 60)
        let delayed = try backend.apply(request([.replace(longer, at: now.addingTimeInterval(86_460))],
                                                after: first.receipt.payload.generation, at: now), now: now, calendar: calendar)
        #expect(delayed.receipt.payload.generation > first.receipt.payload.generation)
        let pending = try backend.snapshot(now: at(20, 30), calendar: calendar)
        #expect(pending.pendingReleases.first?.replacementSchedule?.apps == [game])
        #expect(pending.authority.effectiveRestrictions.flatMap(\.apps) == [game], "Still blocked at 8:30 PM today")
    }

    @Test func correctingAPermanentBlockKeepsItsApps() throws {
        let backend = try backend()
        let now = at(12)
        _ = try backend.apply(request([.add(DomainRestriction(owner: .permanent, policyID: "focus-mixed", title: "Mixed",
            domains: ["a.example"], startsAt: now, apps: [game]))], after: 0, at: now), now: now, calendar: calendar)
        let generation = try backend.snapshot(now: now, calendar: calendar).generation
        // Shield 1.1: a new block's correction waits the full removal wait (3 days).
        _ = try backend.apply(request([.correctRecentPermanent("focus-mixed", releaseAt: now.addingTimeInterval(259_260))],
                                      after: generation, at: now), now: now, calendar: calendar)
        let snapshot = try backend.snapshot(now: now, calendar: calendar)
        #expect(snapshot.committedRestrictions.first?.apps == [game])
        #expect(snapshot.authority.effectiveRestrictions.flatMap(\.apps) == [game])
    }

    @Test func choosingAnAppReadsItsSignatureAndRefusesProtectedApps() {
        guard case .success(let chess) = AppTarget.chosen(at: URL(fileURLWithPath: "/System/Applications/Chess.app")) else {
            Issue.record("Chess should be blockable")
            return
        }
        #expect(chess.bundleID == "com.apple.Chess")
        #expect(chess.displayName == "Chess")
        #expect(AppTarget.chosen(at: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")) == .failure(.essential))
        #expect(AppTarget.chosen(at: URL(fileURLWithPath: "/System/Applications/System Settings.app")) == .failure(.essential))
        #expect(AppTarget.chosen(at: URL(fileURLWithPath: "/Applications/Safari.app")) == .failure(.browser))
        #expect(AppTarget.chosen(at: URL(fileURLWithPath: "/nonexistent/Nothing.app")) == .failure(.unreadable))
    }

    // Real signals, aimed only at a child process this test started.
    @Test func theEnforcerClosesARunningBlockedProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let pid = child.processIdentifier
        let identity = try #require(ProcessScanner.identity(of: pid))
        #expect(identity.bundleID == "com.apple.sleep")
        let target = AppTarget(displayName: "sleep", bundleID: "com.apple.sleep", teamID: nil)
        let enforcer = AppEnforcer(scanner: ProcessScanner(ownerUID: getuid(), onlyPIDs: [pid]))
        let result = enforcer.enforce([target])
        #expect(result.enforced == [target.id])
        #expect(result.actions == [.askToQuit(pid: pid, targetID: target.id)])
        child.waitUntilExit()
        #expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM)
    }

    @Test func theEnforcerForcesAfterTheGracePeriodAndIgnoresUnblockedApps() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let pid = child.processIdentifier
        let sent = SignalLog()
        let enforcer = AppEnforcer(scanner: ProcessScanner(ownerUID: getuid(), onlyPIDs: [pid]),
                                   signal: { pid, signal in sent.append(pid, signal); return 0 })
        let target = AppTarget(displayName: "sleep", bundleID: "com.apple.sleep", teamID: nil)
        let other = AppTarget(displayName: "Other", bundleID: "com.example.other", teamID: "TEAM000001")
        let start = Date()
        #expect(enforcer.enforce([other], now: start).actions.isEmpty)
        enforcer.enforce([target], now: start)
        enforcer.enforce([target], now: start.addingTimeInterval(30))
        enforcer.enforce([target], now: start.addingTimeInterval(AppSweep.grace + 1))
        #expect(sent.entries == [[pid, SIGTERM], [pid, SIGKILL]])
        #expect(enforcer.enforce([], now: start.addingTimeInterval(120)).actions.isEmpty)
    }
}

private final class SignalLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [[Int32]] = []
    func append(_ pid: Int32, _ signal: Int32) { lock.withLock { log.append([pid, signal]) } }
    var entries: [[Int32]] { lock.withLock { log } }
}
