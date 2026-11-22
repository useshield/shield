import Foundation
import Darwin

// A dangling symlink is damaged state, not a missing preference. In particular,
// never turn an unreadable queue or selection into an apparently empty library.
enum StudyPersistenceFiles {
    static func readIfPresent(_ file: URL, root: URL, maximumBytes: Int) throws -> Data? {
        try ShieldRuntime.requireIsolatedStateRead(from: file)
        var metadata = stat()
        guard lstat(file.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadUnknown)
        }
        let data = try AtomicFixtureStore(allowedRoot: root).read(file)
        guard data.count <= maximumBytes else {
            throw StudyDownloadError.invalidManifest("Saved library data is oversized. Its file was preserved.")
        }
        return data
    }
}

struct StudyLibrarySnapshot: Codable, Sendable {
    let version: Int
    let manifest: StudyManifest
    var completedIDs: Set<String>
    var failures: [String: String]
    var updatedAt: Date
    var inFlightIDs: Set<String>? = nil

    func validated() throws -> Self {
        guard version == 1, updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw StudyDownloadError.invalidManifest("Unsupported or invalid saved library state.")
        }
        _ = try manifest.validated()
        let ids = Set(manifest.videos.map(\.id))
        guard completedIDs.isSubset(of: ids), Set(failures.keys).isSubset(of: ids),
              (inFlightIDs ?? []).isSubset(of: ids),
              completedIDs.isDisjoint(with: failures.keys),
              completedIDs.isDisjoint(with: inFlightIDs ?? []) else {
            throw StudyDownloadError.invalidManifest("Saved library state has unknown or conflicting video status.")
        }
        return self
    }
}

struct StudyLibraryStore: Sendable {
    let root: URL
    private var stateURL: URL { root.appendingPathComponent("library-state.json") }

    func load() throws -> StudyLibrarySnapshot? {
        guard let data = try StudyPersistenceFiles.readIfPresent(stateURL, root: root,
                                                                maximumBytes: 1_048_576) else { return nil }
        return try JSONDecoder().decode(StudyLibrarySnapshot.self, from: data).validated()
    }

    func save(_ snapshot: StudyLibrarySnapshot) throws {
        try ShieldRuntime.requireIsolatedWrite(to: root)
        _ = try snapshot.validated()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 1_048_576 else { throw StudyDownloadError.invalidManifest("Library state is oversized.") }
        try AtomicFixtureStore(allowedRoot: root).write(data, to: stateURL)
    }

    // Only invoked after the user confirms a validated manifest. Preserve the
    // unreadable index and all media; revalidation determines new saved status.
    func rebuildIndex(using manifest: StudyManifest) throws {
        _ = try manifest.validated()
        if (try? load()) != nil {
            throw StudyDownloadError.invalidManifest("A readable library index cannot be replaced by recovery.")
        }
        let files = AtomicFixtureStore(allowedRoot: root)
        let original = try files.read(stateURL)
        let backup = root.appendingPathComponent("library-state.damaged-\(UUID()).json")
        try files.write(original, to: backup)
        try save(StudyLibrarySnapshot(version: 1, manifest: manifest, completedIDs: [],
                                      failures: [:], updatedAt: .now))
    }
}

struct StudyLibrarySelectionStore {
    let root: URL
    private var url: URL { root.appendingPathComponent("selected-course.json") }

    private struct Selection: Codable {
        enum Kind: String, Codable { case course, linkQueue }
        let version: Int
        let kind: Kind
        let courseTitle: String?

        init(manifest: StudyManifest) {
            version = 1
            kind = manifest.isLinkQueue ? .linkQueue : .course
            courseTitle = manifest.isLinkQueue ? nil : manifest.courseTitle
        }

        func validated() throws -> Self {
            guard version == 1 else {
                throw StudyDownloadError.invalidManifest("Unsupported saved course selection.")
            }
            switch kind {
            case .linkQueue:
                guard courseTitle == nil else { throw StudyDownloadError.invalidManifest("Invalid queue selection.") }
            case .course:
                guard let courseTitle, !courseTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      courseTitle.count <= 160,
                      !courseTitle.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw StudyDownloadError.invalidManifest("Invalid saved course title.")
                }
            }
            return self
        }

        func matches(_ manifest: StudyManifest) -> Bool {
            switch kind {
            case .linkQueue: manifest.isLinkQueue
            case .course: !manifest.isLinkQueue && manifest.courseTitle == courseTitle
            }
        }
    }

    func selectedCourse(in courses: [StudyManifest]) throws -> StudyManifest? {
        guard let data = try StudyPersistenceFiles.readIfPresent(url, root: root,
                                                                maximumBytes: 4_096) else { return nil }
        let matches: [StudyManifest]
        if let legacy = try? JSONDecoder().decode(String.self, from: data) {
            // Two historical formats used the same JSON string: a display title,
            // then a prefixed key. Neither wins if both identify a saved course.
            matches = courses.filter { $0.selectionKey == legacy || (!$0.isLinkQueue && $0.courseTitle == legacy) }
        } else {
            let selection = try JSONDecoder().decode(Selection.self, from: data).validated()
            matches = courses.filter(selection.matches)
        }
        guard matches.count <= 1 else {
            throw StudyDownloadError.invalidManifest("The saved selection matches more than one collection. Choose a collection to continue. Saved files are unchanged.")
        }
        return matches.first
    }

    func saveSelection(for manifest: StudyManifest) throws {
        _ = try manifest.validated()
        try ShieldRuntime.requireIsolatedWrite(to: url)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try AtomicFixtureStore(allowedRoot: root).write(JSONEncoder().encode(Selection(manifest: manifest)), to: url)
    }
}
