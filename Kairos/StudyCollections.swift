import Foundation
import Darwin

// Owner-made groups of library videos. Presentation only: a collection holds
// video IDs from the one library, a video may be in several collections, and
// deleting a collection never deletes a video or its saved files.

struct StudyCollection: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var symbol: String
    var color: ShieldCategoryColor
    var videoIDs: [String]

    static let maximumNameLength = 60
    static let maximumCount = 100

    static let symbols = [
        "play.rectangle.fill", "books.vertical.fill", "graduationcap.fill", "book.fill",
        "pencil.and.ruler.fill", "function", "brain.head.profile", "lightbulb.fill",
        "music.note", "film.fill", "tv.fill", "mic.fill", "gamecontroller.fill", "sportscourt.fill",
        "dumbbell.fill", "fork.knife", "globe", "airplane", "heart.fill", "star.fill",
        "flame.fill", "bolt.fill", "moon.fill", "folder.fill",
    ]

    static func new(name: String, symbol: String, color: ShieldCategoryColor) -> Self {
        Self(id: "collection-" + UUID().uuidString, name: name, symbol: symbol, color: color, videoIDs: [])
    }
}

struct StudyCollectionLayout: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = currentVersion
    var collections: [StudyCollection] = []

    func collection(_ id: String) -> StudyCollection? { collections.first { $0.id == id } }

    func collections(containing videoID: String) -> [StudyCollection] {
        collections.filter { $0.videoIDs.contains(videoID) }
    }

    /// Repairs a hand-edited or older file: unique IDs, trimmed bounded names,
    /// known icons, valid video IDs listed once, and (when the library is
    /// known) no IDs that are no longer in it.
    func normalized(libraryIDs: Set<String>? = nil) -> Self {
        var seen = Set<String>()
        var result = Self()
        for var collection in collections.prefix(StudyCollection.maximumCount) {
            guard !collection.id.isEmpty, collection.id.count <= 80, seen.insert(collection.id).inserted else { continue }
            collection.name = String(collection.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(StudyCollection.maximumNameLength))
            if collection.name.isEmpty { collection.name = "Collection" }
            if !StudyCollection.symbols.contains(collection.symbol) { collection.symbol = "play.rectangle.fill" }
            var members = Set<String>()
            collection.videoIDs = collection.videoIDs.filter {
                StudyYouTubeLinks.isValidID($0) && (libraryIDs?.contains($0) ?? true) && members.insert($0).inserted
            }
            result.collections.append(collection)
        }
        return result
    }

    /// Replaces a collection with the same ID, or adds a new one at the end.
    mutating func upsert(_ collection: StudyCollection) {
        if let index = collections.firstIndex(where: { $0.id == collection.id }) {
            collections[index] = collection
        } else if collections.count < StudyCollection.maximumCount {
            collections.append(collection)
        }
    }

    mutating func delete(_ id: String) { collections.removeAll { $0.id == id } }

    mutating func add(_ videoIDs: [String], to id: String) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        for videoID in videoIDs where !collections[index].videoIDs.contains(videoID) {
            collections[index].videoIDs.append(videoID)
        }
    }

    mutating func remove(_ videoID: String, from id: String) {
        guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[index].videoIDs.removeAll { $0 == videoID }
    }

    mutating func removeEverywhere(_ videoID: String) {
        for index in collections.indices { collections[index].videoIDs.removeAll { $0 == videoID } }
    }

    /// Drag and drop: the dragged collection takes the target's place.
    mutating func move(_ id: String, to targetID: String) {
        guard id != targetID, let from = collections.firstIndex(where: { $0.id == id }),
              let to = collections.firstIndex(where: { $0.id == targetID }) else { return }
        collections.insert(collections.remove(at: from), at: to)
    }

    /// The sidebar's own drag reordering.
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        // Foundation only (this file has no SwiftUI): the same rule as List's onMove.
        let moving = source.sorted().filter { collections.indices.contains($0) }.map { collections[$0] }
        let before = source.count { $0 < destination }
        collections.removeAll { item in moving.contains { $0.id == item.id } }
        collections.insert(contentsOf: moving, at: min(max(0, destination - before), collections.count))
    }

    mutating func move(_ id: String, by offset: Int) {
        guard let from = collections.firstIndex(where: { $0.id == id }) else { return }
        let to = from + offset
        guard collections.indices.contains(to) else { return }
        collections.swapAt(from, to)
    }
}

struct StudyCollectionStore {
    let fileURL: URL

    /// A missing file is an empty layout. An unreadable one is reported so the
    /// caller can keep a copy before its next save replaces it.
    func load() -> (layout: StudyCollectionLayout, unreadable: Bool) {
        var metadata = stat()
        guard lstat(fileURL.path, &metadata) == 0 else { return (.init(), errno != ENOENT) }
        guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_size <= 1_048_576,
              let data = try? Data(contentsOf: fileURL),
              let layout = try? JSONDecoder().decode(StudyCollectionLayout.self, from: data),
              layout.version == StudyCollectionLayout.currentVersion else {
            return (.init(), true)
        }
        return (layout.normalized(), false)
    }

    func preserveUnreadable() throws {
        try ShieldRuntime.requireIsolatedWrite(to: fileURL)
        let directory = fileURL.deletingLastPathComponent()
        let files = AtomicFixtureStore(allowedRoot: directory)
        try files.write(try files.read(fileURL),
                        to: directory.appendingPathComponent("collections.unreadable-\(UUID().uuidString).json"))
    }

    func save(_ layout: StudyCollectionLayout) throws {
        try ShieldRuntime.requireIsolatedWrite(to: fileURL)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFixtureStore(allowedRoot: directory).write(encoder.encode(layout.normalized()), to: fileURL)
    }
}
