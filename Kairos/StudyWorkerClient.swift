import Darwin
import Foundation

enum StudyInstalledAuthorityGuard {
    // Development authority cannot attest to an installed RC's commitments.
    // Read metadata only. Absence is not a general system-policy attestation.
    static var detected: Bool {
        detected(at: ["/Applications/Shield RC.app", "/Library/Application Support/ShieldAuthority",
            "/Library/LaunchDaemons/com.kairos.ShieldAuthority.plist",
            "/Library/PrivilegedHelperTools/com.kairos.ShieldAuthority",
            "/usr/local/etc/kairos-policy-state.plist"].map { URL(fileURLWithPath: $0) })
    }
    static func detected(at locations: [URL]) -> Bool {
        locations.contains { location in
            var metadata = stat()
            if lstat(location.path, &metadata) == 0 { return true }
            return errno != ENOENT // Permission errors and dangling aliases fail closed.
        }
    }
}

struct StudyWorkerFetcher: RestrictedVideoFetching {
    let approvedIDs: [String]
    let policyAllows: @Sendable () async -> Bool
    var onMetadata: @Sendable (String, String) -> Void = { _, _ in }
    var onActivity: @Sendable (String, StudyWorkerStatus.Phase) -> Void = { _, _ in }
    var onToolVersions: @Sendable ([String: String]) -> Void = { _ in }

    static var bundleURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/ShieldStudyWorker.xpc")
    }
    /// Read once: the app bundle doesn't change while it runs.
    static let isPackaged: Bool = {
        // Never enables RC-77 or UI Review, even if someone copies a helper in.
        ShieldRuntime.isDevelopment && !ShieldRuntime.isUIReview &&
        Bundle.main.bundleIdentifier == "com.kairos.ShieldDevelopment" &&
        FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("Contents/Resources/tool-hashes.json").path)
    }()
    func fetch(video: StudyVideo, stagingDirectory: URL) async throws -> URL {
        try await fetch(video: video, stagingDirectory: stagingDirectory, onProgress: { _ in })
    }
    func fetch(video: StudyVideo, stagingDirectory: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard Self.isPackaged, !StudyInstalledAuthorityGuard.detected, await policyAllows() else {
            throw StudyDownloadError.invalidManifest("Experimental downloads require an isolated Development environment without installed Shield authority.")
        }
        let request = StudyWorkerRequest(version: 1, jobID: UUID(), video: video, approvedIDs: approvedIDs)
        let data = try JSONEncoder().encode(request)
        _ = try StudyWorkerRequest.decode(data)
        let channel = try StudyWorkerChannel()
        defer { channel.connection.invalidate() }
        return try await withTaskCancellationHandler {
            _ = try await channel.call { peer, finish in peer.begin(data as NSData) { finish(Data(), $0 as String?) } }
            let deadline = ProcessInfo.processInfo.systemUptime + 3_900
            var lastPhase: StudyWorkerStatus.Phase?
            var lastProgress: Double?
            var lastVersions: [String: String]?
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                guard await policyAllows() else { throw StudyDownloadError.invalidManifest("Committed policy no longer permits this fetch.") }
                let bytes = try await channel.call { peer, finish in
                    peer.status(request.jobID.uuidString as NSString) { finish($0 as Data?, $1 as String?) }
                }
                guard bytes.count <= 8192 else { throw StudyDownloadError.unsafePath }
                let state = try JSONDecoder().decode(StudyWorkerStatus.self, from: bytes)
                guard state.version == 1, state.jobID == request.jobID else { throw StudyDownloadError.unsafePath }
                if let versions = state.toolVersions {
                    guard Set(versions.keys) == ["yt-dlp", "deno", "ffmpeg", "ffprobe"],
                          versions.values.allSatisfy({ !$0.isEmpty && $0.count <= 160 }) else {
                        throw StudyDownloadError.unsafePath
                    }
                    if versions != lastVersions { lastVersions = versions; onToolVersions(versions) }
                }
                if state.phase != lastPhase { lastPhase = state.phase; onActivity(video.id, state.phase) }
                if let progress = state.progress, progress.isFinite, (0...1).contains(progress), progress != lastProgress {
                    lastProgress = progress; onProgress(progress)
                }
                switch state.phase {
                case .failed, .cancelled:
                    throw StudyDownloadError.invalidMedia(state.problem ?? "The download did not finish.")
                case .ready:
                    guard state.mediaBytes > 0, state.mediaBytes <= 4_000_000_000,
                          (0...2_000_000).contains(state.transcriptBytes) else { throw StudyDownloadError.unsafePath }
                    try StudyStorageBudget.requireCapacity(at: stagingDirectory, sourceBytes: state.mediaBytes)
                    let media = stagingDirectory.appendingPathComponent("\(video.id).mp4")
                    var transferred: [URL] = []
                    var delivered = false
                    defer { if !delivered { transferred.forEach { try? FileManager.default.removeItem(at: $0) } } }
                    try await copyOutput(channel, job: request.jobID, kind: "media", count: state.mediaBytes,
                                         to: media, deadline: deadline)
                    transferred.append(media)
                    if state.transcriptBytes > 0 {
                        let transcript = stagingDirectory.appendingPathComponent("\(video.id).txt")
                        try await copyOutput(channel, job: request.jobID, kind: "transcript", count: state.transcriptBytes,
                                             to: transcript, deadline: deadline)
                        transferred.append(transcript)
                    }
                    try await StudyWorkerOutputTransfer.requirePermission(deadline: deadline, policyAllows: policyAllows)
                    if let title = state.title, !title.isEmpty, title.count <= 256 { onMetadata(video.id, title) }
                    delivered = true
                    return media
                default: try await Task.sleep(for: .milliseconds(250))
                }
            }
            throw StudyDownloadError.timedOut("study worker")
        } onCancel: { channel.connection.invalidate() }
    }

    private func copyOutput(_ channel: StudyWorkerChannel, job: UUID, kind: String, count: Int64,
                            to destination: URL, deadline: TimeInterval) async throws {
        try await StudyWorkerOutputTransfer.copy(count: count, to: destination, deadline: deadline,
                                                 policyAllows: policyAllows) { start in
            try await channel.call { peer, finish in
                peer.read(job.uuidString as NSString, kind: kind as NSString, offset: start) { finish($0 as Data?, $1 as String?) }
            }
        }
    }
}

