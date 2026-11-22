import Foundation
import Testing
import Security
@testable import Shield

struct IntegrationRecoveryTests {
    @Test func installedAuthorityGuardRejectsExistingAndDanglingMarkersWithoutModifyingThem() throws {
        let root = try directory(seedHosts: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("authority")
        #expect(!StudyInstalledAuthorityGuard.detected(at: [marker]))
        try Data("preserve commitment".utf8).write(to: marker)
        #expect(StudyInstalledAuthorityGuard.detected(at: [marker]))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "preserve commitment")
        let alias = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("absent"))
        #expect(StudyInstalledAuthorityGuard.detected(at: [alias]))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path).hasSuffix("absent"))
    }

    private func directory(seedHosts: Bool = true) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldIntegration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        if seedHosts { try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts")) }
        return root
    }

    @MainActor
    @Test func danglingPendingIntentCannotBecomePermissionForANewCommitment() throws {
        let root = try directory(seedHosts: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        try backend.initializeEmptyAuthority(now: .now, calendar: .current)
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        let store = PolicySubmissionStore(root: library)
        #expect(try store.load() == nil)
        let target = library.appendingPathComponent("missing-intent")
        try FileManager.default.createSymbolicLink(at: store.file, withDestinationURL: target)
        #expect(throws: (any Error).self) { try store.load() }
        let model = ShieldViewModel(studyLibraryRoot: library, fixtureBackend: backend)
        model.start()
        defer { model.stop() }
        #expect(model.submissionRecordError != nil)
        #expect(!model.canSubmitPolicy)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: store.file.path) == target.path)
        #expect(try backend.snapshot(now: .now, calendar: .current).committedRestrictions.isEmpty)
    }

    @Test func lateExactRetryRecoversReceiptButOldNewMutationAndChangedReplayFail() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        let rule = DomainRestriction(owner: .permanent, policyID: "keep", title: "Keep", domains: ["example.invalid"])
        let request = BackendRequest(version: 1, id: UUID(), expectedGeneration: 0, submittedAt: now, commands: [.add(rule)])
        _ = try backend.apply(request, now: now, calendar: .current)
        let later = now.addingTimeInterval(3_600)
        let retry = try FixtureBackend(root: root).apply(request, now: later, calendar: .current)
        #expect(retry.status == .alreadyApplied)
        #expect(retry.receipt.payload.generation == 1)
        let different = BackendRequest(version: 1, id: request.id, expectedGeneration: 0,
            submittedAt: now, commands: [.add(DomainRestriction(owner: .permanent,
                policyID: "other", title: "Other", domains: ["other.invalid"]))])
        #expect(throws: FixtureBackendError.self) { try backend.apply(different, now: later, calendar: .current) }
        let stale = BackendRequest(version: 1, id: UUID(), expectedGeneration: 1, submittedAt: now, commands: different.commands)
        #expect(throws: FixtureBackendError.self) { try backend.apply(stale, now: later, calendar: .current) }
        #expect(try backend.snapshot(now: later, calendar: .current).committedRestrictions == [rule])
    }

