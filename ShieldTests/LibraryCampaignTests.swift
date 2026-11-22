import Foundation
import Testing
@testable import Shield

struct LibraryCampaignTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldLibraryCampaign-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }

    private func manifest(_ title: String, queue: Bool = false) -> StudyManifest {
        StudyManifest(schemaVersion: 1, courseTitle: title,
            videos: [StudyVideo(id: "abcdefghijk", title: "A video", expectedDuration: nil, transcriptRequested: true)],
            origin: queue ? .linkQueue : nil)
    }

    @Test func typedSelectionDistinguishesQueueAndPrefixLikeCourseTitles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibrarySelectionStore(root: root)
        let courses = [manifest("Foo"), manifest("course:Foo"), manifest("queue:links-v1"), manifest("Downloads", queue: true)]
        for selected in courses {
            try store.saveSelection(for: selected)
            // Evaluate throwing APIs outside Swift Testing macro expansion.
            // Xcode 27 can generate a non-throwing closure for a nested call.
            let restoredValue = try StudyLibrarySelectionStore(root: root).selectedCourse(in: courses)
            guard let restored = restoredValue else {
                Issue.record("Saved selection did not round-trip for \(selected.courseTitle).")
                return
            }
            #expect(restored.selectionKey == selected.selectionKey)
            #expect(restored.isLinkQueue == selected.isLinkQueue)
        }
    }

    @Test func ambiguousLegacySelectionIsPreservedUntilExplicitChoice() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("selected-course.json")
        let store = StudyLibrarySelectionStore(root: root)
        let courses = [manifest("Foo"), manifest("course:Foo"), manifest("queue:links-v1"), manifest("Downloads", queue: true)]
        for legacy in ["course:Foo", "queue:links-v1"] {
            let bytes = try JSONEncoder().encode(legacy)
            try bytes.write(to: file)
            #expect(throws: StudyDownloadError.self) { try store.selectedCourse(in: courses) }
            #expect(try Data(contentsOf: file) == bytes)
        }
        try store.saveSelection(for: courses[2])
        #expect(try store.selectedCourse(in: courses)?.courseTitle == "queue:links-v1")
        #expect(try store.selectedCourse(in: courses)?.isLinkQueue == false)
    }

    @Test func uniqueLegacySelectionsRemainReadableWithoutImplicitRewrite() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("selected-course.json")
        let course = manifest("Legacy collection")
        for legacy in [course.courseTitle, course.selectionKey] {
            let bytes = try JSONEncoder().encode(legacy)
            try bytes.write(to: file)
            #expect(try StudyLibrarySelectionStore(root: root).selectedCourse(in: [course])?.courseTitle == course.courseTitle)
            #expect(try Data(contentsOf: file) == bytes)
        }
    }

    @Test func invalidLibraryMutationCannotReplaceLastReadableIndex() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let good = StudyLibrarySnapshot(version: 1, manifest: manifest("Saved"),
            completedIDs: ["abcdefghijk"], failures: [:], updatedAt: .now)
        try store.save(good)
        let file = root.appendingPathComponent("library-state.json")
        let original = try Data(contentsOf: file)
        var unknown = good
        unknown.completedIDs = ["unknown"]
        var conflicting = good
        conflicting.inFlightIDs = ["abcdefghijk"]
        var failedComplete = good
        failedComplete.failures = ["abcdefghijk": "Failed"]
        for invalid in [unknown, conflicting, failedComplete] {
            #expect(throws: StudyDownloadError.self) { try store.save(invalid) }
            #expect(try Data(contentsOf: file) == original)
            #expect(try store.load()?.completedIDs == good.completedIDs)
        }
        // A corrupt on-disk index is still refused independently of the writer.
        try JSONEncoder().encode(conflicting).write(to: file)
        #expect(throws: StudyDownloadError.self) { try store.load() }
    }

    @Test func explicitIndexRecoveryPreservesOriginalAndAllSavedFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StudyLibraryStore(root: root)
        let file = root.appendingPathComponent("library-state.json")
        let damaged = Data("incomplete index".utf8)
        try damaged.write(to: file)
        let preserved = ["abcdefghijk.mp4", "abcdefghijk.txt", "abcdefghijk.playback.json"]
        for name in preserved { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        try store.rebuildIndex(using: manifest("Recovered"))
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let backup = try #require(entries.first { $0.lastPathComponent.hasPrefix("library-state.damaged-") })
        #expect(try Data(contentsOf: backup) == damaged)
        for name in preserved { #expect(try Data(contentsOf: root.appendingPathComponent(name)) == Data(name.utf8)) }
        #expect(try store.load()?.completedIDs.isEmpty == true)
        let recovered = try Data(contentsOf: file)
        #expect(throws: StudyDownloadError.self) { try store.rebuildIndex(using: manifest("Different")) }
        #expect(try Data(contentsOf: file) == recovered)
    }

    @Test func danglingStateLinksAreErrorsRatherThanEmptyLibraryState() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["library-state.json", "download-queue.json", "selected-course.json"] {
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(name),
                                                       withDestinationURL: root.appendingPathComponent("missing"))
        }
        #expect(throws: (any Error).self) { try StudyLibraryStore(root: root).load() }
        #expect(throws: (any Error).self) { try StudyQueueStore(root: root).load() }
        #expect(throws: (any Error).self) {
            try StudyLibrarySelectionStore(root: root).selectedCourse(in: [manifest("Saved")])
        }
        for name in ["library-state.json", "download-queue.json", "selected-course.json"] {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent(name).path).hasSuffix("missing"))
        }
    }

    @Test func missingLibraryRootAndUnknownSelectionVersionDoNotInventState() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = root.appendingPathComponent("not-created")
        #expect(try StudyLibraryStore(root: absent).load() == nil)
        #expect(try StudyQueueStore(root: absent).load() == nil)
        #expect(try StudyLibrarySelectionStore(root: absent).selectedCourse(in: []) == nil)
        let file = root.appendingPathComponent("selected-course.json")
        let unknown = Data(#"{"version":99,"kind":"linkQueue"}"#.utf8)
        try unknown.write(to: file)
        #expect(throws: StudyDownloadError.self) {
            try StudyLibrarySelectionStore(root: root).selectedCourse(in: [manifest("Downloads", queue: true)])
        }
        #expect(try Data(contentsOf: file) == unknown)
    }
}
