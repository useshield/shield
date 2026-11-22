import AVFoundation
import Foundation
import Testing
@testable import Shield

struct StudyPlaybackTests {
    @MainActor
    @Test func selectedVideoImportsArbitraryFilenameWithoutChangingOtherJobsOrOriginals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldSelectedImport-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/controlled-media.mp4")
        let source = root.appendingPathComponent("My lecture.mp4")
        let original = try Data(contentsOf: fixture)
        try original.write(to: source)
        let model = ShieldViewModel(studyLibraryRoot: root.appendingPathComponent("library"))
        model.openSavedCourse(StudyManifest(schemaVersion: 1, courseTitle: "Selected import", videos: [
            StudyVideo(id: "abcdefghijk", title: "Chosen", expectedDuration: 2, transcriptRequested: false),
            StudyVideo(id: "lmnopqrstuv", title: "Untouched", expectedDuration: 2, transcriptRequested: false)]))
        for _ in 0..<200 where model.isRestoringStudy { try await Task.sleep(for: .milliseconds(25)) }
        #expect(!model.isRestoringStudy)
        #expect(!model.experimentalDownloadsEnabled)
        await model.importExistingMedia(from: [source], forVideoID: "unknown0001")
        #expect(model.studyCompletedCount == 0)
        await model.importExistingMedia(from: [root], forVideoID: "abcdefghijk")
        #expect(model.studyCompletedCount == 0)
        await model.importExistingMedia(from: [source], forVideoID: "abcdefghijk")
        #expect(model.studyCompletedCount == 1)
        #expect(model.studyJobs.first(where: { $0.id == "lmnopqrstuv" })?.state == .queued)
        #expect(model.playbackSelection(for: "abcdefghijk") != nil)
        #expect(try Data(contentsOf: source) == original)
        model.setExperimentalDownloadsEnabled(false)
        #expect(!model.experimentalDownloadsEnabled)
    }

    @MainActor
    @Test func similarlyNamedCollectionsStaySeparateAndMissingMediaIsReported() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldCollections-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        let model = ShieldViewModel(studyLibraryRoot: library)
        let video = StudyVideo(id: "abcdefghijk", title: "Shared ID, separate courses", expectedDuration: 2, transcriptRequested: false)
        for title in ["数学", "物理"] {
            model.openSavedCourse(StudyManifest(schemaVersion: 1, courseTitle: title, videos: [video]))
            for _ in 0..<200 where model.isRestoringStudy { try await Task.sleep(for: .milliseconds(25)) }
        }
        let directories = try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: nil)
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        #expect(directories.count == 2)
        #expect(Set(try directories.compactMap { try StudyLibraryStore(root: $0).load()?.manifest.courseTitle }) == ["数学", "物理"])
        guard let current = directories.first(where: {
            (try? StudyLibraryStore(root: $0).load()?.manifest.courseTitle) == "物理"
        }) else {
            Issue.record("The expected independent collection is missing.")
            return
        }
        guard var snapshot = try StudyLibraryStore(root: current).load() else {
            Issue.record("The expected collection index is missing.")
            return
        }
        snapshot.completedIDs = [video.id]
        try StudyLibraryStore(root: current).save(snapshot)
        model.openSavedCourse(snapshot.manifest)
        for _ in 0..<200 where model.isRestoringStudy { try await Task.sleep(for: .milliseconds(25)) }
        guard let job = model.studyJobs.first, case .failed(let reason) = job.state else {
            Issue.record("A missing previously completed file must be reported.")
            return
        }
        #expect(reason.contains("missing"))
        #expect(try StudyLibraryStore(root: current).load()?.completedIDs.isEmpty == true)
    }

    @MainActor
    @Test func nativeImportPlayerTranscriptAndRelaunchResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldPlayer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let originals = root.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: false)
        let id = "abcdefghijk"
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/controlled-media.mp4")
        let media = originals.appendingPathComponent("\(id).mp4")
        try FileManager.default.copyItem(at: fixture, to: media)
        let transcript = originals.appendingPathComponent("\(id).txt")
        try Data("A controlled transcript inside Shield.".utf8).write(to: transcript)
        let manifest = StudyManifest(schemaVersion: 1, courseTitle: "Player acceptance",
            videos: [StudyVideo(id: id, title: "Controlled video", expectedDuration: 2, transcriptRequested: true)])
        let manifestURL = root.appendingPathComponent("course.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let library = root.appendingPathComponent("library")
        let model = ShieldViewModel(studyLibraryRoot: library)
        model.importStudyManifest(from: manifestURL)
        for _ in 0..<200 where model.isRestoringStudy { try await Task.sleep(for: .milliseconds(25)) }
        await model.importExistingMedia(from: originals)
        #expect(model.studyCompletedCount == 1)
        guard let selection = model.playbackSelection(for: id, transcript: true) else {
            Issue.record("Validated media must be available for playback.")
            return
        }
        let session = StudyPlayerSession(selection: selection)
        await session.prepare()
        #expect(session.playbackError == nil)
        #expect(session.player.currentItem != nil)
        #expect(session.transcript == "A controlled transcript inside Shield.")
        #expect(session.player.rate == 0) // Opening text must not start hidden audio.
        let sought = await session.player.seek(to: CMTime(seconds: 0.6, preferredTimescale: 600),
                                               toleranceBefore: .zero, toleranceAfter: .zero)
        #expect(sought)
        session.checkpoint()
        session.close()
        guard let position = try selection.store.load(videoID: id) else {
            Issue.record("The saved playback position is missing.")
            return
        }
        #expect(abs(position.seconds - 0.6) < 0.15)

        let reopened = ShieldViewModel(studyLibraryRoot: library)
        // Older folders no longer reopen by themselves: they're listed under
        // Library ▸ More ▸ Older Downloads with their saved-video count.
        reopened.loadSavedCourses()
        for _ in 0..<200 where reopened.savedCourses.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
        #expect(reopened.studyManifestTitle == nil, "An older folder must not reopen at launch")
        let older = try #require(reopened.savedCourses.first { $0.courseTitle == manifest.courseTitle })
        #expect(reopened.olderLibraryCounts[older.selectionKey] == 1)
        reopened.openSavedCourse(older)
        for _ in 0..<200 {
            if reopened.studyManifestTitle != nil && !reopened.isRestoringStudy { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(reopened.studyManifestTitle == manifest.courseTitle)
        #expect(reopened.studyCompletedCount == 1)
        guard let resumedSelection = reopened.playbackSelection(for: id, transcript: true) else {
            Issue.record("Playback must reopen from the saved collection.")
            return
        }
        let resumed = StudyPlayerSession(selection: resumedSelection)
        await resumed.prepare()
        #expect(resumed.playbackError == nil)
        #expect(abs(CMTimeGetSeconds(resumed.player.currentTime()) - 0.6) < 0.15)
        resumed.close()
        let damagedIndex = selection.store.root.appendingPathComponent("library-state.json")
        try Data("damaged index".utf8).write(to: damagedIndex)
        reopened.openSavedCourse(manifest)
        #expect(reopened.pendingLibraryRecovery?.courseTitle == manifest.courseTitle)
        reopened.rebuildStudyIndex()
        for _ in 0..<200 where reopened.isRestoringStudy { try await Task.sleep(for: .milliseconds(25)) }
        #expect(reopened.pendingLibraryRecovery == nil)
        #expect(reopened.studyCompletedCount == 1)
        let backups = try FileManager.default.contentsOfDirectory(at: selection.store.root,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("library-state.damaged-") }
        #expect(backups.count == 1)
        guard let backup = backups.first else {
            Issue.record("The damaged-index backup was not created.")
            return
        }
        #expect(try String(contentsOf: backup, encoding: .utf8) == "damaged index")
        #expect(try selection.store.load(videoID: id)?.seconds == position.seconds)
        #expect(try Data(contentsOf: media) == Data(contentsOf: fixture))
        #expect(try String(contentsOf: transcript, encoding: .utf8) == "A controlled transcript inside Shield.")
    }

    @Test func corruptAndSymlinkedPlaybackDataAreRejectedWithoutAlteringMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldPlayer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyPlaybackStore(root: root)
        let id = "abcdefghijk"
        try store.save(videoID: id, seconds: 99, duration: 100)
        #expect(try store.load(videoID: id)?.resumeSeconds == 0)
        let state = root.appendingPathComponent("\(id).playback.json")
        try Data("broken".utf8).write(to: state)
        #expect(throws: Error.self) { try store.load(videoID: id) }
        try store.reset(videoID: id)
        #expect(try store.load(videoID: id) == nil)
        let secret = root.appendingPathComponent("unrelated.txt")
        try Data("unchanged".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("\(id).txt"), withDestinationURL: secret)
        #expect(throws: Error.self) { try store.transcript(videoID: id) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("\(id).mp4"), withDestinationURL: secret)
        #expect(throws: Error.self) { try store.mediaURL(videoID: id) }
        #expect(throws: Error.self) { try store.save(videoID: "../private", seconds: 0, duration: 1) }
        #expect(try String(contentsOf: secret, encoding: .utf8) == "unchanged")
    }
}
