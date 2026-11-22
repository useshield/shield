import CoreGraphics
import Foundation
import Testing
@testable import Shield

struct StudyCollectionLayoutTests {
    private let a = "abcdefghijk", b = "bcdefghijkl", c = "cdefghijklm"

    @Test func membershipIsManyToManyAndDeletingACollectionKeepsOthers() {
        var layout = StudyCollectionLayout()
        let math = StudyCollection.new(name: "Math", symbol: "function", color: .blue)
        let review = StudyCollection.new(name: "Review", symbol: "star.fill", color: .orange)
        layout.upsert(math)
        layout.upsert(review)
        layout.add([a, b, a], to: math.id)
        layout.add([a], to: review.id)
        #expect(layout.collection(math.id)?.videoIDs == [a, b])
        #expect(layout.collections(containing: a).map(\.id) == [math.id, review.id])
        layout.delete(math.id)
        #expect(layout.collections.map(\.id) == [review.id])
        #expect(layout.collection(review.id)?.videoIDs == [a])
        layout.removeEverywhere(a)
        #expect(layout.collection(review.id)?.videoIDs == [])
    }

    @Test func normalizationRepairsNamesIconsDuplicatesAndUnknownVideos() {
        let layout = StudyCollectionLayout(collections: [
            StudyCollection(id: "one", name: "  " + String(repeating: "x", count: 90), symbol: "not.a.symbol",
                            color: .teal, videoIDs: [a, "bad", a, c]),
            StudyCollection(id: "one", name: "Duplicate", symbol: "star.fill", color: .red, videoIDs: []),
            StudyCollection(id: "two", name: "   ", symbol: "star.fill", color: .red, videoIDs: [b]),
        ]).normalized(libraryIDs: [a, b])
        #expect(layout.collections.map(\.id) == ["one", "two"])
        #expect(layout.collections[0].name.count == StudyCollection.maximumNameLength)
        #expect(layout.collections[0].symbol == "play.rectangle.fill")
        #expect(layout.collections[0].videoIDs == [a], "Invalid, repeated and removed videos are dropped.")
        #expect(layout.collections[1].name == "Collection")
    }

    @Test func movingStaysInBounds() {
        var layout = StudyCollectionLayout()
        let first = StudyCollection.new(name: "First", symbol: "star.fill", color: .blue)
        let second = StudyCollection.new(name: "Second", symbol: "star.fill", color: .blue)
        layout.upsert(first)
        layout.upsert(second)
        layout.move(first.id, by: -1)
        #expect(layout.collections.map(\.id) == [first.id, second.id])
        layout.move(first.id, by: 1)
        #expect(layout.collections.map(\.id) == [second.id, first.id])
    }

    @Test func storeRoundTripsAndKeepsAnUnreadableFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StudyCollections-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = StudyCollectionStore(fileURL: root.appendingPathComponent("collections.json"))
        #expect(store.load().layout == StudyCollectionLayout())
        #expect(!store.load().unreadable, "A missing file is simply empty.")
        var layout = StudyCollectionLayout()
        layout.upsert(StudyCollection(id: "x", name: "Saved", symbol: "star.fill", color: .green, videoIDs: [a]))
        try store.save(layout)
        #expect(store.load().layout == layout)
        try Data("{broken".utf8).write(to: store.fileURL)
        #expect(store.load().unreadable)
        try store.preserveUnreadable()
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("collections.unreadable-") }
        #expect(kept.count == 1)
    }
}

@MainActor
struct StudyLibraryActionTests {
    private let a = "abcdefghijk", b = "bcdefghijkl"

    private func makeModel() throws -> (ShieldViewModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StudyLibraryActions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let authority = root.appendingPathComponent("authority")
        try FileManager.default.createDirectory(at: authority, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let backend = try FixtureBackend(root: authority)
        try backend.initializeEmptyAuthority(now: .now, calendar: .current)
        let library = root.appendingPathComponent("library")
        let model = ShieldViewModel(studyLibraryRoot: library, fixtureBackend: backend)
        return (model, library)
    }

    private func settle(_ model: ShieldViewModel) async throws {
        for _ in 0..<200 where model.isRestoringStudy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isRestoringStudy)
    }