    @Test func savedIntentRequiresExactAuthenticatedEffectsAndSurvivesRestart() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        let rule = DomainRestriction(owner: .permanent, policyID: "keep", title: "Keep", domains: ["example.invalid"])
        let request = BackendRequest(version: 1, id: UUID(), expectedGeneration: 0, submittedAt: now, commands: [.add(rule)])
        let pending = PendingPolicySubmission(version: 1, request: request, schedulePreferences: nil)
        let store = PolicySubmissionStore(root: root)
        try store.save(pending)
        #expect(try store.load()?.request.id == request.id)
        // A different authenticated receipt does not confirm unrelated intent.
        let unrelated = BackendRequest(version: 1, id: UUID(), expectedGeneration: 0, submittedAt: now,
            commands: [.add(DomainRestriction(owner: .permanent, policyID: "other", title: "Other", domains: ["other.invalid"]))])
        _ = try backend.apply(unrelated, now: now, calendar: .current)
        #expect(!pending.isConfirmed(by: try backend.snapshot(now: now, calendar: .current)))
        let exactEffects = BackendRequest(version: 1, id: UUID(), expectedGeneration: 1, submittedAt: now, commands: request.commands)
        _ = try backend.apply(exactEffects, now: now, calendar: .current)
        #expect(pending.isConfirmed(by: try backend.snapshot(now: now, calendar: .current)))
        try store.remove()
        #expect(try store.load() == nil)
    }

    @Test func queueIsDurableDeduplicatedAndCorruptionIsPreserved() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyQueueStore(root: root)
        var queue = StudyQueueDocument(items: [])
        #expect(try queue.append(.parse("https://youtu.be/abcdefghijk https://youtu.be/abcdefghijk bad")) == 1)
        try store.save(queue)
        #expect(try store.load()?.items.map(\.id) == ["abcdefghijk"])
        #expect(try queue.append(.parse("https://youtu.be/abcdefghijk")) == 0)
        try Data("broken queue".utf8).write(to: store.file)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try String(contentsOf: store.file, encoding: .utf8) == "broken queue")
        try store.recoverEmptyQueue(legacy: nil)
        #expect(try store.load()?.items.isEmpty == true)
        let archives = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
        guard let archived = archives.first(where: {
            $0.lastPathComponent.hasPrefix("unreadable-download-queue-")
        }) else {
            Issue.record("Queue corruption recovery did not archive the original bytes.")
            return
        }
        #expect(try String(contentsOf: archived, encoding: .utf8) == "broken queue")
    }

    @MainActor
    @Test func confirmedHoursEditKeepsScheduleTimeZoneDomainsAndTitle() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        let schedule = DailySchedule(id: "youtube", title: "Existing category", domains: ["custom.invalid"],
            startMinutes: 600, endMinutes: 900, isRequested: true)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: now, commands: [.add(schedule)]), now: now, calendar: .current)
        let model = ShieldViewModel(studyLibraryRoot: root.appendingPathComponent("library"), fixtureBackend: backend)
        var snapshot = try backend.snapshot(now: now, calendar: .current)
        snapshot.timeZoneIdentifier = "America/New_York"
        try model.acceptBackendSnapshot(snapshot, now: now)
        #expect(model.scheduleCalendar.timeZone.identifier == "America/New_York")
        // Blocking from 9 AM instead of 10 AM (stored hours are the blocked
        // window) is stricter, so it applies at once.
        model.changeConfirmedHours(scheduleID: schedule.id, start: 540, end: 900, now: now)
        let committed = try #require(model.backendSnapshot?.committedSchedules.first)
        #expect(committed.startMinutes == 540)
        #expect(committed.domains == schedule.domains)
        #expect(committed.title == schedule.title)
    }

    @MainActor
    @Test func unchangedPendingHoursDoNotPreventIndependentStrengthening() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        let original = DailySchedule(id: "youtube", title: "YouTube", domains: ["youtube.com"],
            startMinutes: 600, endMinutes: 900, isRequested: true)
        let planned = DailySchedule(id: "youtube", title: "YouTube", domains: original.domains,
            startMinutes: 660, endMinutes: 900, isRequested: true)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0, submittedAt: now,
            commands: [.add(original)]), now: now, calendar: .current)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 1, submittedAt: now,
            commands: [.replace(planned, at: now.addingTimeInterval(86_460))]), now: now, calendar: .current)
        let model = ShieldViewModel(studyLibraryRoot: root.appendingPathComponent("library"), fixtureBackend: backend)
        model.refresh(now: now)
        // New X / Reddit schedules (stored as the blocked complement) are
        // independent of the pending YouTube change.
        let domains: Set<String> = ["x.com", "twitter.com", "reddit.com", "www.reddit.com"]
        _ = model.addSchedule(name: "X / Reddit Focus", domains: domains,
                              allowed: try #require(AllowedAccessWindow(startMinutes: 780, endMinutes: 420)),
                              categoryID: "social", now: now)
        _ = model.addSchedule(name: "X / Reddit Night", domains: domains,
                              allowed: try #require(AllowedAccessWindow(startMinutes: 480, endMinutes: 1_200)),
                              categoryID: "social", now: now)
        #expect(model.backendSnapshot?.committedSchedules.count == 3)
        #expect(model.backendSnapshot?.committedSchedules.first(where: { $0.id == "youtube" }) == original)
        #expect(model.backendSnapshot?.pendingReleases.first?.replacementSchedule == planned)
    }

    @MainActor
    @Test func addingAnotherScheduleDoesNotRecreateOrChangeExistingSchedules() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        let night = DailySchedule(id: "social-night", title: "Night", domains: ["social.invalid"],
            startMinutes: 1_200, endMinutes: 480, isRequested: true)
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: now, commands: [.add(night)]), now: now, calendar: .current)
        let model = ShieldViewModel(studyLibraryRoot: root.appendingPathComponent("library"), fixtureBackend: backend)
        model.refresh(now: now)
        let allowed = try #require(AllowedAccessWindow(startMinutes: 18 * 60, endMinutes: 20 * 60))
        let youtube = try #require(model.addSchedule(name: "YouTube", domains: ["youtube.com"],
                                                     allowed: allowed, categoryID: "video", now: now))
        let added = try #require(model.backendSnapshot?.committedSchedules.first { $0.title == "YouTube" })
        #expect(model.submissionState == .confirmed(youtube))
        #expect(Set(model.backendSnapshot?.committedSchedules.map(\.id) ?? []) == ["social-night", added.id])
        #expect(model.backendSnapshot?.committedSchedules.first(where: { $0.id == "social-night" }) == night)
    }

    @Test func workerRejectsUnapprovedIDsUnknownFieldsAndOversizedMessages() throws {
        let video = StudyVideo(id: "abcdefghijk", title: "Approved", expectedDuration: nil, transcriptRequested: true)
        let request = StudyWorkerRequest(version: 1, jobID: UUID(), video: video, approvedIDs: [video.id])
        let bytes = try JSONEncoder().encode(request)
        #expect(try StudyWorkerRequest.decode(bytes).video == video)
        let denied = StudyWorkerRequest(version: 1, jobID: UUID(), video: video, approvedIDs: ["lmnopqrstuv"])
        #expect(throws: (any Error).self) { try StudyWorkerRequest.decode(JSONEncoder().encode(denied)) }
        guard var object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            Issue.record("The encoded worker request is not a JSON object.")
            return
        }
        object["url"] = "https://unrelated.invalid"
        #expect(throws: (any Error).self) { try StudyWorkerRequest.decode(JSONSerialization.data(withJSONObject: object)) }
        #expect(throws: (any Error).self) { try StudyWorkerRequest.decode(Data(repeating: 32, count: 32_769)) }
    }

    @MainActor
    @Test func corruptPendingIntentBlocksNewRequestsUntilExplicitPreservingRecovery() throws {
        let root = try directory(seedHosts: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        try backend.initializeEmptyAuthority(now: .now, calendar: .current)
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        let store = PolicySubmissionStore(root: library)
        let original = Data("unreadable intent".utf8)
        try original.write(to: store.file)
        let model = ShieldViewModel(studyLibraryRoot: library, fixtureBackend: backend)
        model.start()
        defer { model.stop() }
        #expect(model.backendSnapshot != nil)
        #expect(model.submissionRecordError != nil)
        #expect(!model.canSubmitPolicy)
        model.archiveUnreadableSubmission()
        #expect(model.canSubmitPolicy)
        let archives = try FileManager.default.contentsOfDirectory(
            at: library, includingPropertiesForKeys: nil)
        guard let archive = archives.first(where: {
            $0.lastPathComponent.hasPrefix("unreadable-policy-request-")
        }) else {
            Issue.record("Policy submission recovery did not archive the original bytes.")
            return
        }
        #expect(try Data(contentsOf: archive) == original)
        #expect(try backend.snapshot(now: .now, calendar: .current).committedRestrictions.isEmpty)
    }

    @Test func boundedWorkerFilesRejectSymlinksAndOversizedDataBeforeReading() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("metadata")
        try Data(repeating: 1, count: 128).write(to: file)
        #expect(try StudyBoundedFile.read(file, limit: 128).count == 128)
        #expect(throws: StudyDownloadError.self) { try StudyBoundedFile.read(file, limit: 127) }
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: StudyDownloadError.self) { try StudyBoundedFile.read(link, limit: 128) }
    }

    @Test func maintenanceExpiryAndRestartPreserveExactRequestReplay() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        let rule = DomainRestriction(owner: .temporary, policyID: "expires", title: "Temporary",
            domains: ["example.invalid"], startsAt: now, endsAt: now.addingTimeInterval(60))
        let request = BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: now, commands: [.add(rule)])
        _ = try backend.apply(request, now: now, calendar: .current)
        let later = now.addingTimeInterval(600)
        _ = try backend.tick(now: later, calendar: .current)
        let restarted = try FixtureBackend(root: root)
        let replay = try restarted.apply(request, now: later, calendar: .current)
        #expect(replay.status == .alreadyApplied)
        #expect(replay.receipt.payload.generation == 2)
        #expect(replay.receipt.payload.requestID == request.id)
        let snapshot = try restarted.snapshot(now: later, calendar: .current)
        #expect(snapshot.committedRestrictions.isEmpty)
        #expect(PendingPolicySubmission(version: 1, request: request, schedulePreferences: nil).isConfirmed(by: snapshot))
        let changed = BackendRequest(version: 1, id: request.id, expectedGeneration: 0,
            submittedAt: now, commands: [.add(DomainRestriction(owner: .permanent, policyID: "other",
                title: "Other", domains: ["other.invalid"]))])
        #expect(throws: FixtureBackendError.self) { try restarted.apply(changed, now: later, calendar: .current) }
    }

    @Test func mixedInvalidPolicyBatchLeavesAuthorityAndReceiptUnchanged() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        let permanent = DomainRestriction(owner: .permanent, policyID: "permanent", title: "Keep", domains: ["example.invalid"])
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: now, commands: [.add(permanent)]), now: now, calendar: .current)
        let before = try backend.snapshot(now: now, calendar: .current)
        let added = DomainRestriction(owner: .permanent, policyID: "new", title: "New", domains: ["other.invalid"])
        let invalid = BackendRequest(version: 1, id: UUID(), expectedGeneration: 1, submittedAt: now,
            commands: [.add(added), .release("permanent", at: now.addingTimeInterval(86_400))])
        #expect(throws: FixtureBackendError.self) { try backend.apply(invalid, now: now, calendar: .current) }
        let after = try backend.snapshot(now: now, calendar: .current)
        #expect(after.generation == before.generation)
        #expect(after.committedRestrictions == [permanent])
        #expect(after.receipt == before.receipt)
    }

    @Test func queueOwnershipIsIndependentOfDisplayTitleAndSurvivesEncoding() throws {
        let video = StudyVideo(id: "abcdefghijk", title: "A video", expectedDuration: nil, transcriptRequested: false)
        let imported = StudyManifest(schemaVersion: 1, courseTitle: "Downloads", videos: [video])
        let queue = StudyManifest(schemaVersion: 1, courseTitle: "Downloads", videos: [video], origin: .linkQueue)
        #expect(!imported.isLinkQueue)
        #expect(queue.isLinkQueue)
        #expect(imported.selectionKey != queue.selectionKey)
        let decoded = try JSONDecoder().decode(StudyManifest.self, from: JSONEncoder().encode(queue))
        #expect(decoded.isLinkQueue)
        let legacy = try JSONDecoder().decode(StudyManifest.self, from: JSONEncoder().encode(imported))
        #expect(!legacy.isLinkQueue)
    }

    @MainActor
    @Test func importedDownloadsCollectionCannotOwnOrFilterLinkQueue() async throws {
        let root = try directory(seedHosts: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        let backend = try FixtureBackend(root: root)
        try backend.initializeEmptyAuthority(now: .now, calendar: .current)
        let model = ShieldViewModel(studyLibraryRoot: library, fixtureBackend: backend)
        defer { model.stop() }
        let video = StudyVideo(id: "lmnopqrstuv", title: "Imported course", expectedDuration: nil, transcriptRequested: false)
        // Imported JSON cannot reserve the queue, even by including its marker.
        let imported = StudyManifest(schemaVersion: 1, courseTitle: "Downloads", videos: [video], origin: .linkQueue)
        let file = root.appendingPathComponent("collection.json")
        try JSONEncoder().encode(imported).write(to: file)
        model.importStudyManifest(from: file)
        for _ in 0..<100 where model.isRestoringStudy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isRestoringStudy)
        #expect(!model.isShowingLinkQueue)
        #expect(model.listedStudyJobs.map(\.id) == [video.id])
        #expect(model.addVideoLinks("https://youtu.be/abcdefghijk"))
        for _ in 0..<100 where model.isRestoringStudy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.isShowingLinkQueue)
        #expect(model.listedStudyJobs.map(\.id) == ["abcdefghijk"])
        for _ in 0..<100 where model.savedCourses.count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.savedCourses.filter { $0.courseTitle == "Downloads" }.count == 2)
        #expect(Set(model.savedCourses.map(\.selectionKey)).count == 2)
        let preserved = model.savedCourses.first { !$0.isLinkQueue && $0.courseTitle == "Downloads" }
        #expect(preserved?.videos == [video])
    }

    @Test func certificatePinRejectsMissingMalformedAndInjectedRequirements() throws {
        let pin = String(repeating: "a", count: 40)
        let expression = try StudyWorkerIdentity.clientRequirement(certificateSHA1: pin)
        #expect(expression.contains(pin))
        var requirement: SecRequirement?
        #expect(SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess)
        for invalid in ["", String(repeating: "f", count: 39), pin + " or true", "../host", String(repeating: "A", count: 40)] {
            #expect(throws: StudyDownloadError.self) { try StudyWorkerIdentity.clientRequirement(certificateSHA1: invalid) }
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: StudyWorkerFetcher.bundleURL.path) ||
        ProcessInfo.processInfo.environment["SHIELD_REQUIRE_WORKER_TEST"] == "1"))
    func packagedOutOfProcessWorkerRejectsInvalidEnvelopeAndUnknownJob() async throws {
        let channel = try StudyWorkerChannel()
        defer { channel.connection.invalidate() }
        do {
            _ = try await channel.call { peer, done in
                peer.begin(Data("{}".utf8) as NSData) { done(Data(), $0 as String?) }
            }
            Issue.record("Worker accepted an invalid envelope")
        } catch StudyWorkerChannelError.rejected(let message) {
            #expect(message.contains("Invalid worker envelope"))
        } catch { Issue.record("Expected worker rejection; got transport/identity failure: \(error)") }
        do {
            _ = try await channel.call { peer, done in
                peer.status(UUID().uuidString as NSString) { done($0 as Data?, $1 as String?) }
            }
            Issue.record("Worker returned an unknown job")
        } catch StudyWorkerChannelError.rejected(let message) {
            #expect(message.contains("Unknown worker job"))
        } catch { Issue.record("Expected worker rejection; got transport/identity failure: \(error)") }
        let video = StudyVideo(id: "abcdefghijk", title: "Approved", expectedDuration: nil, transcriptRequested: false)
        let request = StudyWorkerRequest(version: 1, jobID: UUID(), video: video, approvedIDs: [video.id])
        let bytes = try JSONEncoder().encode(request)
        do {
            _ = try await channel.call { peer, done in peer.begin(bytes as NSData) { done(Data(), $0 as String?) } }
            Issue.record("No-tools worker unexpectedly started a job")
        } catch StudyWorkerChannelError.rejected(let message) {
            #expect(message.contains("Reviewed tools are not bundled"))
        } catch { Issue.record("Expected tool gate; got transport/identity failure: \(error)") }
    }
}
