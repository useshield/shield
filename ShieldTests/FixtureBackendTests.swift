import Foundation
import Testing
@testable import Shield

struct FixtureBackendTests {
    @MainActor
    @Test func singleScheduleApplyCommitsOnlyAfterServiceAckAndRejectsStaleRequest() throws {
        let root = try backendDirectory()
        let backend = try FixtureBackend(root: root)
        let now = Date()
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: now, commands: [.add(DomainRestriction(
                owner: .permanent, policyID: "seed", title: "Seed",
                domains: ["seed.example"]))]), now: now, calendar: .current)
        let model = ShieldViewModel(studyLibraryRoot: root.appendingPathComponent("study"), fixtureBackend: backend)
        model.refresh(now: now)
        // Name the backend's own error if the snapshot is missing (it once was,
        // intermittently, in a full parallel run).
        #expect(model.backendSnapshot != nil, "Refresh failed: \(model.fixtureReceiptError ?? "no error recorded")")
        // YouTube is allowed 6–8 PM; the stored hours are the blocked complement.
        let allowed = try #require(AllowedAccessWindow(startMinutes: 18 * 60, endMinutes: 20 * 60))
        let added = try #require(model.addSchedule(name: "YouTube", domains: ["youtube.com", "www.youtube.com", "youtu.be"],
                                                   allowed: allowed, categoryID: "video", now: now))
        let schedule = try #require(model.backendSnapshot?.committedSchedules.first {
            $0.domains == ["youtube.com", "www.youtube.com", "youtu.be"]
        }, "Apply: \(model.backendActionMessage ?? "") \(model.fixtureReceiptError ?? "")")
        #expect((schedule.startMinutes, schedule.endMinutes) == (1_200, 1_080))
        #expect(model.submissionState == .confirmed(added))
        #expect(model.pendingSubmission == nil)

        // Another signed operation advances the authority before our next
        // request. The stale request must be rejected and change nothing.
        let generation = try #require(model.backendSnapshot?.generation)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(),
            expectedGeneration: generation, submittedAt: now,
            commands: [.add(DomainRestriction(owner: .permanent,
                policyID: "other", title: "Other", domains: ["other.example"]))]),
            now: now, calendar: .current)
        let stale = try #require(model.removeSchedule(schedule.id, now: now))
        #expect(model.backendActionMessage?.contains("rejected") == true)
        #expect(model.submissionState == .failed(stale))
        let after = try backend.snapshot(now: now, calendar: .current)
        #expect(after.committedSchedules.contains(schedule))
        #expect(after.pendingReleases.isEmpty)
    }

    @Test func delayedScheduleReplacementSurvivesCrashesAcrossDSTAndPreservesOverlap() throws {
        let root = try backendDirectory()
        let backend = try FixtureBackend(root: root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 1)))
        let due = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 3)))
        let original = DailySchedule(id: "night", title: "Night", domains: ["shared.example", "old.example"],
                                     startMinutes: 1_200, endMinutes: 480, isRequested: true)
        let replacement = DailySchedule(id: "night", title: "Night", domains: ["shared.example", "new.example"],
                                        startMinutes: 1_320, endMinutes: 360, isRequested: true)
        let permanent = DomainRestriction(owner: .permanent, policyID: "permanent", title: "Permanent",
                                          domains: ["shared.example"])
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: now, commands: [.add(original), .add(permanent)]), now: now, calendar: calendar)
        #expect(throws: FixtureBackendError.self) {
            _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 1,
                submittedAt: now, commands: [.replace(replacement, at: now.addingTimeInterval(3_600))]),
                now: now, calendar: calendar)
        }
        let interrupted = try FixtureBackend(root: root, fault: .afterJournal)
        #expect(throws: FixtureBackendError.self) {
            _ = try interrupted.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 1,
                submittedAt: now, commands: [.replace(replacement, at: due)]), now: now, calendar: calendar)
        }
        _ = try backend.recover(now: now, calendar: calendar)
        let pending = try backend.snapshot(now: now, calendar: calendar)
        #expect(pending.committedSchedules == [original])
        #expect(pending.pendingReleases.first?.replacementSchedule == replacement)
        #expect(pending.enforcement.blockedDomains.contains("old.example"))
        let before = due.addingTimeInterval(-1)
        _ = try backend.tick(now: before, calendar: calendar)
        #expect(try backend.snapshot(now: before, calendar: calendar).committedSchedules == [original])
        let crashAtDue = try FixtureBackend(root: root, fault: .afterHosts)
        #expect(throws: FixtureBackendError.self) { try crashAtDue.tick(now: due, calendar: calendar) }
        _ = try backend.recover(now: due, calendar: calendar)
        let final = try backend.snapshot(now: due, calendar: calendar)
        #expect(final.committedSchedules == [replacement])
        #expect(final.pendingReleases.isEmpty)
        #expect(final.enforcement.blockedDomains == ["shared.example", "new.example"])
        #expect(final.committedRestrictions.contains { $0.policyID == "permanent" })
        #expect(try backend.verifiedReceipt().payload.generation == final.generation)
    }

    @Test func anonymousXPCDispatchesRealFixtureCommitAndSnapshot() throws {
        let root = try backendDirectory()
        let backend = try FixtureBackend(root: root)
        let service = try FixtureBackendXPCService(backend: backend, peerPolicy: .currentProcessForTests)
        service.resume()
        defer { service.invalidate() }
        let connection = NSXPCConnection(listenerEndpoint: service.endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: FixtureBackendXPCWire.self)
        connection.resume()
        defer { connection.invalidate() }
        let remote = try #require(connection.remoteObjectProxyWithErrorHandler({ _ in })
            as? FixtureBackendXPCWire)
        let request = BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: .now, commands: [.add(DomainRestriction(owner: .permanent,
                policyID: "xpc", title: "XPC fixture", domains: ["xpc.example"]))])
        let committed = DispatchSemaphore(value: 0)
        var ackBytes: Data?
        remote.submit(try JSONEncoder().encode(request) as NSData) { data, _ in
            ackBytes = data as Data?
            committed.signal()
        }
        #expect(committed.wait(timeout: .now() + 10) == .success)
        let ack = try JSONDecoder().decode(BackendAcknowledgment.self, from: #require(ackBytes))
        #expect(ack.status == .applied)
        let received = DispatchSemaphore(value: 0)
        var snapshotBytes: Data?
        remote.snapshot { data, _ in
            snapshotBytes = data as Data?
            received.signal()
        }
        #expect(received.wait(timeout: .now() + 10) == .success)
        let snapshot = try JSONDecoder().decode(FixtureSnapshotEnvelope.self, from: #require(snapshotBytes))
        #expect(snapshot.generation == ack.receipt.payload.generation)
        #expect(snapshot.restrictions.map(\.policyID) == ["xpc"])
        let rejected = DispatchSemaphore(value: 0)
        var rejection: String?
        var unexpectedReply = false
        remote.submit(Data(repeating: 0, count: StateFileLimits.maximumBytes + 1) as NSData) { data, error in
            unexpectedReply = data != nil
            rejection = error as String?
            rejected.signal()
        }
        #expect(rejected.wait(timeout: .now() + 10) == .success)
        #expect(!unexpectedReply)
        #expect(rejection?.contains("too large") == true)
        #expect(try backend.snapshot(now: .now, calendar: .current).generation == snapshot.generation)
    }

    @Test func duplicateRequestIDRequiresSameContentAfterRestart() throws {
        let root = try backendDirectory()
        let backend = try FixtureBackend(root: root)
        let now = Date()
        let id = UUID()
        let rule = DomainRestriction(owner: .permanent, policyID: "hard",
                                     title: "Hard", domains: ["hard.example"])
        let request = BackendRequest(version: 1, id: id, expectedGeneration: 0,
                                     submittedAt: now, commands: [.add(rule)])
        let first = try backend.apply(request, now: now, calendar: .current)
        let reopened = try FixtureBackend(root: root)
        let repeatAck = try reopened.apply(request, now: now, calendar: .current)
        #expect(repeatAck.status == .alreadyApplied)
        #expect(repeatAck.receipt == first.receipt)
        let changed = BackendRequest(version: 1, id: id, expectedGeneration: 0,
                                     submittedAt: now, commands: [.add(DomainRestriction(
                                        owner: .permanent, policyID: "other", title: "Other",
                                        domains: ["other.example"]))])
        #expect(throws: FixtureBackendError.self) {
            _ = try reopened.apply(changed, now: now, calendar: .current)
        }
        #expect(try reopened.snapshot(now: now, calendar: .current).generation == 1)
    }

    @MainActor
    @Test func activeCommittedVideoBlockStopsStudyFetchWithoutPolicyMutation() throws {
        let root = try backendDirectory()
        let backend = try FixtureBackend(root: root)
        let now = Date()
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: now, commands: [.add(DomainRestriction(owner: .permanent,
                policyID: "video-block", title: "Video block", domains: ["youtube.com"]))]),
            now: now, calendar: .current)
        let model = ShieldViewModel(authorityReader: AuthorityStateReader(fileURL: backend.paths.authority),
            enforcementReader: HostsEnforcementReader(fileURL: backend.paths.hosts),
            studyLibraryRoot: root.appendingPathComponent("study"), fixtureBackend: backend)
        model.refresh(now: now)
        #expect(model.studyFetchBlockReason?.contains("blocks YouTube") == true)
        #expect(try backend.snapshot(now: now, calendar: .current).generation == 1)
    }

    @MainActor
    @Test func invalidReceiptRemovesDisplayedAuthorityInsteadOfTrustingReadableFile() throws {
        let root = try backendDirectory()
        let backend = try FixtureBackend(root: root)
        let now = Date()
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: now, commands: [.add(DomainRestriction(owner: .permanent,
                policyID: "trusted", title: "Trusted", domains: ["trusted.example"]))]),
            now: now, calendar: .current)
        let model = ShieldViewModel(authorityReader: AuthorityStateReader(fileURL: backend.paths.authority),
            enforcementReader: HostsEnforcementReader(fileURL: backend.paths.hosts),
            studyLibraryRoot: root.appendingPathComponent("study"), fixtureBackend: backend)
        model.refresh(now: now)
        #expect(model.authorityState != nil)
        try Data("invalid receipt".utf8).write(to: backend.paths.receipt)
        guard case .valid = AuthorityStateReader(fileURL: backend.paths.authority).read(now: now) else {
            Issue.record("The unsigned authority file must still be readable for this negative case.")
            return
        }
        model.refresh(now: now)
        #expect(model.backendSnapshot == nil)
        #expect(model.fixtureReceipt == nil)
        #expect(model.authorityState == nil)
        #expect(model.authorityError != nil)
        #expect(model.studyFetchBlockReason?.contains("authority is unavailable") == true)
    }

    @Test func scheduleBoundaryReconcilesBeforePeriodicRefresh() throws {
        let root = try backendDirectory()
        let backend = try FixtureBackend(root: root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_760_528_800))
        let start = day.addingTimeInterval(19 * 3_600 + 59 * 60 + 30)
        let schedule = DailySchedule(id: "minute", title: "One minute",
                                     domains: ["shared.example"], startMinutes: 1_200,
                                     endMinutes: 1_201, isRequested: true)
        let permanent = DomainRestriction(owner: .permanent, policyID: "hard", title: "Hard",
                                          domains: ["shared.example"])
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
                                             submittedAt: start, commands: [.add(permanent), .add(schedule)]),
                              now: start, calendar: calendar)
        #expect(try backend.tick(now: start.addingTimeInterval(10), calendar: calendar).status == .unchanged)
        let transition = try backend.tick(now: start.addingTimeInterval(30), calendar: calendar)
        #expect(transition.receipt.payload.generation == 2)
        let active = try backend.snapshot(now: start.addingTimeInterval(30), calendar: calendar)
        #expect(active.authority.effectiveRestrictions.contains { $0.policyID == "minute" })
        #expect(active.authority.effectiveRestrictions.contains { $0.policyID == "hard" })
    }

    @MainActor
    @Test func viewModelSubmitsFixtureCommitmentAndReportsAcknowledgment() throws {
        let root = try backendDirectory()
        let backend = try FixtureBackend(root: root)
        let now = Date()
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
                                             submittedAt: now, commands: [.add(DomainRestriction(
                                                owner: .permanent, policyID: "hard", title: "Hard",
                                                domains: ["hard.example"]))]),
                              now: now, calendar: .current)
        let model = ShieldViewModel(authorityReader: AuthorityStateReader(fileURL: backend.paths.authority),
                                    enforcementReader: HostsEnforcementReader(fileURL: backend.paths.hosts),
                                    studyLibraryRoot: root.appendingPathComponent("study"),
                                    fixtureBackend: backend)
        model.refresh(now: now)
        #expect(model.backendSnapshot?.generation == 1)
        model.commitFixtureFocus(now: now)
        #expect(model.backendSnapshot?.generation == 2)
        #expect(model.backendSnapshot?.committedRestrictions.count == 2)
        if case .confirmed = model.submissionState {} else { Issue.record("Expected a confirmed fixture request") }
        // Two X / Reddit schedules; stored hours are the BLOCKED complement.
        let morning = try #require(AllowedAccessWindow(startMinutes: 780, endMinutes: 420))
        let night = try #require(AllowedAccessWindow(startMinutes: 480, endMinutes: 1_200))
        let domains: Set<String> = ["x.com", "twitter.com", "reddit.com", "www.reddit.com"]
        _ = model.addSchedule(name: "X / Reddit Focus", domains: domains, allowed: morning, categoryID: "social", now: now)
        #expect(model.backendSnapshot?.generation == 3)
        _ = model.addSchedule(name: "X / Reddit Night", domains: domains, allowed: night, categoryID: "social", now: now)
        #expect(model.backendSnapshot?.generation == 4)
        #expect(model.backendSnapshot?.committedSchedules.count == 2)
        #expect(model.diagnosticReport.contains("pending=0"))
        let focus = try #require(model.backendSnapshot?.committedSchedules.first { $0.title == "X / Reddit Focus" })
        #expect((focus.startMinutes, focus.endMinutes) == (420, 780))
        model.requestFixtureRelease(policyID: focus.id, now: now)
        #expect(model.backendSnapshot?.pendingReleases.map(\.policyID) == [focus.id])
        #expect((model.backendSnapshot?.pendingReleases.first?.effectiveAt
            .timeIntervalSince(now) ?? 0) > 86_400)
        #expect(model.backendSnapshot?.committedSchedules.count == 2)
    }

    @Test func releaseDelayUsesServiceReceiveTimeAndKeepsAuthorityUntilDue() throws {
        let root = try backendDirectory()
        let backend = try FixtureBackend(root: root)
        let submitted = Date()
        let rule = DomainRestriction(owner: .commitment, policyID: "fixed",
                                     title: "Fixed commitment", domains: ["fixed.example"])
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: submitted, commands: [.add(rule)]), now: submitted, calendar: .current)
        let received = submitted.addingTimeInterval(2)
        let tooEarly = BackendRequest(version: 1, id: UUID(), expectedGeneration: 1,
            submittedAt: submitted, commands: [.release("fixed", at:
                submitted.addingTimeInterval(86_400))])
        #expect(throws: FixtureBackendError.self) {
            _ = try backend.apply(tooEarly, now: received, calendar: .current)
        }
        #expect(try backend.snapshot(now: received, calendar: .current).generation == 1)
        let due = submitted.addingTimeInterval(86_460)
        let valid = BackendRequest(version: 1, id: UUID(), expectedGeneration: 1,
            submittedAt: submitted, commands: [.release("fixed", at: due)])
        _ = try backend.apply(valid, now: received, calendar: .current)
        let pending = try backend.snapshot(now: received, calendar: .current)
        #expect(pending.pendingReleases.map(\.policyID) == ["fixed"])
        #expect(pending.authority.effectiveRestrictions.contains { $0.policyID == "fixed" })
        _ = try backend.tick(now: due.addingTimeInterval(-1), calendar: .current)
        #expect(try backend.snapshot(now: due.addingTimeInterval(-1), calendar: .current)
            .committedRestrictions.contains { $0.policyID == "fixed" })
        _ = try backend.tick(now: due, calendar: .current)
        let released = try backend.snapshot(now: due, calendar: .current)
        #expect(released.pendingReleases.isEmpty)
        #expect(released.committedRestrictions.isEmpty)
        #expect(released.authority.effectiveRestrictions.isEmpty)
    }

    @Test func recurringWindowStrengthensImmediatelyButCannotShrinkByUpdate() throws {
        let root = try backendDirectory()
        let backend = try FixtureBackend(root: root)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 10, day: 15, hour: 9, minute: 0)))
        let permanent = DomainRestriction(owner: .permanent, policyID: "overlap",
            title: "Permanent overlap", domains: ["shared.example"])
        let original = DailySchedule(id: "morning", title: "Morning",
            domains: ["shared.example", "morning.example"], startMinutes: 420,
            endMinutes: 780, isRequested: true)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: now, commands: [.add(permanent), .add(original)]),
            now: now, calendar: calendar)
        let stronger = DailySchedule(id: "morning", title: "Longer morning",
            domains: original.domains, startMinutes: 360, endMinutes: 840,
            isRequested: true)
        #expect(stronger.isImmediateStrengthening(of: original))
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 1,
            submittedAt: now, commands: [.strengthen(stronger)]), now: now, calendar: calendar)
        let active = try backend.snapshot(now: now, calendar: calendar)
        #expect(active.committedSchedules == [stronger])
        #expect(active.authority.effectiveRestrictions.contains { $0.policyID == "morning" })
        let weaker = DailySchedule(id: "morning", title: "Shorter morning",
            domains: original.domains, startMinutes: 480, endMinutes: 720,
            isRequested: true)
        #expect(!weaker.isImmediateStrengthening(of: stronger))
        #expect(throws: FixtureBackendError.self) {
            _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 2,
                submittedAt: now, commands: [.strengthen(weaker)]), now: now, calendar: calendar)
        }
        #expect(try backend.snapshot(now: now, calendar: calendar).generation == 2)
        let due = now.addingTimeInterval(86_460)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 2,
            submittedAt: now, commands: [.release("morning", at: due)]),
            now: now, calendar: calendar)
        let pending = try backend.snapshot(now: now, calendar: calendar)
        #expect(pending.pendingReleases.map(\.policyID) == ["morning"])
        _ = try backend.tick(now: due, calendar: calendar)
        let settled = try backend.snapshot(now: due, calendar: calendar)
        #expect(settled.committedSchedules.isEmpty)
        #expect(settled.authority.effectiveRestrictions.contains { $0.policyID == "overlap" })
    }

    @MainActor
    @Test func scheduleApplyStrengthensImmediatelyAndQueuesWeakerHours() throws {
        let root = try backendDirectory()
        let backend = try FixtureBackend(root: root)
        let now = Date()
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: now, commands: [.add(DomainRestriction(owner: .permanent,
                policyID: "seed", title: "Seed", domains: ["seed.example"]))]),
            now: now, calendar: .current)
        let model = ShieldViewModel(
            studyLibraryRoot: root.appendingPathComponent("study"), fixtureBackend: backend)
        model.refresh(now: now)
        // Stored hours are the BLOCKED complement: Focus blocks 7 AM–1 PM,
        // Night blocks 8 PM–8 AM.
        let domains: Set<String> = ["x.com", "twitter.com", "reddit.com", "www.reddit.com"]
        _ = model.addSchedule(name: "X / Reddit Focus", domains: domains,
                              allowed: try #require(AllowedAccessWindow(startMinutes: 780, endMinutes: 420)),
                              categoryID: "social", now: now)
        _ = model.addSchedule(name: "X / Reddit Night", domains: domains,
                              allowed: try #require(AllowedAccessWindow(startMinutes: 480, endMinutes: 1_200)),
                              categoryID: "social", now: now)
        #expect(model.backendSnapshot?.committedSchedules.count == 2)
        let focus = try #require(model.backendSnapshot?.committedSchedules.first { $0.title == "X / Reddit Focus" })
        #expect((focus.startMinutes, focus.endMinutes) == (420, 780))

        // Blocking from 6 AM instead of 7 AM is stricter: it applies at once.
        model.changeConfirmedHours(scheduleID: focus.id, start: 360, end: 780, now: now)
        #expect(model.backendSnapshot?.committedSchedules.first(where: {
            $0.id == focus.id
        })?.startMinutes == 360)
        let committedGeneration = try #require(model.backendSnapshot?.generation)

        // Blocking only from 8 AM is looser: it waits at least 24 hours.
        model.changeConfirmedHours(scheduleID: focus.id, start: 480, end: 780, now: now)
        #expect(model.backendSnapshot?.generation == committedGeneration + 1)
        #expect(model.backendSnapshot?.committedSchedules.first(where: { $0.id == focus.id })?.startMinutes == 360)
        #expect(model.backendSnapshot?.pendingReleases.first(where: { $0.policyID == focus.id })?.replacementSchedule?.startMinutes == 480)
        #expect((model.backendSnapshot?.pendingReleases.first?.effectiveAt.timeIntervalSince(now) ?? 0) > 86_400)
    }

    @MainActor
    @Test func developmentServiceViewRejectsOlderGeneration() throws {
        let root = try backendDirectory()
        let backend = try FixtureBackend(root: root)
        let now = Date()
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: now, commands: [.add(DomainRestriction(owner: .permanent,
                policyID: "first", title: "First", domains: ["first.example"]))]),
            now: now, calendar: .current)
        let first = try backend.snapshot(now: now, calendar: .current)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 1,
            submittedAt: now, commands: [.add(DomainRestriction(owner: .temporary,
                policyID: "second", title: "Second", domains: ["second.example"],
                endsAt: now.addingTimeInterval(3_600)))]), now: now, calendar: .current)
        let second = try backend.snapshot(now: now, calendar: .current)
        let model = ShieldViewModel(xpcClient: FixtureBackendXPCClient(serviceName: "test.unused"))
        try model.acceptBackendSnapshot(second, now: now)
        #expect(model.authorityState?.generation == 2)
        #expect(throws: FixtureBackendError.self) {
            try model.acceptBackendSnapshot(first, now: now)
        }
        #expect(model.authorityState == nil)
        #expect(model.fixtureReceipt == nil)
        // Clearing an invalid snapshot must not erase the last trusted generation.
        #expect(throws: FixtureBackendError.self) { try model.acceptBackendSnapshot(first, now: now) }
    }

    @Test func snapshotReportsCommittedOwnersAndPendingWeakening() throws {
        let root = try backendDirectory()
        let backend = try FixtureBackend(root: root)
        let now = Date()
        let rule = DomainRestriction(owner: .commitment, policyID: "study", title: "Study",
                                     domains: ["study.example"])
        let schedule = DailySchedule(id: "night", title: "Night", domains: ["study.example"],
                                     startMinutes: 1200, endMinutes: 480, isRequested: true)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
                                             submittedAt: now, commands: [.add(rule), .add(schedule)]),
                              now: now, calendar: .current)
        let initial = try backend.snapshot(now: now, calendar: .current)
        #expect(initial.generation == 1)
        #expect(initial.committedRestrictions.map(\.policyID) == ["study"])
        #expect(initial.committedSchedules.map(\.id) == ["night"])
        #expect(initial.pendingReleases.isEmpty)
        let release = now.addingTimeInterval(86_400)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 1,
                                             submittedAt: now, commands: [.release("study", at: release)]),
                              now: now, calendar: .current)
        let pending = try backend.snapshot(now: now, calendar: .current)
        #expect(pending.generation == 2)
        #expect(pending.pendingReleases.map(\.policyID) == ["study"])
        #expect(pending.authority.effectiveRestrictions.contains { $0.policyID == "study" })
        #expect(pending.receipt.payload.generation == pending.generation)
        _ = try backend.tick(now: release, calendar: .current)
        let settled = try backend.snapshot(now: release, calendar: .current)
        #expect(settled.pendingReleases.isEmpty)
        #expect(settled.committedRestrictions.isEmpty)
        #expect(settled.committedSchedules.count == 1)
    }

    @Test func lifecyclePreservesOwnersAcrossDaysAndRestart() throws {
        let root = try backendDirectory()
        let backend = try FixtureBackend(root: root)
        let now = Date(timeIntervalSince1970: 1_760_528_800)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let permanent = DomainRestriction(owner: .permanent, policyID: "hard",
                                          title: "Hard block", domains: ["shared.example"])
        let temporary = DomainRestriction(owner: .temporary, policyID: "october-fixture",
                                          title: "October regression", domains: ["shared.example", "temp.example"],
                                          startsAt: now, endsAt: now.addingTimeInterval(7_200))
        let commitment = DomainRestriction(owner: .commitment, policyID: "study",
                                           title: "Study commitment", domains: ["study.example"])
        let schedule = DailySchedule(id: "overnight", title: "Overnight", domains: ["night.example"],
                                     startMinutes: 1_200, endMinutes: 480, isRequested: true)
        let bootstrap = BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
                                       submittedAt: now, commands: [
                                        .add(permanent), .add(temporary), .add(commitment), .add(schedule)
                                       ])
        let first = try backend.apply(bootstrap, now: now, calendar: calendar)
        #expect(first.receipt.payload.generation == 1)
        #expect(try backend.apply(bootstrap, now: now, calendar: calendar).status == .alreadyApplied)
        #expect(try authority(at: root, now: now).effectiveRestrictions
            .flatMap(\.domains).contains("temp.example"))

        let releaseAt = now.addingTimeInterval(90_000)
        let release = BackendRequest(version: 1, id: UUID(), expectedGeneration: 1,
                                     submittedAt: now, commands: [.release("study", at: releaseAt)])
        let second = try backend.apply(release, now: now, calendar: calendar)
        #expect(second.receipt.payload.generation == 2)
        #expect(second.nextTransition != nil)

        let restarted = try FixtureBackend(root: root)
        _ = try restarted.tick(now: now.addingTimeInterval(10_800), calendar: calendar)
        let afterExpiry = try authority(at: root, now: now.addingTimeInterval(10_800))
        let afterExpiryDomains = Set(afterExpiry.effectiveRestrictions.flatMap(\.domains))
        #expect(afterExpiryDomains.contains("shared.example"))
        #expect(afterExpiryDomains.contains("study.example"))
        #expect(!afterExpiryDomains.contains("temp.example"))
        _ = try restarted.tick(now: now.addingTimeInterval(93_600), calendar: calendar)
        let afterRelease = try authority(at: root, now: now.addingTimeInterval(93_600))
        let afterReleaseDomains = Set(afterRelease.effectiveRestrictions.flatMap(\.domains))
        #expect(afterReleaseDomains.contains("shared.example"))
        #expect(!afterReleaseDomains.contains("study.example"))
        #expect(try restarted.verifiedReceipt().payload.generation == afterRelease.generation)
    }

    @Test func interruptedJournalReplaysWithoutWeakening() throws {
        let root = try backendDirectory()
        let now = Date()
        let rule = DomainRestriction(owner: .permanent, policyID: "hard", title: "Hard",
                                     domains: ["hard.example"])
        let request = BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
                                     submittedAt: now, commands: [.add(rule)])
        let interrupted = try FixtureBackend(root: root, fault: .afterJournal)
        #expect(throws: FixtureBackendError.self) {
            try interrupted.apply(request, now: now, calendar: .current)
        }
        #expect(FileManager.default.fileExists(atPath: interrupted.paths.journal.path))
        let restored = try FixtureBackend(root: root)
        let ack = try restored.recover(now: now, calendar: .current)
        #expect(ack.status == .recovered)
        #expect(try restored.verifiedReceipt().payload.generation == 1)
        #expect(try String(contentsOf: restored.paths.hosts, encoding: .utf8).contains("hard.example"))
        #expect(!FileManager.default.fileExists(atPath: restored.paths.journal.path))
    }

    @Test func staleSignedJournalCannotRollBackNewerGeneration() throws {
        let root = try backendDirectory()
        let now = Date()
        let first = BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: now, commands: [.add(DomainRestriction(owner: .permanent,
                policyID: "first", title: "First", domains: ["first.example"]))])
        let interrupted = try FixtureBackend(root: root, fault: .afterJournal)
        #expect(throws: FixtureBackendError.self) {
            try interrupted.apply(first, now: now, calendar: .current)
        }
        let staleJournal = try Data(contentsOf: interrupted.paths.journal)
        let backend = try FixtureBackend(root: root)
        _ = try backend.recover(now: now, calendar: .current)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 1,
            submittedAt: now, commands: [.add(DomainRestriction(owner: .commitment,
                policyID: "second", title: "Second", domains: ["second.example"]))]),
            now: now, calendar: .current)
        try staleJournal.write(to: backend.paths.journal)
        #expect(throws: FixtureBackendError.self) {
            try backend.recover(now: now, calendar: .current)
        }
        #expect(try backend.verifiedReceipt().payload.generation == 2)
        #expect(try String(contentsOf: backend.paths.hosts, encoding: .utf8).contains("second.example"))
    }

    @Test func corruptAuthorityAndReceiptStopRequests() throws {
        let root = try backendDirectory()
        let now = Date()
        let backend = try FixtureBackend(root: root)
        let rule = DomainRestriction(owner: .permanent, policyID: "hard", title: "Hard",
                                     domains: ["hard.example"])
        let request = BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
                                     submittedAt: now, commands: [.add(rule)])
        _ = try backend.apply(request, now: now, calendar: .current)
        let hostsBefore = try Data(contentsOf: backend.paths.hosts)
        try Data().write(to: backend.paths.authority)
        let next = BackendRequest(version: 1, id: UUID(), expectedGeneration: 1,
                                  submittedAt: now, commands: [.release("hard", at: now.addingTimeInterval(90_000))])
        #expect(throws: FixtureBackendError.self) {
            try backend.apply(next, now: now, calendar: .current)
        }
        #expect(try Data(contentsOf: backend.paths.hosts) == hostsBefore)
        #expect(throws: FixtureBackendError.self) { try backend.verifiedReceipt() }
    }

    @Test func permanentReleaseAndGenerationRollbackAreRejected() throws {
        let root = try backendDirectory()
        let now = Date()
        let backend = try FixtureBackend(root: root)
        let rule = DomainRestriction(owner: .permanent, policyID: "hard", title: "Hard",
                                     domains: ["hard.example"])
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
                                             submittedAt: now, commands: [.add(rule)]),
                              now: now, calendar: .current)
        let release = BackendRequest(version: 1, id: UUID(), expectedGeneration: 1,
                                     submittedAt: now, commands: [.release("hard", at: now.addingTimeInterval(90_000))])
        #expect(throws: FixtureBackendError.self) { try backend.apply(release, now: now, calendar: .current) }
        let rollback = BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
                                      submittedAt: now, commands: [.add(DomainRestriction(
                                        owner: .temporary, policyID: "new", title: "New",
                                        domains: ["new.example"], endsAt: now.addingTimeInterval(3_600)))])
        #expect(throws: FixtureBackendError.self) { try backend.apply(rollback, now: now, calendar: .current) }
    }

    /// Blocks made before Shield 1.1 keep the 24-hour Fix a Mistake.
    @Test func recentNewBlockPermanentCanBeCorrectedWithTwentyFourHourDelay() throws {
        let root = try backendDirectory()
        let created = Date()
        var backend = try FixtureBackend(root: root)
        backend.writesPreRemovalDocuments = true
        let mistake = DomainRestriction(owner: .permanent, policyID: "focus-mistake", title: "Social feeds",
                                        domains: ["x.com", "reddit.com", "tumblr.com"], startsAt: created)
        let plan = DomainRestriction(owner: .permanent, policyID: "owner-plan-adult-1", title: "Adult",
                                     domains: ["adult.example"], startsAt: created)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: created, commands: [.add(mistake), .add(plan)]), now: created, calendar: .current)
        let now = created.addingTimeInterval(3_600)
        // An immediate undo with unscheduled sites, a plan owner and a missing rule are refused.
        for command in [BackendCommand.correctRecentPermanent("focus-mistake", releaseAt: now.addingTimeInterval(86_399)),
                        .correctRecentPermanent("owner-plan-adult-1", releaseAt: now.addingTimeInterval(90_000)),
                        .correctRecentPermanent("missing", releaseAt: now.addingTimeInterval(90_000))] {
            #expect(throws: FixtureBackendError.self) {
                _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 1,
                    submittedAt: now, commands: [command]), now: now, calendar: .current)
            }
        }
        // Keep Tumblr permanently (immediately) and release the rest after the delay.
        let kept = DomainRestriction(owner: .permanent, policyID: "focus-kept", title: "Tumblr",
                                     domains: ["tumblr.com"], startsAt: now)
        let due = now.addingTimeInterval(86_460)
        let request = BackendRequest(version: 1, id: UUID(), expectedGeneration: 1, submittedAt: now,
            commands: [.add(kept), .correctRecentPermanent("focus-mistake", releaseAt: due)])
        _ = try backend.apply(request, now: now, calendar: .current)
        let corrected = try backend.snapshot(now: now, calendar: .current)
        #expect(corrected.committedRestrictions.first { $0.policyID == "focus-mistake" }?.owner == .commitment)
        #expect(corrected.pendingReleases.map(\.policyID) == ["focus-mistake"])
        #expect(corrected.authority.effectiveRestrictions.contains { $0.policyID == "focus-mistake" },
                "Blocking must not change before the release is due.")
        #expect(PendingPolicySubmission(version: 1, request: request, schedulePreferences: nil)
            .isConfirmed(by: corrected))
        _ = try backend.tick(now: due, calendar: .current)
        let released = try backend.snapshot(now: due, calendar: .current)
        #expect(Set(released.committedRestrictions.map(\.policyID)) == ["owner-plan-adult-1", "focus-kept"])
        #expect(released.authority.effectiveRestrictions.contains { $0.domains.contains("tumblr.com") })
        #expect(!released.authority.effectiveRestrictions.contains { $0.domains.contains("x.com") })
    }

    /// Shield 1.1: a block made under 1.1 can't use Fix a Mistake to beat the
    /// removal wait. The correction waits as long as removal does.
    @Test func aOnePointOneBlockCorrectionWaitsTheFullRemovalWait() throws {
        let root = try backendDirectory()
        let created = Date()
        let backend = try FixtureBackend(root: root)
        let mistake = DomainRestriction(owner: .permanent, policyID: "focus-mistake", title: "Feeds",
                                        domains: ["x.com", "tumblr.com"], startsAt: created)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: created, commands: [.add(mistake)]), now: created, calendar: .current)
        let now = created.addingTimeInterval(3_600)
        let wait = try #require(backend.snapshot(now: now, calendar: .current).permanentRemoval).currentWait(at: now)
        #expect(wait == 259_200)
        for early in [86_460.0, wait - 1] {
            #expect(throws: FixtureBackendError.self) {
                _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 1, submittedAt: now,
                    commands: [.correctRecentPermanent("focus-mistake", releaseAt: now.addingTimeInterval(early))]),
                    now: now, calendar: .current)
            }
        }
        let kept = DomainRestriction(owner: .permanent, policyID: "focus-kept", title: "Tumblr",
                                     domains: ["tumblr.com"], startsAt: created)
        let due = now.addingTimeInterval(wait + 60)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 1, submittedAt: now,
            commands: [.add(kept), .correctRecentPermanent("focus-mistake", releaseAt: due)]), now: now, calendar: .current)
        let corrected = try backend.snapshot(now: now, calendar: .current)
        #expect(corrected.pendingReleases.map(\.policyID) == ["focus-mistake"])
        #expect(corrected.pendingReleases.first?.effectiveAt == due)
        #expect(corrected.authority.effectiveRestrictions.contains { $0.domains.contains("x.com") })
    }

    @Test func correctionNeverUnblocksEarlyEvenWithDailyHours() throws {
        let root = try backendDirectory()
        let created = Date()
        let backend = try FixtureBackend(root: root)
        // A nearly always-allowed schedule (blocked one minute a day) must not
        // let a permanent block end at once.
        let hours = DailySchedule(id: "loose", title: "Loose", domains: ["x.com"],
                                  startMinutes: 0, endMinutes: 1, isRequested: true)
        let mistake = DomainRestriction(owner: .permanent, policyID: "focus-mistake", title: "x.com",
                                        domains: ["x.com"], startsAt: created)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: created, commands: [.add(hours), .add(mistake)]), now: created, calendar: .current)
        #expect(throws: FixtureBackendError.self) {
            _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 1, submittedAt: created,
                commands: [.correctRecentPermanent("focus-mistake", releaseAt: created)]), now: created, calendar: .current)
        }
        #expect(try backend.snapshot(now: created, calendar: .current).committedRestrictions
            .first { $0.policyID == "focus-mistake" }?.owner == .permanent)
    }

    @Test func cancellingACorrectionMakesTheBlockPermanentAgain() throws {
        let root = try backendDirectory()
        let created = Date()
        let backend = try FixtureBackend(root: root)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0, submittedAt: created,
            commands: [.add(DomainRestriction(owner: .permanent, policyID: "focus-mistake", title: "x.com",
                                              domains: ["x.com"], startsAt: created))]), now: created, calendar: .current)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 1, submittedAt: created,
            commands: [.correctRecentPermanent("focus-mistake", releaseAt: created.addingTimeInterval(259_260))]),
            now: created, calendar: .current)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 2, submittedAt: created,
            commands: [.cancelPending("focus-mistake")]), now: created, calendar: .current)
        let after = try backend.snapshot(now: created, calendar: .current)
        let rule = try #require(after.committedRestrictions.first { $0.policyID == "focus-mistake" })
        #expect(rule.owner == .permanent, "A cancelled correction must not leave a releasable block")
        #expect(rule.startsAt == created, "The original correction deadline is kept")
        #expect(after.pendingReleases.isEmpty)
        #expect(throws: FixtureBackendError.self) {
            _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 3, submittedAt: created,
                commands: [.release("focus-mistake", at: created.addingTimeInterval(90_000))]),
                now: created, calendar: .current)
        }
    }

    @Test func timedBlocksCannotBeReleasedByRequest() throws {
        let root = try backendDirectory()
        let now = Date()
        let backend = try FixtureBackend(root: root)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0, submittedAt: now,
            commands: [.add(DomainRestriction(owner: .commitment, policyID: "focus-timed", title: "a.example",
                domains: ["a.example"], startsAt: now, endsAt: now.addingTimeInterval(3_600)))]), now: now, calendar: .current)
        #expect(throws: FixtureBackendError.self) {
            _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 1, submittedAt: now,
                commands: [.release("focus-timed", at: now.addingTimeInterval(90_000))]), now: now, calendar: .current)
        }
    }

    @Test func permanentCorrectionClosesAfterSeventyTwoHours() throws {
        let root = try backendDirectory()
        let created = Date()
        let backend = try FixtureBackend(root: root)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: created, commands: [.add(DomainRestriction(owner: .permanent, policyID: "focus-old",
                title: "Old", domains: ["old.example"], startsAt: created))]), now: created, calendar: .current)
        let late = created.addingTimeInterval(DomainRestriction.permanentCorrectionWindow + 1)
        #expect(throws: FixtureBackendError.self) {
            _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 1, submittedAt: late,
                commands: [.correctRecentPermanent("focus-old", releaseAt: late.addingTimeInterval(90_000))]),
                now: late, calendar: .current)
        }
        // A permanent without a recorded start (every plan owner) is never correctable.
        #expect(!DomainRestriction(owner: .permanent, policyID: "focus-x", title: "X",
                                   domains: ["x.example"]).isCorrectablePermanent(at: created))
    }

    @Test func hostsInterruptionRecoversCommittedGeneration() throws {
        let root = try backendDirectory()
        let now = Date()
        let request = BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
                                     submittedAt: now, commands: [.add(DomainRestriction(
                                        owner: .permanent, policyID: "a", title: "A", domains: ["a.example"]))])
        #expect(throws: FixtureBackendError.self) {
            try FixtureBackend(root: root, fault: .afterHosts).apply(request, now: now, calendar: .current)
        }
        let backend = try FixtureBackend(root: root)
        #expect(try backend.recover(now: now, calendar: .current).status == .recovered)
        #expect(try backend.apply(request, now: now, calendar: .current).status == .alreadyApplied)
    }

    @Test func documentTamperingInvalidatesReceipt() throws {
        let root = try backendDirectory()
        let now = Date()
        let backend = try FixtureBackend(root: root)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
                                              submittedAt: now, commands: [.add(DomainRestriction(
                                                owner: .commitment, policyID: "c", title: "C",
                                                domains: ["c.example"]))]),
                              now: now, calendar: .current)
        var data = try Data(contentsOf: backend.paths.document)
        data[20] ^= 0x01
        try data.write(to: backend.paths.document)
        #expect(throws: FixtureBackendError.self) { try backend.verifiedReceipt() }
    }

    @Test func malformedAndOutOfDateRequestsFailBeforeMutation() throws {
        let root = try backendDirectory()
        let backend = try FixtureBackend(root: root)
        let now = Date()
        let invalid = BackendRequest(version: 2, id: UUID(), expectedGeneration: 0,
                                     submittedAt: now, commands: [.add(DomainRestriction(
                                        owner: .permanent, policyID: "a", title: "A", domains: ["bad domain"]))])
        #expect(throws: FixtureBackendError.self) { try backend.apply(invalid, now: now, calendar: .current) }
        #expect(!FileManager.default.fileExists(atPath: backend.paths.document.path))
        let stale = BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
                                   submittedAt: now.addingTimeInterval(-600), commands: invalid.commands)
        #expect(throws: FixtureBackendError.self) { try backend.apply(stale, now: now, calendar: .current) }
    }

    @Test func backendRejectsConcurrentWriterAndUnsafeRoot() throws {
        let root = try backendDirectory()
        let backend = try FixtureBackend(root: root)
        let now = Date()
        let request = BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
                                     submittedAt: now, commands: [.add(DomainRestriction(
                                        owner: .permanent, policyID: "a", title: "A", domains: ["a.example"]))])
        let lock = try ExclusiveFileLock(url: backend.paths.lock)
        #expect(throws: ReconciliationError.self) {
            try backend.apply(request, now: now, calendar: .current)
        }
        withExtendedLifetime(lock) {}
        #expect(throws: FixtureBackendError.self) {
            try FixtureBackend(root: URL(fileURLWithPath: "/etc"))
        }
    }

    @Test func bootstrapRefusesUnknownManagedHostsState() throws {
        let root = try backendDirectory()
        let hosts = root.appendingPathComponent("hosts")
        try Data("127.0.0.1 localhost\n# BEGIN KAIROS\n0.0.0.0 old.example\n# END KAIROS\n".utf8)
            .write(to: hosts)
        let now = Date()
        let request = BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
                                     submittedAt: now, commands: [.add(DomainRestriction(
                                        owner: .permanent, policyID: "new", title: "New",
                                        domains: ["new.example"]))])
        let backend = try FixtureBackend(root: root)
        #expect(throws: FixtureBackendError.self) {
            try backend.apply(request, now: now, calendar: .current)
        }
        #expect(try String(contentsOf: hosts, encoding: .utf8).contains("old.example"))
        #expect(!FileManager.default.fileExists(atPath: backend.paths.document.path))
    }
}

private func backendDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ShieldBackendTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
    return root
}

private func authority(at root: URL, now: Date) throws -> AuthorityState {
    let reader = AuthorityStateReader(fileURL: root.appendingPathComponent("authority.plist"),
                                      maximumAge: .infinity)
    guard case .valid(let state) = reader.read(now: now) else {
        throw FixtureBackendError.uncertain("Fixture authority is unavailable.")
    }
    return state
}
