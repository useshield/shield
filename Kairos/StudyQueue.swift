import Foundation

struct StudyQueueItem: Codable, Equatable, Identifiable {
    let id: String
    let approvedAt: Date
    var title: String?
}

struct StudyQueueDocument: Codable {
    /// The whole library: every video the user added, saved or not.
    static let limit = 500
    var version = 1
    var items: [StudyQueueItem]

    func validated() throws -> Self {
        guard version == 1, items.count <= StudyQueueDocument.limit, Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ StudyYouTubeLinks.isValidID($0.id) && ($0.title?.count ?? 0) <= 256 &&
                  $0.approvedAt.timeIntervalSinceReferenceDate.isFinite }) else {
            throw StudyDownloadError.invalidManifest("The saved queue is invalid. Its file was preserved.")
        }
        return self
    }
    mutating func append(_ links: StudyYouTubeLinks, now: Date = .now) throws -> Int {
        guard !links.tooMany else {
            throw StudyDownloadError.invalidManifest("Paste up to 100 YouTube video links at a time.")
        }
        guard !links.ids.isEmpty else {
            throw StudyDownloadError.invalidManifest("No YouTube video links found.")
        }
        let known = Set(items.map(\.id))
        let additions = links.ids.filter { !known.contains($0) }
        guard items.count + additions.count <= Self.limit else {
            throw StudyDownloadError.invalidManifest("The library holds at most \(Self.limit) videos.")
        }
        items += additions.map { .init(id: $0, approvedAt: now, title: nil) }
        return additions.count
    }
}

struct StudyQueueStore {
    let root: URL
    var file: URL { root.appendingPathComponent("download-queue.json") }
    func load() throws -> StudyQueueDocument? {
        guard let data = try StudyPersistenceFiles.readIfPresent(file, root: root,
                                                                maximumBytes: 524_288) else { return nil }
        return try JSONDecoder().decode(StudyQueueDocument.self, from: data).validated()
    }
    func save(_ document: StudyQueueDocument) throws {
        _ = try document.validated()
        try ShieldRuntime.requireIsolatedWrite(to: file)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try AtomicFixtureStore(allowedRoot: root).write(JSONEncoder().encode(document), to: file)
    }
    func recoverEmptyQueue(legacy: String?) throws {
        try ShieldRuntime.requireIsolatedWrite(to: file)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let files = AtomicFixtureStore(allowedRoot: root)
        let original = FileManager.default.fileExists(atPath: file.path)
            ? try files.read(file) : Data((legacy ?? "").utf8)
        try files.write(original, to: root.appendingPathComponent("unreadable-download-queue-\(UUID()).json"))
        try save(StudyQueueDocument(items: []))
    }
}
