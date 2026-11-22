import Darwin
import Foundation
import AVFoundation
import AudioToolbox
import CoreVideo

enum StudyBoundedFile {
    static func read(_ file: URL, limit: Int) throws -> Data {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw StudyDownloadError.unsafePath }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_nlink == 1,
              info.st_size >= 0, info.st_size <= limit else { throw StudyDownloadError.unsafePath }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw StudyDownloadError.unsafePath }
        return data
    }
}

// Retain the validated inode, not a pathname that a leftover subprocess could
// replace between status and read. Size/time checks also reject in-place edits.
// This is transfer integrity, not an immutable-file or hostile-root guarantee.
final class StudyOutputSnapshot {
    private let descriptor: Int32
    private let initial: stat
    let size: Int64

    init(file: URL, expectedSize: Int64, maximumSize: Int64) throws {
        guard file.isFileURL, expectedSize > 0, expectedSize <= maximumSize else {
            throw StudyDownloadError.unsafePath
        }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw StudyDownloadError.unsafePath }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_nlink == 1, info.st_uid == geteuid(), info.st_size == expectedSize else {
            close(fd)
            throw StudyDownloadError.unsafePath
        }
        descriptor = fd
        initial = info
        size = expectedSize
    }

    deinit { close(descriptor) }

    private func unchanged() -> Bool {
        var current = stat()
        return fstat(descriptor, &current) == 0 && current.st_size == initial.st_size &&
            current.st_mtimespec.tv_sec == initial.st_mtimespec.tv_sec &&
            current.st_mtimespec.tv_nsec == initial.st_mtimespec.tv_nsec &&
            current.st_ctimespec.tv_sec == initial.st_ctimespec.tv_sec &&
            current.st_ctimespec.tv_nsec == initial.st_ctimespec.tv_nsec
    }

    func read(offset: Int64) throws -> Data {
        guard offset >= 0, offset <= size, unchanged() else { throw StudyDownloadError.unsafePath }
        let wanted = Int(min(65_536, size - offset))
        if wanted == 0 { return Data() }
        var bytes = Data(count: wanted)
        let count = bytes.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Int in
            guard let address = buffer.baseAddress else { return -1 }
            return pread(descriptor, address, wanted, off_t(offset))
        }
        guard count == wanted, unchanged() else { throw StudyDownloadError.unsafePath }
        return bytes
    }
}

struct StudyVideo: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let expectedDuration: TimeInterval?
    let transcriptRequested: Bool
}


// Parser for one or many explicitly provided video URLs. The app and worker
// exchange exact IDs, not URLs, cookies, arbitrary hosts, or shell arguments.
// Unknown/bad links are counted so valid links survive a mixed paste.
struct StudyYouTubeLinks: Sendable {
    let ids: [String]
    let rejectedCount: Int
    let tooMany: Bool

    static func isValidID(_ id: String) -> Bool {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return id.utf8.count == 11 && id.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func parse(_ text: String) -> StudyYouTubeLinks {
        guard text.utf8.count <= 32_768 else {
            return StudyYouTubeLinks(ids: [], rejectedCount: 0, tooMany: true)
        }
        let tokens = text.split(whereSeparator: { $0.isWhitespace || $0 == "," })
        guard tokens.count <= 100 else {
            return StudyYouTubeLinks(ids: [], rejectedCount: tokens.count, tooMany: true)
        }
        var ids: [String] = []
        var rejected = 0
        for token in tokens {
            guard let components = URLComponents(string: String(token)),
                  components.scheme == "https", components.user == nil,
                  components.password == nil, components.port == nil,
                  components.fragment == nil, let host = components.host?.lowercased(),
                  components.percentEncodedPath == components.path else {
                rejected += 1
                continue
            }
            let pieces = components.path.split(separator: "/")
            let videoParameters = components.queryItems?.filter { $0.name == "v" } ?? []
            let id: String?
            if host == "youtu.be" {
                id = pieces.count == 1 && components.path == "/\(pieces[0])" && videoParameters.isEmpty
                    ? String(pieces[0]) : nil
            } else if ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host) {
                if components.path == "/watch" {
                    id = videoParameters.count == 1 ? videoParameters[0].value : nil
                } else if pieces.count == 2 && (pieces[0] == "shorts" || pieces[0] == "live") &&
                            components.path == "/\(pieces[0])/\(pieces[1])" && videoParameters.isEmpty {
                    id = String(pieces[1])
                } else {
                    id = nil
                }
            } else {
                id = nil
            }
            guard let id, isValidID(id) else {
                rejected += 1
                continue
            }
            if !ids.contains(id) { ids.append(id) }
        }
        return StudyYouTubeLinks(ids: ids, rejectedCount: rejected, tooMany: false)
    }
}


// Only explicitly selected MP4 files or immediate regular children of a picked
// folder may be considered for import. Do not recursively walk private trees.
struct StudyMediaSourceSelection {
    static func collect(from selections: [URL], maximumFiles: Int = 4_000) throws -> [URL] {
        guard !selections.isEmpty, selections.count <= 100,
              maximumFiles > 0, maximumFiles <= 4_000 else {
            throw StudyDownloadError.invalidManifest("Choose 1–100 MP4 files or folders.")
        }
        var result: [URL] = []
        var seen = Set<String>()
        func add(_ candidate: URL) throws {
            guard candidate.isFileURL else { throw StudyDownloadError.unsafePath }
            var info = stat()
            guard lstat(candidate.path, &info) == 0 else {
                throw StudyDownloadError.unsafePath
            }
            // Symlinks, pipes, devices, and nested folders are not media.
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return }
            let kind = candidate.pathExtension.lowercased()
            guard kind == "mp4" || kind == "txt" else { return }
            // macOS exposes /var/... and /private/var/... for the same inode.
            // Canonicalize only after lstat rejects symlink leaves. This keeps
            // explicit file + containing-folder selections from double-importing.
            let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
            let path = canonical.path
            if seen.insert(path).inserted {
                result.append(canonical)
                guard result.count <= maximumFiles else {
                    throw StudyDownloadError.invalidManifest("Too many media files in selection.")
                }
            }
        }
        for selected in selections {
            guard selected.isFileURL else { throw StudyDownloadError.unsafePath }
            var info = stat()
            guard lstat(selected.path, &info) == 0 else {
                throw StudyDownloadError.unsafePath
            }
            switch info.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFREG):
                try add(selected)
            case mode_t(S_IFDIR):
                let children = try FileManager.default.contentsOfDirectory(
                    at: selected, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])
                guard children.count <= maximumFiles else {
                    throw StudyDownloadError.invalidManifest("Selected folder has too many files.")
                }
                for child in children { try add(child) }
            default:
                throw StudyDownloadError.unsafePath
            }
        }
        return result.sorted { $0.path < $1.path }
    }
}

struct StudyMediaImportMatcher {
    static func candidates(for id: String, in files: [URL]) -> [URL] {
        files.filter { url in
            guard url.pathExtension.lowercased() == "mp4" else { return false }
            let stem = url.deletingPathExtension().lastPathComponent
            return stem == id || stem.hasSuffix("[\(id)]")
        }
    }
}

struct StudyMediaImportStager {
    static func copy(from source: URL, to destination: URL, maximumBytes: Int64 = 4_000_000_000) async throws {
        let task = Task.detached { try copyRegularFile(from: source, to: destination, maximumBytes: maximumBytes) }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    static func copyRegularFile(from source: URL, to destination: URL,
                                maximumBytes: Int64 = 4_000_000_000) throws {
        try Task.checkCancellation()
        guard ShieldRuntime.allowsLocalMediaImport else { throw StudyDownloadError.unsafePath }
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else {
            if errno == EACCES || errno == EPERM {
                throw StudyDownloadError.permissionDenied("The selected video cannot be read.")
            }
            throw StudyDownloadError.unsafePath
        }
        defer { close(input) }
        var metadata = stat()
        guard fstat(input, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_size > 0, metadata.st_size <= maximumBytes else {
            throw StudyDownloadError.unsafePath
        }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else {
            if errno == EACCES || errno == EPERM {
                throw StudyDownloadError.permissionDenied("The private staging directory cannot be written.")
            }
            throw StudyDownloadError.unsafePath
        }
        defer { close(output) }
        let reader = FileHandle(fileDescriptor: input, closeOnDealloc: false)
        let writer = FileHandle(fileDescriptor: output, closeOnDealloc: false)
        var copied: Int64 = 0
        while let chunk = try reader.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            copied += Int64(chunk.count)
            guard copied <= metadata.st_size else { throw StudyDownloadError.unsafePath }
            try writer.write(contentsOf: chunk)
        }
        guard copied == metadata.st_size, fsync(output) == 0 else { throw StudyDownloadError.unsafePath }
    }
}

enum StudyStorageBudget {
    // Staging, possible compatibility conversion and atomic publication may
    // coexist. Leave headroom for state writes; never reclaim user files.
    static func requiredBytes(sourceBytes: Int64) throws -> Int64 {
        guard sourceBytes > 0, sourceBytes <= 4_000_000_000 else {
            throw StudyDownloadError.invalidMedia("Video is empty or larger than the 4 GB limit.")
        }
        return sourceBytes * 3 + 268_435_456
    }