    @Test func pastedLinksJoinTheLibraryAndTheChosenCollection() async throws {
        let (model, library) = try makeModel()
        defer { model.stop() }
        let math = StudyCollection.new(name: "Math", symbol: "function", color: .blue)
        model.saveCollection(math)
        #expect(model.addVideoLinks("https://youtu.be/\(a) https://www.youtube.com/watch?v=\(b)", toCollection: math.id))
        try await settle(model)
        #expect(model.libraryIDs == [a, b])
        #expect(model.libraryJobs(in: math.id).map(\.id) == [a, b])
        #expect(model.libraryJobs(in: nil).count == 2)
        // A link already in the library is only added to another collection.
        let review = StudyCollection.new(name: "Review", symbol: "star.fill", color: .orange)
        model.saveCollection(review)
        #expect(model.addVideoLinks("https://youtu.be/\(a)", toCollection: review.id))
        try await settle(model)
        #expect(model.libraryIDs == [a, b])
        #expect(model.libraryJobs(in: review.id).map(\.id) == [a])
        // Collections persist beside the library.
        let reloaded = StudyCollectionStore(fileURL: library.appendingPathComponent("collections.json")).load().layout
        #expect(reloaded.collection(review.id)?.videoIDs == [a])
    }

    @Test func deletingACollectionKeepsItsVideos() async throws {
        let (model, _) = try makeModel()
        defer { model.stop() }
        let math = StudyCollection.new(name: "Math", symbol: "function", color: .blue)
        model.saveCollection(math)
        model.selectedCollectionID = math.id
        #expect(model.addVideoLinks("https://youtu.be/\(a)", toCollection: math.id))
        try await settle(model)
        model.deleteCollection(math.id)
        #expect(model.collectionLayout.collections.isEmpty)
        #expect(model.selectedCollectionID == nil)
        #expect(model.libraryIDs == [a])
    }

    @Test func deletingAVideoRemovesItsFilesAndMemberships() async throws {
        let (model, library) = try makeModel()
        defer { model.stop() }
        let math = StudyCollection.new(name: "Math", symbol: "function", color: .blue)
        model.saveCollection(math)
        #expect(model.addVideoLinks("https://youtu.be/\(a) https://youtu.be/\(b)", toCollection: math.id))
        try await settle(model)
        let folder = library.appendingPathComponent(".link-queue-v1")
        for suffix in ["mp4", "txt", "playback.json"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent("\(a).\(suffix)"))
        }
        model.deleteVideo(a)
        try await settle(model)
        #expect(model.libraryIDs == [b])
        #expect(model.collectionLayout.collection(math.id)?.videoIDs == [b])
        for suffix in ["mp4", "txt", "playback.json"] {
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(a).\(suffix)").path))
        }
        #expect(try StudyLibraryStore(root: folder).load()?.completedIDs.contains(a) != true)
    }

    @Test func renamedTitlesAreKeptWhenDownloadMetadataArrives() async throws {
        let (model, _) = try makeModel()
        defer { model.stop() }
        #expect(model.addVideoLinks("https://youtu.be/\(a)", toCollection: nil))
        try await settle(model)
        #expect(model.libraryTitle(a) == "YouTube video \(a)")
        model.renameVideo(a, to: "  Lesson 1  ")
        #expect(model.libraryTitle(a) == "Lesson 1")
        model.renameVideo(a, to: "   ")
        #expect(model.libraryTitle(a) == "Lesson 1", "An empty name is refused.")
    }

    @Test func aCourseJoinsTheLibraryOnceAsItsOwnCollection() async throws {
        let (model, _) = try makeModel()
        defer { model.stop() }
        let course = StudyManifest(schemaVersion: 1, courseTitle: "Algebra", videos: [
            StudyVideo(id: a, title: "Linear equations", expectedDuration: 600, transcriptRequested: true),
            StudyVideo(id: b, title: "Circles", expectedDuration: 700, transcriptRequested: true),
        ])
        #expect(!model.isCourseInLibrary(course))
        model.addCourseToLibrary(course)
        try await settle(model)
        #expect(model.isCourseInLibrary(course))
        #expect(model.libraryIDs == [a, b])
        #expect(model.libraryTitle(b) == "Circles")
        let id = model.collectionID(forCourse: course)
        #expect(model.selectedCollectionID == id)
        #expect(model.collectionLayout.collection(id)?.name == "Algebra")
        #expect(model.libraryJobs(in: id).map(\.id) == [a, b])
        model.addCourseToLibrary(course)
        try await settle(model)
        #expect(model.libraryIDs == [a, b])
        #expect(model.collectionLayout.collections.count == 1)
    }

    @Test func savedVideosMissingFromTheListAreAdoptedIntoTheLibrary() async throws {
        let (model, library) = try makeModel()
        defer { model.stop() }
        let folder = library.appendingPathComponent(".link-queue-v1")
        let manifest = StudyManifest(schemaVersion: 1, courseTitle: "Downloads", videos: [
            StudyVideo(id: a, title: "Kept lesson", expectedDuration: nil, transcriptRequested: true),
        ], origin: .linkQueue)
        try StudyLibraryStore(root: folder).save(StudyLibrarySnapshot(
            version: 1, manifest: manifest, completedIDs: [a], failures: [:], updatedAt: .now))
        model.openLibrary()
        try await settle(model)
        #expect(model.libraryIDs == [a])
        #expect(model.libraryTitle(a) == "Kept lesson")
        #expect(model.isShowingLinkQueue)
    }
}