// The authenticated channel supplies bytes, but it cannot extend the user's
// authorization or the job lifetime. Recheck both throughout a large transfer.
enum StudyWorkerOutputTransfer {
    static func requirePermission(deadline: TimeInterval,
                                  policyAllows: @Sendable () async -> Bool) async throws {
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw StudyDownloadError.timedOut("worker transfer") }
        guard await policyAllows() else {
            throw StudyDownloadError.invalidManifest("Committed policy no longer permits this fetch.")
        }
        try Task.checkCancellation()
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw StudyDownloadError.timedOut("worker transfer") }
    }

    static func copy(count: Int64, to destination: URL, deadline: TimeInterval,
                     policyAllows: @Sendable () async -> Bool,
                     read: @Sendable (Int64) async throws -> Data) async throws {
        guard destination.isFileURL, count > 0, count <= 4_000_000_000 else { throw StudyDownloadError.unsafePath }
        try await requirePermission(deadline: deadline, policyAllows: policyAllows)
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StudyDownloadError.unsafePath }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var complete = false
        defer {
            close(fd)
            if !complete { try? FileManager.default.removeItem(at: destination) }
        }
        var offset: Int64 = 0
        while offset < count {
            try await requirePermission(deadline: deadline, policyAllows: policyAllows)
            let chunk = try await read(offset)
            try await requirePermission(deadline: deadline, policyAllows: policyAllows)
            guard !chunk.isEmpty, chunk.count <= 65_536, Int64(chunk.count) <= count - offset else { throw StudyDownloadError.unsafePath }
            try output.write(contentsOf: chunk)
            offset += Int64(chunk.count)
        }
        try output.synchronize()
        try await requirePermission(deadline: deadline, policyAllows: policyAllows)
        complete = true
    }
}

final class StudyWorkerChannel: @unchecked Sendable {
    let connection: NSXPCConnection
    init() throws {
        let requirement = try StudyWorkerIdentity.requirement(for: StudyWorkerFetcher.bundleURL,
                                                               identifier: StudyWorkerIdentity.identifier, requireSandbox: true)
        connection = NSXPCConnection(serviceName: StudyWorkerIdentity.identifier)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: ShieldStudyWorkerWire.self)
        connection.resume()
    }
    func call(_ operation: @escaping @Sendable (ShieldStudyWorkerWire, @escaping (Data?, String?) -> Void) -> Void) async throws -> Data {
        let connection = connection
        return try await Task.detached {
            let reply = WorkerReply()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ reply.transportFailed($0) }) as? ShieldStudyWorkerWire else {
                throw StudyWorkerChannelError.transport("Proxy unavailable")
            }
            operation(proxy) { reply.finish($0, $1) }
            return try reply.wait()
        }.value
    }
}

enum StudyWorkerChannelError: LocalizedError {
    case transport(String)
    case rejected(String)
    var errorDescription: String? {
        switch self {
        case .transport(let detail): return "Worker communication failed: \(detail)"
        case .rejected(let detail): return "Worker rejected the request: \(detail)"
        }
    }
}

private final class WorkerReply: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var finished = false
    private var data: Data?
    private var problem: String?
    private var transportProblem: String?
    func transportFailed(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        transportProblem = "\((error as NSError).domain) \((error as NSError).code): \(error.localizedDescription)"
        finished = true; signal.signal()
    }
    func finish(_ data: Data?, _ problem: String?) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        self.data = data; self.problem = problem; finished = true; signal.signal()
    }
    func wait() throws -> Data {
        guard signal.wait(timeout: .now() + 10) == .success else { throw StudyDownloadError.timedOut("worker reply") }
        lock.lock(); defer { lock.unlock() }
        if let transportProblem { throw StudyWorkerChannelError.transport(transportProblem) }
        if let problem { throw StudyWorkerChannelError.rejected(problem) }
        guard let data, data.count <= 65_536 else { throw StudyDownloadError.unsafePath }
        return data
    }
}