    static func requireCapacity(at directory: URL, sourceBytes: Int64) throws {
        let required = try requiredBytes(sourceBytes: sourceBytes)
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage, available >= required else {
            throw StudyDownloadError.invalidMedia("Not enough free space to stage and validate this video. Free disk space and retry; saved videos and originals are unchanged.")
        }
    }
}

struct StudyTools: Sendable {
    let ytdlp: URL
    let deno: URL
    let ffmpeg: URL
    let ffprobe: URL

    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         searchRoots: [URL] = [URL(fileURLWithPath: "/opt/homebrew/bin"),
                                               URL(fileURLWithPath: "/usr/local/bin")],
                         contained: Bool = false) throws -> Self {
        // Unconfined tools stay limited to disposable fixtures; contained
        // tools run only under StudyContainment's Seatbelt profile.
        guard ShieldRuntime.allowsExternalTools || contained else { throw StudyDownloadError.unsafePath }
        let roots = [home.appendingPathComponent(".local/bin")] + searchRoots
        func find(_ name: String) throws -> URL {
            for root in roots {
                // Homebrew links bin/ffmpeg into its Cellar; the checks apply to the resolved file.
                let linked = root.appendingPathComponent(name)
                var info = stat()
                guard lstat(linked.path, &info) == 0 else { continue }
                let candidate = linked.resolvingSymlinksInPath()
                guard lstat(candidate.path, &info) == 0 else { throw StudyDownloadError.unsafePath }
                guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                      (info.st_mode & 0o022) == 0,
                      (info.st_uid == geteuid() || info.st_uid == 0),
                      FileManager.default.isExecutableFile(atPath: candidate.path) else {
                    throw StudyDownloadError.unsafePath
                }
                return candidate
            }
            throw StudyDownloadError.missingTool(name)
        }
        return try Self(ytdlp: find("yt-dlp"), deno: find("deno"),
                        ffmpeg: find("ffmpeg"), ffprobe: find("ffprobe"))
    }

    func versions() async throws -> [String: String] {
        var result: [String: String] = [:]
        for (name, url) in [("yt-dlp", ytdlp), ("deno", deno),
                            ("ffmpeg", ffmpeg), ("ffprobe", ffprobe)] {
            guard url.isFileURL, FileManager.default.isExecutableFile(atPath: url.path) else {
                throw StudyDownloadError.missingTool(name)
            }
            let process = Process()
            process.executableURL = url
            process.arguments = ["-version"]
            if name == "yt-dlp" || name == "deno" { process.arguments = ["--version"] }
            process.environment = ["PATH": "/usr/bin:/bin"]
            process.standardError = FileHandle.nullDevice
            let data = try await StudyProcessRunner().captureOutput(process, timeout: 10)
            guard process.terminationStatus == 0 else {
                throw StudyDownloadError.processFailed(name, process.terminationStatus)
            }
            guard data.count < 65_536,
                  let line = String(data: data, encoding: .utf8)?.split(separator: "\n").first,
                  !line.isEmpty else { throw StudyDownloadError.invalidMedia("Invalid tool version output.") }
            result[name] = String(line.prefix(160))
        }
        guard let yt = result["yt-dlp"]?.split(separator: ".").prefix(3).compactMap({ Int($0) }),
              yt.count == 3, yt.lexicographicallyPrecedes([2025, 1, 1]) == false else {
            throw StudyDownloadError.invalidMedia("yt-dlp must be dated 2025.01.01 or newer.")
        }
        guard result["deno"]?.hasPrefix("deno 2.") == true else {
            throw StudyDownloadError.invalidMedia("Deno 2.x is required for the approved extractor.")
        }
        func major(_ name: String) -> Int? {
            let parts = result[name]?.split(separator: " ") ?? []
            guard parts.count >= 3, parts[0] == name, parts[1] == "version" else { return nil }
            return Int(parts[2].split(separator: ".").first ?? "")
        }
        guard let ffmpegMajor = major("ffmpeg"), ffmpegMajor >= 6,
              major("ffprobe") == ffmpegMajor else {
            throw StudyDownloadError.invalidMedia("Matching FFmpeg and ffprobe version 6 or newer are required.")
        }
        return result
    }
}

struct StudyManifest: Codable, Sendable {
    let schemaVersion: Int
    let courseTitle: String
    let videos: [StudyVideo]
    enum Origin: String, Codable, Sendable { case linkQueue }
    var origin: Origin? = nil
    var isLinkQueue: Bool { origin == .linkQueue }
    var selectionKey: String { isLinkQueue ? "queue:links-v1" : "course:" + courseTitle }

    nonisolated func validated() throws -> StudyManifest {
        guard schemaVersion == 1 else {
            throw StudyDownloadError.invalidManifest("Unsupported schema version.")
        }
        guard !courseTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              courseTitle.count <= 160,
              !courseTitle.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw StudyDownloadError.invalidManifest("Course title is empty, oversized, or contains control characters.")
        }
        guard !videos.isEmpty, videos.count <= (isLinkQueue ? 1_000 : 100) else {
            throw StudyDownloadError.invalidManifest("No approved videos.")
        }
        guard Set(videos.map(\.id)).count == videos.count else {
            throw StudyDownloadError.invalidManifest("Video IDs must be unique.")
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        for video in videos {
            guard video.id.count == 11,
                  video.id.unicodeScalars.allSatisfy(allowed.contains),
                  !video.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  video.title.count <= 160,
                  !video.title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  video.expectedDuration.map({ $0.isFinite && $0 >= 1 && $0 <= 28_800 }) != false else {
                throw StudyDownloadError.invalidManifest("Invalid video entry.")
            }
        }
        return self
    }
}

enum StudyJobState: Equatable, Sendable {
    case queued
    case downloading(attempt: Int)
    case validating
    case complete(MediaValidation)
    case failed(String)
}

struct StudyJob: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    var state: StudyJobState
    var progress: Double? = nil
    /// What's happening when it isn't plain downloading, e.g. "Trying another
    /// way (2 of 4)…" after YouTube refused a try (A refused
    /// video sat on "Downloading…" for minutes with nothing to show why).
    var note: String? = nil
}

struct MediaValidation: Equatable, Sendable {
    let duration: TimeInterval
    let hasVideo: Bool
    let hasAudio: Bool
    let fileSize: Int64
    let transcriptPresent: Bool

    var isPlayable: Bool { hasVideo && hasAudio && duration.isFinite && duration > 0 && fileSize > 0 && fileSize <= 4_000_000_000 }
}

enum StudyDownloadError: Error, LocalizedError, Sendable {
    case invalidManifest(String)
    case missingTool(String)
    case processFailed(String, Int32)
    case toolReported(String, String)
    case invalidMedia(String)
    case unsafePath
    case permissionDenied(String)
    case cancelled
    case timedOut(String)
    /// The tool printed nothing for too long (a hung connection).
    case stalled(String)

    var errorDescription: String? {
        switch self {
        case .invalidManifest(let detail): "Invalid study manifest: \(detail)"
        case .missingTool(let tool): "Required tool is unavailable: \(tool)."
        case .processFailed(let tool, let code): "\(tool) exited with status \(code)."
        case .toolReported(_, let reason): reason
        case .invalidMedia(let detail): detail
        case .unsafePath: "The requested output path is unsafe."
        case .permissionDenied(let detail): "Permission denied: \(detail)"
        case .cancelled: "Download was cancelled."
        case .timedOut(let tool): "\(tool) exceeded its time limit."
        case .stalled(let tool): "\(tool) stopped making progress."
        }
    }
}

protocol MediaValidating: Sendable {
    func validate(
        mediaURL: URL,
        expectedDuration: TimeInterval?,
        transcriptURL: URL?
    ) async throws -> MediaValidation
}

// Local import uses Apple's media reader in the app process. It makes no
// external process or network request. Downloaded media retains the stronger
// FFmpeg sample validation path when a contained downloader becomes available.
struct NativeLocalMediaValidator: MediaValidating {
    let durationTolerance: TimeInterval = 5