/// Drag collections into any order; the sidebar and Library
/// tiles share one order.
struct StudyCollectionReorderTests {
    private func layout(_ ids: [String]) -> StudyCollectionLayout {
        StudyCollectionLayout(collections: ids.map {
            StudyCollection(id: $0, name: $0, symbol: "star.fill", color: .blue, videoIDs: [])
        })
    }

    @Test func draggingOntoATileTakesItsPlace() {
        var order = layout(["a", "b", "c", "d"])
        order.move("a", to: "c")
        #expect(order.collections.map(\.id) == ["b", "c", "a", "d"])
        order.move("d", to: "b")
        #expect(order.collections.map(\.id) == ["d", "b", "c", "a"])
        order.move("b", to: "b")
        order.move("missing", to: "a")
        #expect(order.collections.map(\.id) == ["d", "b", "c", "a"])
    }

    @Test func sidebarMovesMatchSwiftUIsOnMove() {
        let ids = ["a", "b", "c", "d", "e"]
        let cases: [(IndexSet, Int)] = [([0], 3), ([4], 0), ([1, 3], 5), ([2], 2), ([0, 1], 4), ([3], 1)]
        for (source, destination) in cases {
            var order = layout(ids)
            order.move(fromOffsets: source, toOffset: destination)
            // Array.move(fromOffsets:toOffset:) is what List's onMove expects.
            var expected = ids
            let moving = source.sorted().map { expected[$0] }
            let before = source.count { $0 < destination }
            expected.removeAll { moving.contains($0) }
            expected.insert(contentsOf: moving, at: destination - before)
            #expect(order.collections.map(\.id) == expected, "\(source.sorted()) → \(destination)")
        }
    }
}

/// Each place can have its own icon and colour.
struct PlaceStyleTests {
    @Test func stylesSaveAndLoadAndDropUnknownIcons() throws {
        let suite = "PlaceStyleTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(PlaceStyle.loadAll(defaults).isEmpty)
        PlaceStyle.saveAll(["home": PlaceStyle(symbol: "house.fill", color: .green),
                            "odd": PlaceStyle(symbol: "not.a.symbol", color: .red)], to: defaults)
        #expect(PlaceStyle.loadAll(defaults) == ["home": PlaceStyle(symbol: "house.fill", color: .green)])
        #expect(Set(PlaceStyle.symbols).count == PlaceStyle.symbols.count)
    }
}

/// The ⓘ bubble sits just under the pointer and never leaves the screen.
struct HintBubblePlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 200, height: 40)

    @Test func sitsCentredJustBelowThePointer() {
        let frame = HintBubblePanel.frame(size: size, pointer: CGPoint(x: 700, y: 500), screen: screen)
        #expect(abs(frame.midX - 700) < 0.5)
        #expect(abs(frame.maxY - 484) < 0.5, "16 points under the pointer")
    }

    @Test func flipsAboveNearTheBottomAndStaysOnScreen() {
        let low = HintBubblePanel.frame(size: size, pointer: CGPoint(x: 5, y: 30), screen: screen)
        #expect(low.minY > 30, "Near the bottom it goes above the pointer")
        #expect(low.minX >= screen.minX + 8)
        let right = HintBubblePanel.frame(size: size, pointer: CGPoint(x: 1439, y: 500), screen: screen)
        #expect(right.maxX <= screen.maxX - 8)
    }
}
