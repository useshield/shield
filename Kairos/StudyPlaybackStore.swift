import Foundation
import Darwin

struct StudyPlaybackPosition: Codable, Equatable, Sendable {
    let version: Int
    let videoID: String
    let seconds: TimeInterval
    let duration: TimeInterval
    let updatedAt: Date

    var finished: Bool { seconds >= duration - min(2, duration * 0.02) }
    var resumeSeconds: TimeInterval { finished ? 0 : seconds }
}

// Separate files keep player checkpoints from racing download/library updates.
struct StudyPlaybackStore: Sendable {
    let root: URL

    private func url(for id: String) throws -> URL {
        guard id.count == 11, id.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) ||
                (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { throw StudyDownloadError.unsafePath }
        return root.appendingPathComponent("\(id).playback.json")
    }

    func load(videoID: String) throws -> StudyPlaybackPosition? {
        let file = try url(for: videoID)
        try ShieldRuntime.requireIsolatedStateRead(from: file)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try AtomicFixtureStore(allowedRoot: root).read(file)
        guard data.count <= 4_096 else { throw StudyDownloadError.invalidMedia("Saved playback position is oversized.") }
        let value = try JSONDecoder().decode(StudyPlaybackPosition.self, from: data)
        guard value.version == 1, value.videoID == videoID,
              value.seconds.isFinite, value.duration.isFinite,
              value.duration > 0, value.seconds >= 0, value.seconds <= value.duration else {
            throw StudyDownloadError.invalidMedia("Saved playback position is invalid.")
        }
        return value
    }

    func save(videoID: String, seconds: TimeInterval, duration: TimeInterval) throws {
        guard seconds.isFinite, duration.isFinite, duration > 0, seconds >= 0 else {
            throw StudyDownloadError.invalidMedia("Playback has no valid position to save.")
        }
        let value = StudyPlaybackPosition(version: 1, videoID: videoID,
            seconds: min(seconds, duration), duration: duration, updatedAt: .now)
        try AtomicFixtureStore(allowedRoot: root).write(JSONEncoder().encode(value), to: url(for: videoID))
    }

    func reset(videoID: String) throws {
        let file = try url(for: videoID)
        try ShieldRuntime.requireIsolatedWrite(to: file)
        try AtomicFixtureStore(allowedRoot: root).validatePath(file)
        if FileManager.default.fileExists(atPath: file.path) {
            try AtomicFixtureStore(allowedRoot: root).remove(file)
        }
    }

    func mediaURL(videoID: String) throws -> URL {
        _ = try url(for: videoID)
        let file = root.appendingPathComponent("\(videoID).mp4")
        try ShieldRuntime.requireIsolatedStateRead(from: file)
        try AtomicFixtureStore(allowedRoot: root).validatePath(file)
        var info = stat()
        guard lstat(file.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size > 0 else {
            throw StudyDownloadError.invalidMedia("The saved video is missing. Import it again.")
        }
        return file
    }

    /// The transcript's timed lines; nil for videos saved before Shield kept them.
    func cues(videoID: String) throws -> [TranscriptCue]? {
        _ = try url(for: videoID)
        let file = root.appendingPathComponent("\(videoID).cues.json")
        try ShieldRuntime.requireIsolatedStateRead(from: file)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try AtomicFixtureStore(allowedRoot: root).read(file)
        guard data.count <= TranscriptCue.fileLimit else {
            throw StudyDownloadError.invalidMedia("The saved transcript timing is oversized.")
        }
        let cues = try TranscriptCue.decode(data)
        return cues.isEmpty ? nil : cues
    }

    func transcript(videoID: String) throws -> String? {
        _ = try url(for: videoID)
        let file = root.appendingPathComponent("\(videoID).txt")
        try ShieldRuntime.requireIsolatedStateRead(from: file)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let data = try AtomicFixtureStore(allowedRoot: root).read(file)
        guard data.count <= 2_000_000, let text = String(data: data, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudyDownloadError.invalidMedia("The saved transcript is not readable UTF-8 text.")
        }
        return text
    }
}