    func validate(mediaURL: URL, expectedDuration: TimeInterval?,
                  transcriptURL: URL?) async throws -> MediaValidation {
        guard mediaURL.isFileURL, mediaURL.pathExtension.lowercased() == "mp4" else {
            throw StudyDownloadError.unsafePath
        }
        var info = stat()
        guard lstat(mediaURL.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw StudyDownloadError.unsafePath
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: mediaURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0, fileSize <= 4_000_000_000 else {
            throw StudyDownloadError.invalidMedia("Local video is empty or oversized.")
        }
        let asset = AVURLAsset(url: mediaURL)
        let playable = try await asset.load(.isPlayable)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard playable, duration.isFinite, duration > 0,
              !videoTracks.isEmpty, !audioTracks.isEmpty else {
            throw StudyDownloadError.invalidMedia("Local MP4 needs playable video, audio, and duration.")
        }
        if let expectedDuration, abs(duration - expectedDuration) > durationTolerance {
            throw StudyDownloadError.invalidMedia("Duration differs from the approved manifest.")
        }
        // Decode actual samples, including near the end. Readable metadata alone
        // must not promote a damaged file to a playable saved video.
        for start in [0.0, max(0, duration - 2)] {
            try Task.checkCancellation()
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                          duration: CMTime(seconds: min(2, duration), preferredTimescale: 600))
            let video = AVAssetReaderTrackOutput(track: videoTracks[0],
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            let audio = AVAssetReaderTrackOutput(track: audioTracks[0],
                outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            guard reader.canAdd(video), reader.canAdd(audio) else {
                throw StudyDownloadError.invalidMedia("Saved tracks cannot be decoded.")
            }
            reader.add(video); reader.add(audio)
            guard reader.startReading(), video.copyNextSampleBuffer() != nil,
                  audio.copyNextSampleBuffer() != nil else {
                reader.cancelReading()
                throw StudyDownloadError.invalidMedia("Video or audio failed a native decode sample.")
            }
            reader.cancelReading()
        }
        return MediaValidation(duration: duration, hasVideo: true, hasAudio: true,
                               fileSize: fileSize,
                               transcriptPresent: transcriptURL.map {
                                   FileManager.default.fileExists(atPath: $0.path)
                               } ?? false)
    }
}

struct NativeMediaPreparer {
    func prepare(_ source: URL, expectedDuration: TimeInterval?) async throws -> URL {
        do {
            _ = try await NativeLocalMediaValidator().validate(mediaURL: source,
                expectedDuration: expectedDuration, transcriptURL: nil)
            return source
        } catch let error as StudyDownloadError {
            guard case .invalidMedia(let detail) = error,
                  !detail.hasPrefix("Duration differs") else { throw error }
            let asset = AVURLAsset(url: source)
            guard try await asset.load(.isExportable),
                  let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                throw error
            }
            let destination = source.deletingPathExtension().appendingPathExtension("compatible.mp4")
            do {
                try await withTaskCancellationHandler {
                    try await export.export(to: destination, as: .mp4)
                } onCancel: { export.cancelExport() }
                try Task.checkCancellation()
                _ = try await NativeLocalMediaValidator().validate(mediaURL: destination,
                    expectedDuration: expectedDuration, transcriptURL: nil)
                return destination
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }
    }
}

protocol RestrictedVideoFetching: Sendable {
    func fetch(video: StudyVideo, stagingDirectory: URL) async throws -> URL
    func fetch(video: StudyVideo, stagingDirectory: URL,
               onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL
    /// `onRetry(try, of)` runs when a refused try moves on to another way.
    func fetch(video: StudyVideo, stagingDirectory: URL,
               onProgress: @escaping @Sendable (Double) -> Void,
               onRetry: @escaping @Sendable (Int, Int) -> Void) async throws -> URL
}

extension RestrictedVideoFetching {
    func fetch(video: StudyVideo, stagingDirectory: URL,
               onProgress: @escaping @Sendable (Double) -> Void,
               onRetry: @escaping @Sendable (Int, Int) -> Void) async throws -> URL {
        try await fetch(video: video, stagingDirectory: stagingDirectory, onProgress: onProgress)
    }

    func fetch(video: StudyVideo, stagingDirectory: URL,
               onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await fetch(video: video, stagingDirectory: stagingDirectory)
    }
}

// One yt-dlp run's progress, from lines "<marker>ext|vcodec|acodec|percent".
// A video-only stream counts for 0–90% and the audio stream after it for
// 90–100%, so a video+audio download never jumps back; reports only rise.
/// When a tool last printed anything, in system uptime.
final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTouch = ProcessInfo.processInfo.systemUptime
    private var errorLogSize = 0
    var last: TimeInterval { lock.withLock { lastTouch } }
    func touch() { lock.withLock { lastTouch = ProcessInfo.processInfo.systemUptime } }
    /// Growth of the error log counts as activity too.
    func note(errorLogSize size: Int) {
        lock.withLock {
            if size != errorLogSize { errorLogSize = size; lastTouch = ProcessInfo.processInfo.systemUptime }
        }
    }
}

private final class DownloadProgressParser: @unchecked Sendable {
    static let marker = "shield-progress:"
    private let lock = NSLock()
    private var pending = ""
    private var reported = -1.0
    private var finished = false
    private var sizeLimitLine = false
    private let onProgress: @Sendable (Double) -> Void

    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    // Callbacks run under the lock, so none can still be running, or start, after this.
    func finish() {
        lock.lock(); defer { lock.unlock() }
        finished = true
    }

    // yt-dlp said it skipped a file over --max-filesize.
    var sawSizeLimit: Bool { lock.lock(); defer { lock.unlock() }; return sizeLimitLine }

    func append(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        pending += text
        let lines = pending.components(separatedBy: "\n")
        pending = String((lines.last ?? "").suffix(16_384))
        for line in lines.dropLast() {
            if line.contains("max-filesize") { sizeLimitLine = true }
            guard line.hasPrefix(Self.marker),
                  let value = Self.fraction(line.dropFirst(Self.marker.count)), value > reported else { continue }
            reported = value
            onProgress(value)
        }
    }

    static func fraction<S: StringProtocol>(_ fields: S) -> Double? {
        let parts = fields.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 4, parts[0] != "vtt",   // the captions file
              let percent = Double(parts[3].replacingOccurrences(of: "%", with: "")), percent.isFinite else { return nil }
        let part = min(1, max(0, percent / 100))
        if parts[1] == "none" { return 0.9 + part * 0.1 }   // audio after the video
        if parts[2] == "none" { return part * 0.9 }          // video without audio
        return part
    }
}

struct StudyProcessRunner: Sendable {
    let launcherURL: URL?
    // True only for a StudyContainment job: the process must then be sandbox-exec.
    let confined: Bool

    init(launcherURL: URL? = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/StudyToolLauncher"),
         confined: Bool = false) {
        self.launcherURL = launcherURL
        self.confined = confined
    }

    func run(_ process: Process, timeout: TimeInterval) async throws {
        try await run(process, timeout: timeout, capture: nil, stall: nil)
    }

    /// Also stops the tool once `lastActivity` (system uptime of its last
    /// output) is older than `stallLimit`: a hung download used to sit until
    /// the hour limit, then try again for another hour (audit).
    func run(_ process: Process, timeout: TimeInterval, stallLimit: TimeInterval,
             lastActivity: @escaping @Sendable () -> TimeInterval) async throws {
        try await run(process, timeout: timeout, capture: nil, stall: (stallLimit, lastActivity))
    }

    func captureOutput(_ process: Process, timeout: TimeInterval, maximumBytes: Int = 65_536) async throws -> Data {
        let capture = try StudyProcessOutput(maximumBytes: maximumBytes)
        process.standardOutput = capture.pipe
        defer { capture.close() }
        try await run(process, timeout: timeout, capture: capture, stall: nil)
        return capture.data
    }

    private func run(_ process: Process, timeout: TimeInterval, capture: StudyProcessOutput?,
                     stall: (limit: TimeInterval, lastActivity: @Sendable () -> TimeInterval)?) async throws {
        let contained = confined && StudyContainment.enabled && process.executableURL == StudyContainment.sandboxExec
        guard ShieldRuntime.allowsExternalTools || contained else { throw StudyDownloadError.unsafePath }
        guard let launcherURL, FileManager.default.isExecutableFile(atPath: launcherURL.path),
              let originalTool = process.executableURL, originalTool.isFileURL else {
            throw StudyDownloadError.missingTool("contained study tool launcher")
        }
        try Task.checkCancellation()
        process.arguments = [originalTool.path] + (process.arguments ?? [])
        process.executableURL = launcherURL
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Child has its duplicate. Closing our writer makes EOF meaningful;
        // nonblocking reads prevent a full ffprobe pipe from deadlocking it.
        try? capture?.pipe.fileHandleForWriting.close()
        let pid = process.processIdentifier
        let groupDeadline = ProcessInfo.processInfo.systemUptime + 1
        while process.isRunning && getpgid(pid) != pid && ProcessInfo.processInfo.systemUptime < groupDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let ownsProcessGroup = getpgid(pid) == pid
        if process.isRunning && !ownsProcessGroup {
            process.terminate()
            throw StudyDownloadError.processFailed("study tool launcher", 125)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        do {
            while process.isRunning {
                try Task.checkCancellation()
                try capture?.drain()
                let now = ProcessInfo.processInfo.systemUptime
                if now >= deadline { throw StudyDownloadError.timedOut(originalTool.lastPathComponent) }
                if let stall, now - stall.lastActivity() >= stall.limit {
                    throw StudyDownloadError.stalled(originalTool.lastPathComponent)
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try capture?.drain()
        } catch {
            await terminate(process, ownsGroup: ownsProcessGroup)
            throw Task.isCancelled ? StudyDownloadError.cancelled : error
        }
        // A tool that exits while leaving descendants behind must not leave
        // those processes running in the user's session.
        if ownsProcessGroup && kill(-pid, 0) == 0 { await terminate(process, ownsGroup: true) }
    }

    private func terminate(_ process: Process, ownsGroup: Bool) async {
        let pid = process.processIdentifier
        func stillRunning() -> Bool { ownsGroup ? kill(-pid, 0) == 0 : process.isRunning }
        if ownsGroup { _ = kill(-pid, SIGTERM) }
        else if process.isRunning { process.terminate() }
        let grace = ProcessInfo.processInfo.systemUptime + 2
        while stillRunning() && ProcessInfo.processInfo.systemUptime < grace {
            // Cancellation of this task must not turn the cleanup wait into a spin.
            await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
        }
        if stillRunning() { _ = kill(ownsGroup ? -pid : pid, SIGKILL) }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
        }
    }
}

private final class StudyProcessOutput {
    let pipe = Pipe()
    private let maximumBytes: Int
    private(set) var data = Data()

    init(maximumBytes: Int) throws {
        guard maximumBytes > 0, maximumBytes <= 2_000_000 else { throw StudyDownloadError.unsafePath }
        self.maximumBytes = maximumBytes
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw StudyDownloadError.unsafePath
        }
    }

    func drain() throws {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        // The byte cap bounds each drain, even if a hostile tool writes forever.
        while true {
            let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &buffer, 16_384)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                throw StudyDownloadError.unsafePath
            }
            guard count <= maximumBytes - data.count else {
                throw StudyDownloadError.invalidMedia("Tool output exceeded its inspection limit.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    func close() {
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
    }
}

struct FFprobeMediaValidator: MediaValidating {
    let ffprobeURL: URL
    let ffmpegURL: URL?
    let durationTolerance: TimeInterval

    init(
        ffprobeURL: URL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe"),
        ffmpegURL: URL? = nil,
        durationTolerance: TimeInterval = 5
    ) {
        self.ffprobeURL = ffprobeURL
        self.ffmpegURL = ffmpegURL
        self.durationTolerance = durationTolerance
    }

    func validate(
        mediaURL: URL,
        expectedDuration: TimeInterval?,
        transcriptURL: URL?
    ) async throws -> MediaValidation {
        guard mediaURL.isFileURL else { throw StudyDownloadError.unsafePath }
        guard FileManager.default.isExecutableFile(atPath: ffprobeURL.path) else {
            throw StudyDownloadError.missingTool("ffprobe")
        }

        let process = Process()
        process.executableURL = ffprobeURL
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": mediaURL.deletingLastPathComponent().path]
        process.arguments = [
            "-v", "error",
            "-show_entries", "format=duration:stream=codec_type",
            "-of", "json",
            mediaURL.path
        ]
        process.standardError = FileHandle.nullDevice

        let data = try await StudyProcessRunner().captureOutput(process, timeout: 30)
        guard process.terminationStatus == 0 else {
            throw StudyDownloadError.processFailed("ffprobe", process.terminationStatus)
        }

        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let format = object?["format"] as? [String: Any]
        let duration = (format?["duration"] as? String).flatMap(TimeInterval.init) ?? 0
        let streams = object?["streams"] as? [[String: Any]] ?? []
        let codecTypes = Set(streams.compactMap { $0["codec_type"] as? String })
        let attributes = try FileManager.default.attributesOfItem(atPath: mediaURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        guard duration.isFinite, duration > 0, codecTypes.contains("video"), codecTypes.contains("audio"),
              fileSize > 0, fileSize <= 4_000_000_000 else {
            throw StudyDownloadError.invalidMedia("Missing playable audio, video, duration, or bytes.")
        }
        if let expectedDuration, abs(duration - expectedDuration) > durationTolerance {
            throw StudyDownloadError.invalidMedia("Duration differs from the approved manifest.")
        }
        if let ffmpegURL {
            guard FileManager.default.isExecutableFile(atPath: ffmpegURL.path) else {
                throw StudyDownloadError.missingTool("ffmpeg")
            }
            for seek in [false, true] {
                let decode = Process()
                decode.executableURL = ffmpegURL
                decode.environment = ["PATH": "/usr/bin:/bin"]
                decode.arguments = ["-nostdin", "-v", "error", "-xerror"]
                    + (seek ? ["-sseof", "-5"] : [])
                    + ["-i", mediaURL.path, "-t", "5", "-map", "0:v:0", "-map", "0:a:0",
                       "-f", "null", "-"]
                decode.standardOutput = FileHandle.nullDevice
                decode.standardError = FileHandle.nullDevice
                try await StudyProcessRunner().run(decode, timeout: 90)
                guard decode.terminationStatus == 0 else {
                    throw StudyDownloadError.invalidMedia("Video or audio failed a decode sample.")
                }
            }
        }

        return MediaValidation(
            duration: duration,
            hasVideo: true,
            hasAudio: true,
            fileSize: fileSize,
            transcriptPresent: transcriptURL.map {
                FileManager.default.fileExists(atPath: $0.path)
            } ?? false
        )
    }
}

/// Turns a saved file Apple's player can't play (VP9, AV1, Opus) into H.264/AAC MP4.
protocol MediaRepairing: Sendable {
    func prepare(_ source: URL, force: Bool) async throws -> URL
}

extension MediaCompatibilityRepairer: MediaRepairing {}

struct MediaCompatibilityRepairer: Sendable {
    let ffprobeURL: URL
    let ffmpegURL: URL

    private struct Inspection {
        let container: String
        let video: String
        let audio: String

        var isCompatible: Bool {
            video == "h264" && audio == "aac" &&
                container.split(separator: ",").contains(where: { $0 == "mp4" || $0 == "mov" })
        }
    }

    func prepare(_ source: URL, force: Bool = false) async throws -> URL {
        guard source.isFileURL, ffprobeURL.isFileURL, ffmpegURL.isFileURL,
              FileManager.default.isExecutableFile(atPath: ffprobeURL.path),
              FileManager.default.isExecutableFile(atPath: ffmpegURL.path) else {
            throw StudyDownloadError.missingTool("ffprobe or ffmpeg")
        }
        let inspection = try await inspect(source)
        if !force && inspection.isCompatible { return source }
        let repaired = source.deletingPathExtension().appendingPathExtension("compatible.mp4")
        let transcode = Process()
        transcode.executableURL = ffmpegURL
        transcode.environment = ["PATH": "/usr/bin:/bin", "HOME": source.deletingLastPathComponent().path]
        transcode.arguments = ["-nostdin", "-v", "error", "-xerror", "-n", "-i", source.path,
                               "-map", "0:v:0", "-map", "0:a:0", "-c:v", "libx264",
                               "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p",
                               "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart",
                               repaired.path]
        transcode.standardOutput = FileHandle.nullDevice
        transcode.standardError = FileHandle.nullDevice
        try await StudyProcessRunner().run(transcode, timeout: 5_400)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: repaired.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard transcode.terminationStatus == 0, bytes > 0 else {
            throw StudyDownloadError.invalidMedia("Compatibility repair did not produce H.264/AAC MP4 media.")
        }
        let repairedInspection = try await inspect(repaired)
        guard repairedInspection.isCompatible else {
            throw StudyDownloadError.invalidMedia("Compatibility repair produced incompatible codecs.")
        }
        return repaired
    }

    private func inspect(_ source: URL) async throws -> Inspection {
        let probe = Process()
        probe.executableURL = ffprobeURL
        probe.environment = ["PATH": "/usr/bin:/bin"]
        probe.arguments = ["-v", "error", "-show_entries",
                           "format=format_name:stream=codec_type,codec_name",
                           "-of", "json", source.path]
        probe.standardError = FileHandle.nullDevice
        let data = try await StudyProcessRunner().captureOutput(probe, timeout: 30)
        guard probe.terminationStatus == 0 else {
            throw StudyDownloadError.processFailed("ffprobe", probe.terminationStatus)
        }
        guard data.count <= 65_536,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let streams = object["streams"] as? [[String: Any]],
              let container = (object["format"] as? [String: Any])?["format_name"] as? String,
              let video = streams.first(where: { $0["codec_type"] as? String == "video" })?["codec_name"] as? String,
              let audio = streams.first(where: { $0["codec_type"] as? String == "audio" })?["codec_name"] as? String else {
            throw StudyDownloadError.invalidMedia("Codec or container inspection is incomplete.")
        }
        return Inspection(container: container, video: video, audio: audio)
    }
}

struct YTDLPRestrictedFetcher: RestrictedVideoFetching {
    struct Containment: Sendable {
        // Starts a fresh egress broker, and the Seatbelt profile for its
        // port, for one yt-dlp run; so no broker outlives its lifetime mid-download.
        let start: @Sendable () throws -> Session
        // Private per-job copy inside staging (StudyCookies), or nil.
        var cookies: URL? = nil
    }
    struct Session: Sendable {
        let profile: URL
        let proxyURL: String
        let stop: @Sendable () -> Void
    }
    let ytdlpURL: URL
    let denoURL: URL
    let ffmpegLocation: URL
    // When set, yt-dlp and its children run under the Seatbelt profile and
    // reach the network only through the per-job egress broker.
    var containment: Containment? = nil
    /// Tallest video to download (see `qualities`).
    var maxHeight: Int = YTDLPRestrictedFetcher.defaultQuality

    func fetch(video: StudyVideo, stagingDirectory: URL) async throws -> URL {
        try await fetch(video: video, stagingDirectory: stagingDirectory, onProgress: { _ in })
    }

    func fetch(video: StudyVideo, stagingDirectory: URL,
               onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await fetch(video: video, stagingDirectory: stagingDirectory, onProgress: onProgress, onRetry: { _, _ in })
    }

    func fetch(video: StudyVideo, stagingDirectory: URL,
               onProgress: @escaping @Sendable (Double) -> Void,
               onRetry: @escaping @Sendable (Int, Int) -> Void) async throws -> URL {
        _ = try StudyManifest(
            schemaVersion: 1,
            courseTitle: "Single approved item",
            videos: [video]
        ).validated()

        guard stagingDirectory.isFileURL else { throw StudyDownloadError.unsafePath }
        for tool in [ytdlpURL, denoURL, ffmpegLocation] {
            guard tool.isFileURL, FileManager.default.isExecutableFile(atPath: tool.path) else {
                throw StudyDownloadError.missingTool(tool.lastPathComponent)
            }
        }

        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let outputTemplate = stagingDirectory
            .appendingPathComponent("\(video.id).%(ext)s").path
        // YouTube sometimes refuses one player client's media links (HTTP 403)
        // while others work, so other clients are tried before giving up;
        // partial files from a refused try are removed first.
        // Measured Nov 15: without the sign-in YouTube hands out whole files
        // (a 5-minute lesson in about 30 s); signed in, it hands out hundreds of
        // small pieces (about 2 minutes). So the sign-in is kept for when
        // YouTube asks for it ("confirm you're not a bot"), not tried first.
        // The way that last worked goes first (When YouTube
        // refuses one way for a while, every video paid ~20 s per refused try).
        let attempts = WorkingWay.ordered(Self.attempts(hasSignIn: containment?.cookies != nil))
        var index = 0
        while index < attempts.count {
            let attempt = attempts[index]
            do {
                let tooLarge: Bool
                do {
                    tooLarge = try await runYTDLP(video: video, stagingDirectory: stagingDirectory,
                                                  outputTemplate: outputTemplate, extraArguments: attempt.clients,
                                                  useSignIn: attempt.signIn, subtitles: video.transcriptRequested,
                                                  onProgress: onProgress)
                } catch let error as StudyDownloadError where video.transcriptRequested && Self.isSubtitleFailure(error) {
                    // Only the captions failed: the same try once more without
                    // them, so the video still saves (without a transcript).
                    try Task.checkCancellation()
                    Self.removePartialDownloads(in: stagingDirectory)
                    tooLarge = try await runYTDLP(video: video, stagingDirectory: stagingDirectory,
                                                  outputTemplate: outputTemplate, extraArguments: attempt.clients,
                                                  useSignIn: attempt.signIn, subtitles: false, onProgress: onProgress)
                }
                let output = try finishFetch(video: video, stagingDirectory: stagingDirectory, tooLarge: tooLarge)
                WorkingWay.worked(attempt)
                return output
            } catch let error as StudyDownloadError {
                WorkingWay.failed(attempt)
                // Each refused way's own reason, for the next diagnosis (the
                // last try's reason alone hid why the others failed).
                if containment != nil { DownloadProblemLog.note(videoID: video.id, way: attempt, error: error) }
                guard index < attempts.count - 1, Self.isRetryable(error), !Self.isRateLimited(error) else { throw error }
                // A rate limit (429) is left to the coordinator's pause; another client now would only be refused too.
                try Task.checkCancellation()
                Self.removePartialDownloads(in: stagingDirectory)
                // A sign-in check goes straight to the signed-in try, if there is one.
                if Self.asksForSignIn(error), let signed = attempts.indices.first(where: { $0 > index && attempts[$0].signIn }) {
                    index = signed
                } else {
                    index += 1
                }
                onRetry(index + 1, attempts.count)
            }
        }
        throw StudyDownloadError.processFailed("yt-dlp", 1)   // unreachable: the last try throws or returns
    }

    /// Player clients to try in order: yt-dlp's default, then two other sets.
    /// None uses `web_embedded`: since Nov 2026 YouTube refuses its video
    /// files (HTTP 403) for some videos unless a token Shield doesn't have is
    /// sent (yt-dlp issue 17989; fixed upstream only after 2026.10.26).
    static let playerClientFallbacks: [[String]] = [
        [],
        ["--extractor-args", "youtube:player_client=tv,web_safari"],
        ["--extractor-args", "youtube:player_client=tv_simply,mweb"],
    ]

    /// Signed in, yt-dlp's default clients include `web_embedded`, so it is
    /// left out explicitly; the second signed-in way uses other clients.
    static let signedInClientFallbacks: [[String]] = [
        ["--extractor-args", "youtube:player_client=default,-web_embedded"],
        ["--extractor-args", "youtube:player_client=tv,web_safari"],
    ]

    struct Attempt: Equatable, Sendable { let clients: [String]; let signIn: Bool }

    /// Without the sign-in first (fast whole files). With a sign-in file, a
    /// refusal goes to a signed-in way next (When YouTube
    /// refuses a connection's plain downloads, the signed-in ones still work),
    /// alternating with the other plain ways after that.
    static func attempts(hasSignIn: Bool) -> [Attempt] {
        let plain = playerClientFallbacks.map { Attempt(clients: $0, signIn: false) }
        guard hasSignIn else { return plain }
        let signed = signedInClientFallbacks.map { Attempt(clients: $0, signIn: true) }
        return [plain[0], signed[0], plain[1], signed[1], plain[2]]
    }

    /// Network trouble that clears by itself, unlike YouTube refusing a
    /// video's file (403), which every way was already tried for.
    static func isPassingProblem(_ error: StudyDownloadError) -> Bool {
        guard case .toolReported(_, let reason) = error else { return false }
        let lower = reason.lowercased()
        return ["timed out", "connection reset", "http error 5", "page needs to be reloaded", "http error 429"]
            .contains { lower.contains($0) }
    }

    static func asksForSignIn(_ error: StudyDownloadError) -> Bool {
        guard case .toolReported(_, let reason) = error else { return false }
        let lower = reason.lowercased()
        return lower.contains("not a bot") || lower.contains("sign in to confirm") || lower.contains("login required")
    }

    static func isRateLimited(_ error: StudyDownloadError) -> Bool {
        guard case .toolReported(_, let reason) = error else { return false }
        let lower = reason.lowercased()
        return lower.contains("http error 429") || lower.contains("too many requests")
    }

    /// yt-dlp stops the whole video when only its captions fail to download.
    static func isSubtitleFailure(_ error: StudyDownloadError) -> Bool {
        guard case .toolReported(_, let reason) = error else { return false }
        return reason.lowercased().contains("subtitles")
    }

    /// The user's chosen download quality (Settings › Video quality).
    static let qualityKey = "Shield.DownloadQuality"
    static let qualities = [360, 480, 720, 1080]
    static let defaultQuality = 1080
    static var savedQuality: Int {
        let saved = UserDefaults.standard.integer(forKey: qualityKey)
        return qualities.contains(saved) ? saved : defaultQuality
    }

    /// H.264/AAC first, which Apple's player plays as is, at the chosen
    /// height or the closest below it; then any codec up to that height
    /// (converted after download); a video with nothing that small takes
    /// its smallest version.
    static func formatSelector(maxHeight: Int) -> String {
        let h = qualities.contains(maxHeight) ? maxHeight : defaultQuality
        return "bv*[height<=\(h)][vcodec^=avc1]+ba[acodec^=mp4a]/b[height<=\(h)][vcodec^=avc1][acodec^=mp4a]" +
            "/bv*[height<=\(h)]+ba/b[height<=\(h)]/wv*+ba/w/b"
    }

    /// A refused media link, missing format or bot check, which another
    /// client (or going without the sign-in) may avoid. Private, removed or
    /// region-locked videos are final.
    static func isRetryable(_ error: StudyDownloadError) -> Bool {
        guard case .toolReported(_, let reason) = error else { return false }
        let lower = reason.lowercased()
        return ["403", "forbidden", "requested format is not available", "fragment 1 not found",
                "unable to download video data", "http error 429", "not a bot", "player response",
                "timed out", "connection reset", "page needs to be reloaded", "http error 5"].contains { lower.contains($0) }
    }

    static func removePartialDownloads(in directory: URL) {
        let items = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for item in items where ["part", "ytdl"].contains(item.pathExtension) || item.lastPathComponent.contains(".part-Frag") {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// True when yt-dlp skipped the video for being over the size limit.
    private func runYTDLP(video: StudyVideo, stagingDirectory: URL, outputTemplate: String, extraArguments: [String],
                          useSignIn: Bool, subtitles: Bool,
                          onProgress: @escaping @Sendable (Double) -> Void) async throws -> Bool {
        let process = Process()
        process.executableURL = ytdlpURL
        process.currentDirectoryURL = stagingDirectory
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": stagingDirectory.path,
            "TMPDIR": stagingDirectory.path,
            "XDG_CONFIG_HOME": stagingDirectory.path,
            "XDG_CACHE_HOME": stagingDirectory.path
        ]
        process.arguments = [
            "--no-playlist",
            "--no-overwrites",
            "--ignore-config",
            "--no-cache-dir",
            "--write-info-json",
            "--no-remote-components",
            "--socket-timeout", "20",
            "--retries", "2",
            "--fragment-retries", "2",
            "--extractor-retries", "2",
            // Pieces of a split stream four at a time instead of one by one.
            "--concurrent-fragments", "4",
            "--restrict-filenames",
            "--newline",
            // yt-dlp prints only the text after "download:"; the marker and the
            // stream's codecs let the parser tell video from audio.
            "--progress-template", "download:\(DownloadProgressParser.marker)%(info.ext)s|%(info.vcodec)s|%(info.acodec)s|%(progress._percent_str)s",
            "--js-runtimes", "deno:\(denoURL.path)",
            "--ffmpeg-location", ffmpegLocation.path,
            // H.264/AAC first: Apple's player plays it as is, so most
            // downloads skip the compatibility conversion.
            "-f", Self.formatSelector(maxHeight: maxHeight),
            "--merge-output-format", "mp4",
            "--max-filesize", "2G",
            "-o", outputTemplate,
        ] + extraArguments + ["https://www.youtube.com/watch?v=\(video.id)"]
        if subtitles {
            process.arguments?.insert(contentsOf: ["--write-auto-subs", "--sub-langs", "en", "--sub-format", "vtt"], at: 0)
        }
        var session: Session?
        defer { session?.stop() }
        if let containment {
            let started = try containment.start()
            session = started
            process.executableURL = StudyContainment.sandboxExec
            let cookies = useSignIn ? containment.cookies.map { ["--cookies", $0.path] } ?? [] : []
            process.arguments = ["-f", started.profile.path, ytdlpURL.path, "--proxy", started.proxyURL] +
                cookies + (process.arguments ?? [])
        }
        let progressOutput = Pipe()
        let parser = DownloadProgressParser(onProgress: onProgress)
        let activity = ActivityClock()
        progressOutput.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { activity.touch(); parser.append(data) }
        }
        process.standardOutput = progressOutput
        // yt-dlp's own error line (for example YouTube's sign-in check) is
        // shown instead of a bare exit status. The log never leaves staging.
        let errorLog = stagingDirectory.appendingPathComponent(".yt-dlp-errors.log")
        FileManager.default.createFile(atPath: errorLog.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
        let errorHandle = try FileHandle(forWritingTo: errorLog)
        process.standardError = errorHandle
        defer {
            progressOutput.fileHandleForReading.readabilityHandler = nil
            // A tick already in flight finishes before this returns; none come after.
            parser.finish()
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: errorLog)
        }
        // yt-dlp prints progress every few seconds while bytes arrive; five
        // silent minutes (output and error log alike) means it's stuck.
        let errorLogPath = errorLog.path
        try await StudyProcessRunner(confined: containment != nil).run(process, timeout: 3_600, stallLimit: 300) {
            let size = (try? FileManager.default.attributesOfItem(atPath: errorLogPath)[.size] as? Int) ?? 0
            activity.note(errorLogSize: size)
            return activity.last
        }
        guard process.terminationStatus == 0 else {
            if let reason = Self.reportedError(in: errorLog) { throw StudyDownloadError.toolReported("yt-dlp", reason) }
            throw StudyDownloadError.processFailed("yt-dlp", process.terminationStatus)
        }
        return parser.sawSizeLimit
    }

    private func finishFetch(video: StudyVideo, stagingDirectory: URL, tooLarge: Bool) throws -> URL {
        // yt-dlp exits 0 when it skips a file over --max-filesize, leaving nothing behind.
        let output = stagingDirectory.appendingPathComponent("\(video.id).mp4")
        var status = stat()
        guard lstat(output.path, &status) == 0, (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), status.st_size > 0 else {
            throw StudyDownloadError.invalidMedia(tooLarge ? "This video is too large to save (over 2 GB)."
                                                           : "No video file came back from YouTube.")
        }
        if video.transcriptRequested {
            let subtitle = stagingDirectory.appendingPathComponent("\(video.id).en.vtt")
            if let data = try? StudyBoundedFile.read(subtitle, limit: 2_000_000),
               let raw = String(data: data, encoding: .utf8) {
                let info = stagingDirectory.appendingPathComponent("\(video.id).info.json")
                let title = (try? StudyBoundedFile.read(info, limit: 16_000_000))
                    .flatMap(StudyContainedFetcher.title(fromInfoJSON:))
                let clean = TranscriptFormatter().document(title: title, vtt: raw)
                if !clean.isEmpty {
                    try? Data(clean.utf8).write(to: stagingDirectory.appendingPathComponent("\(video.id).txt"), options: .atomic)
                    // The same captions with their times: the transcript follows
                    // the video, and captions can show on it.
                    if let cues = TranscriptCue.encode(TranscriptFormatter().cues(vtt: raw)) {
                        try? cues.write(to: stagingDirectory.appendingPathComponent("\(video.id).cues.json"), options: .atomic)
                    }
                }
            }
        }
        return output
    }

    // Last "ERROR:" line of a bounded log tail, at most 240 characters. Nil
    // without one: other lines (such as yt-dlp's warnings about skipped cookie
    // entries) can quote a whole cookie, so they are never shown.
    static func reportedError(in log: URL) -> String? {
        guard let data = try? StudyBoundedFile.read(log, limit: 4_000_000),
              let text = String(data: data.suffix(16_384), encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let reason = lines.last(where: { $0.contains("ERROR:") })
            .map { String($0[$0.range(of: "ERROR:")!.upperBound...]).trimmingCharacters(in: .whitespaces) }
        guard let reason, !reason.isEmpty, !reason.contains("\t") else { return nil }
        return String(reason.prefix(240))
    }
}

struct TranscriptCleaner: Sendable {
    func clean(_ raw: String) -> String {
        var lines: [String] = []
        var previous: String?

        for rawLine in raw.components(separatedBy: .newlines) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "WEBVTT" || trimmed.contains("-->") || Int(trimmed) != nil || trimmed.hasPrefix("NOTE") {
                continue
            }
            let line = rawLine
                .replacingOccurrences(
                    of: #"^\s*(\d{1,2}:)?\d{1,2}:\d{2}([.,]\d{3})?\s*"#,
                    with: "",
                    options: .regularExpression
                )
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, line != previous else { continue }
            lines.append(line)
            previous = line
        }
        return lines.joined(separator: "\n")
    }
}

/// A transcript meant for reading: the video's title, a blank line, then
/// paragraphs separated by blank lines. Captions become running text; a new
/// paragraph starts at a pause or a sentence end once a paragraph is long.
struct TranscriptFormatter: Sendable {
    static let pause: Double = 3
    static let minimumWords = 60
    static let maximumWords = 140

    /// Formats a WebVTT caption file. Empty when it holds no caption text.
    func document(title: String?, vtt: String) -> String {
        document(title: title, body: paragraphs(captionLines(vtt)))
    }

    /// Reflows a transcript an older version saved one caption per line; those
    /// kept the caption file's "Kind:" header. Any other text is unchanged.
    func readable(_ saved: String) -> String {
        guard saved.hasPrefix("Kind:"), !saved.contains("\n\n") else { return saved }
        let lines = saved.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("Kind:") && !$0.hasPrefix("Language:") }
        let reflowed = document(title: nil, body: paragraphs(lines.map { ($0, nil) }))
        return reflowed.isEmpty ? saved : reflowed
    }

    private func document(title: String?, body: [String]) -> String {
        guard !body.isEmpty else { return "" }
        let heading = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return ((heading.isEmpty ? [] : [heading]) + body).joined(separator: "\n\n") + "\n"
    }

    /// Each caption line with its time, for following along and captions:
    /// a line lasts until the next one starts (or its own cue ends).
    func cues(vtt: String) -> [TranscriptCue] {
        let lines = timedLines(vtt)
        var result: [TranscriptCue] = []
        for (index, line) in lines.enumerated() {
            guard let start = line.start else { continue }
            let nextStart = lines[(index + 1)...].lazy.compactMap { $0.start }.first { $0 > start }
            let end = max(start + 0.5, min(nextStart ?? .infinity, max(line.end ?? start + 4, start + 0.5)))
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard end.isFinite, !text.isEmpty else { continue }
            result.append(TranscriptCue(start: start, end: end, text: String(text.prefix(TranscriptCue.maximumText))))
        }
        return result
    }

    /// Each new caption line once, with the start time of the cue that first
    /// shows it. YouTube's rolling captions repeat the previous line.
    private func captionLines(_ vtt: String) -> [(text: String, start: Double?)] {
        timedLines(vtt).map { ($0.text, $0.start) }
    }

    private func timedLines(_ vtt: String) -> [(text: String, start: Double?, end: Double?)] {
        var result: [(text: String, start: Double?, end: Double?)] = []
        var start: Double?
        var end: Double?
        var inCue = false
        // A cue ends only at an empty line (WebVTT). YouTube's first cue opens
        // with a line holding just a space; ending the cue there lost the
        // video's first line (or timed it a whole cue late).
        for rawLine in vtt.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines) {
            if rawLine.isEmpty { inCue = false; continue }
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("-->") {
                inCue = true
                let stamps = trimmed.components(separatedBy: "-->")
                start = stamps.first.flatMap(seconds)
                // "00:00:04.000 align:start position:0%": the time is the first word.
                end = stamps.dropFirst().first?.split(separator: " ").first.flatMap { seconds(String($0)) }
                continue
            }
            guard inCue, !trimmed.isEmpty else { continue }
            let text = trimmed
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, text != result.last?.text else { continue }
            result.append((text, start, end))
        }
        return result
    }

    private func seconds(_ stamp: String) -> Double? {
        let parts = stamp.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    private func paragraphs(_ lines: [(text: String, start: Double?)]) -> [String] {
        var result: [String] = []
        var words: [Substring] = []
        for (index, line) in lines.enumerated() {
            words += line.text.split(separator: " ")
            let next = index + 1 < lines.count ? lines[index + 1] : nil
            var paused = false
            if let start = line.start, let nextStart = next?.start { paused = nextStart - start >= Self.pause }
            let sentenceEnd = line.text.last.map { ".?!".contains($0) } ?? false
            if next == nil || words.count >= Self.maximumWords
                || (words.count >= Self.minimumWords && (paused || sentenceEnd)) {
                var paragraph = words.joined(separator: " ")
                if let first = paragraph.first { paragraph.replaceSubrange(...paragraph.startIndex, with: first.uppercased()) }
                result.append(paragraph)
                words = []
            }
        }
        return result
    }
}

struct ValidatedMediaInstaller: Sendable {
    let libraryRoot: URL

    /// Half-written copies a crash left behind (".<id>.<uuid>.validated").
    /// Only plain files of ours untouched for an hour go, so a copy still
    /// being written is never removed. Returns how many were removed.
    @discardableResult
    static func removeLeftovers(in root: URL, olderThan age: TimeInterval = 3_600,
                                now: Date = Date()) -> Int {
        let pattern = /^\.[A-Za-z0-9_-]{11}\.[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.validated$/
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return 0 }
        var removed = 0
        for name in names where name.wholeMatch(of: pattern) != nil {
            let file = root.appendingPathComponent(name)
            var info = stat()
            guard lstat(file.path, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  info.st_uid == geteuid() else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            guard now.timeIntervalSince(modified) >= age else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        return removed
    }

    func installTranscript(from staged: URL, videoID: String) throws {
        try ShieldRuntime.requireIsolatedWrite(to: libraryRoot)
        guard videoID.count == 11,
              videoID.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains
              ),
              staged.lastPathComponent == "\(videoID).txt" else { throw StudyDownloadError.unsafePath }
        let data = try StudyBoundedFile.read(staged, limit: 2_000_000)
        guard !data.isEmpty, data.count <= 2_000_000, String(data: data, encoding: .utf8) != nil else {
            throw StudyDownloadError.invalidMedia("Transcript is invalid.")
        }
        try AtomicFixtureStore(allowedRoot: libraryRoot).write(
            data, to: libraryRoot.appendingPathComponent("\(videoID).txt")
        )
    }

    /// The transcript's timed lines, next to it. Checked before it's kept.
    func installCues(from staged: URL, videoID: String) throws {
        try ShieldRuntime.requireIsolatedWrite(to: libraryRoot)
        guard videoID.count == 11,
              videoID.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains
              ),
              staged.lastPathComponent == "\(videoID).cues.json" else { throw StudyDownloadError.unsafePath }
        let data = try StudyBoundedFile.read(staged, limit: TranscriptCue.fileLimit)
        _ = try TranscriptCue.decode(data)
        try AtomicFixtureStore(allowedRoot: libraryRoot).write(
            data, to: libraryRoot.appendingPathComponent("\(videoID).cues.json")
        )
    }

    func install(
        stagedMedia: URL,
        validation: MediaValidation,
        videoID: String
    ) throws -> URL {
        try ShieldRuntime.requireIsolatedWrite(to: libraryRoot)
        guard validation.isPlayable,
              videoID.count == 11,
              videoID.unicodeScalars.allSatisfy(
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains
              ) else {
            throw StudyDownloadError.invalidMedia("Only validated approved media can be installed.")
        }

        let root = libraryRoot.standardizedFileURL
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0,
              (rootInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              rootInfo.st_uid == geteuid() else { throw StudyDownloadError.unsafePath }
        let destination = root.appendingPathComponent("\(videoID).mp4")
        guard destination.standardizedFileURL.path.hasPrefix(root.path + "/") else {
            throw StudyDownloadError.unsafePath
        }

        let candidate = root.appendingPathComponent(
            ".\(videoID).\(UUID().uuidString).validated"
        )
        defer { try? FileManager.default.removeItem(at: candidate) }
        let source = try StudyOutputSnapshot(file: stagedMedia, expectedSize: validation.fileSize,
                                              maximumSize: 4_000_000_000)
        let output = open(candidate.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw StudyDownloadError.unsafePath }
        do {
            let outputHandle = FileHandle(fileDescriptor: output, closeOnDealloc: false)
            var offset: Int64 = 0
            while offset < source.size {
                try Task.checkCancellation()
                let chunk = try source.read(offset: offset)
                try outputHandle.write(contentsOf: chunk)
                offset += Int64(chunk.count)
            }
            guard fsync(output) == 0 else { throw StudyDownloadError.unsafePath }
            close(output)
        } catch {
            close(output)
            throw error
        }
        try Task.checkCancellation()
        guard rename(candidate.path, destination.path) == 0 else { throw StudyDownloadError.unsafePath }
        return destination
    }
}

actor StudyDownloadCoordinator {
    private let fetcher: RestrictedVideoFetching
    private let validator: MediaValidating
    private let installer: ValidatedMediaInstaller?
    private let repairer: (any MediaRepairing)?
    private let maximumAttempts: Int
    /// Videos fetched at once. A slow one no longer holds up the next.
    static let parallelDownloads = 3

    init(
        fetcher: RestrictedVideoFetching,
        validator: MediaValidating,
        maximumAttempts: Int = 3,
        installer: ValidatedMediaInstaller? = nil,
        repairer: (any MediaRepairing)? = nil
    ) {
        self.fetcher = fetcher
        self.validator = validator
        self.maximumAttempts = max(1, min(maximumAttempts, 3))
        self.installer = installer
        self.repairer = repairer
    }

    func run(
        manifest: StudyManifest,
        stagingDirectory: URL,
        onUpdate: @escaping @Sendable (StudyJob) -> Void = { _ in }
    ) async -> [StudyJob] {
        do {
            _ = try manifest.validated()
        } catch {
            return manifest.videos.map {
                StudyJob(id: $0.id, title: $0.title, state: .failed(error.localizedDescription))
            }
        }

        // A few at a time, starting the next as soon as one finishes. After a
        // cancel the rest still pass through downloadOne, which marks them cancelled.
        let videos = manifest.videos
        let jobs = await withTaskGroup(of: StudyJob.self) { group in
            var next = 0
            func startNext() {
                guard next < videos.count else { return }
                let video = videos[next]
                next += 1
                group.addTask { await self.downloadOne(video, stagingDirectory: stagingDirectory, onUpdate: onUpdate) }
            }
            for _ in 0..<min(Self.parallelDownloads, videos.count) { startNext() }
            var finished: [StudyJob] = []
            for await job in group {
                finished.append(job)
                startNext()
            }
            return finished
        }
        return jobs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func downloadOne(
        _ video: StudyVideo,
        stagingDirectory: URL,
        onUpdate: @escaping @Sendable (StudyJob) -> Void
    ) async -> StudyJob {
        for attempt in 1...maximumAttempts {
            let work = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: work) }
                onUpdate(StudyJob(id: video.id, title: video.title, state: .downloading(attempt: attempt),
                                  note: attempt > 1 ? "Trying again…" : nil))
                let mediaURL = try await fetcher.fetch(video: video, stagingDirectory: work, onProgress: { progress in
                    onUpdate(StudyJob(id: video.id, title: video.title,
                                      state: .downloading(attempt: attempt), progress: progress))
                }, onRetry: { number, total in
                    onUpdate(StudyJob(id: video.id, title: video.title, state: .downloading(attempt: attempt),
                                      note: "YouTube refused it. Trying another way (\(number) of \(total))…"))
                })
                guard mediaURL.deletingLastPathComponent().standardizedFileURL == work.standardizedFileURL else {
                    throw StudyDownloadError.unsafePath
                }
                onUpdate(StudyJob(id: video.id, title: video.title, state: .validating))
                let transcriptURL = video.transcriptRequested
                    ? work.appendingPathComponent("\(video.id).txt") : nil
                var preparedURL = try await repairer?.prepare(mediaURL, force: false) ?? mediaURL
                let resultBeforeInstall: MediaValidation
                do {
                    resultBeforeInstall = try await validator.validate(mediaURL: preparedURL,
                                                                       expectedDuration: video.expectedDuration,
                                                                       transcriptURL: transcriptURL)
                } catch StudyDownloadError.invalidMedia(let detail) where detail.contains("decode sample") {
                    guard let repairer, preparedURL == mediaURL else { throw StudyDownloadError.invalidMedia(detail) }
                    preparedURL = try await repairer.prepare(mediaURL, force: true)
                    resultBeforeInstall = try await validator.validate(mediaURL: preparedURL,
                                                                       expectedDuration: video.expectedDuration,
                                                                       transcriptURL: transcriptURL)
                }
                var result = resultBeforeInstall
                if let installer {
                    _ = try installer.install(stagedMedia: preparedURL, validation: result, videoID: video.id)
                    var transcriptInstalled = false
                    if let transcriptURL, result.transcriptPresent {
                        transcriptInstalled = (try? installer.installTranscript(from: transcriptURL, videoID: video.id)) != nil
                        let cues = work.appendingPathComponent("\(video.id).cues.json")
                        if transcriptInstalled, FileManager.default.fileExists(atPath: cues.path) {
                            try? installer.installCues(from: cues, videoID: video.id)
                        }
                    }
                    result = MediaValidation(duration: result.duration, hasVideo: result.hasVideo,
                                             hasAudio: result.hasAudio, fileSize: result.fileSize,
                                             transcriptPresent: transcriptInstalled)
                }
                let job = StudyJob(id: video.id, title: video.title, state: .complete(result))
                onUpdate(job)
                return job
            } catch {
                if Task.isCancelled || error is CancellationError {
                    let job = StudyJob(id: video.id, title: video.title, state: .failed("Cancelled"))
                    onUpdate(job)
                    return job
                }
                if attempt < maximumAttempts, Self.isRetryable(error, attempt: attempt) {
                    // YouTube's passing refusals ("reload the page", 429) clear after a short pause.
                    if case StudyDownloadError.toolReported = error { try? await Task.sleep(for: .seconds(6 * attempt)) }
                    continue
                }
                let job = StudyJob(id: video.id, title: video.title, state: .failed(error.localizedDescription))
                onUpdate(job)
                return job
            }
        }
        return StudyJob(id: video.id, title: video.title, state: .failed("Retry limit reached."))
    }

    static func isRetryable(_ error: Error, attempt: Int) -> Bool {
        switch error {
        case StudyDownloadError.processFailed: true
        // An hour-long stall gets one more try, not two.
        case StudyDownloadError.timedOut, StudyDownloadError.stalled: attempt == 1
        // A damaged transfer may come back whole; a file that fails a check
        // by its nature (length, size, space, format) would fail it again.
        case StudyDownloadError.invalidMedia(let detail): !finalMediaProblems.contains { detail.contains($0) }
        // The fetcher has already tried every way: a refusal gets one more
        // round after a pause, not two (Twelve refused tries
        // sat on "Downloading…" for minutes). Passing network trouble keeps all tries.
        case let reported as StudyDownloadError where YTDLPRestrictedFetcher.isRetryable(reported):
            attempt == 1 || YTDLPRestrictedFetcher.isPassingProblem(reported)
        default: false
        }
    }

    static let finalMediaProblems = ["Duration differs", "couldn't convert", "Not enough free space",
                                     "inspection limit", "4 GB limit", "too large to save", "No video file came back",
                                     "must be dated", "is required", "are required"]
}


/// The download way (player clients, signed in or not) that last worked, tried
/// first for the next videos for a while; forgotten when it fails.
enum WorkingWay {
    static let remembered: TimeInterval = 2 * 3_600
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last: (way: YTDLPRestrictedFetcher.Attempt, at: Date)?

    static func ordered(_ ways: [YTDLPRestrictedFetcher.Attempt], now: Date = Date()) -> [YTDLPRestrictedFetcher.Attempt] {
        lock.lock(); defer { lock.unlock() }
        guard let last, now.timeIntervalSince(last.at) < remembered, ways.contains(last.way),
              last.way != ways.first else { return ways }
        return [last.way] + ways.filter { $0 != last.way }
    }

    static func worked(_ way: YTDLPRestrictedFetcher.Attempt, now: Date = Date()) {
        lock.lock(); last = (way, now); lock.unlock()
    }

    static func failed(_ way: YTDLPRestrictedFetcher.Attempt) {
        lock.lock(); if last?.way == way { last = nil }; lock.unlock()
    }

    static func reset() { lock.lock(); last = nil; lock.unlock() }
}

/// Why each try of a failed download was refused, one line each, kept small,
/// next to Shield's other data. Only yt-dlp's own "ERROR:" text is written
/// (never warnings, which can quote a sign-in cookie).
enum DownloadProblemLog {
    static var file: URL { ShieldRuntime.supportDirectory.appendingPathComponent("download-problems.log") }
    static let maximumBytes = 64_000

    static func line(videoID: String, way: YTDLPRestrictedFetcher.Attempt, error: StudyDownloadError, now: Date) -> String {
        let clients = way.clients.last.map { $0.replacingOccurrences(of: "youtube:player_client=", with: "") } ?? "default"
        let reason = error.localizedDescription.replacingOccurrences(of: "\n", with: " ").prefix(300)
        return "\(ISO8601DateFormatter().string(from: now)) \(videoID) [\(clients)\(way.signIn ? ", signed in" : "")] \(reason)\n"
    }

    static func note(videoID: String, way: YTDLPRestrictedFetcher.Attempt, error: StudyDownloadError,
                     to url: URL = file, now: Date = Date()) {
        if case .cancelled = error { return }
        let entry = Data(line(videoID: videoID, way: way, error: error, now: now).utf8)
        var data = (try? Data(contentsOf: url)) ?? Data()
        data.append(entry)
        if data.count > maximumBytes { data = data.suffix(maximumBytes / 2) }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
