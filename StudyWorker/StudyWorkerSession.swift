import CryptoKit
import Darwin
import Foundation

final class StudyWorkerSession: NSObject, ShieldStudyWorkerWire, @unchecked Sendable {
    private let lock = NSLock()
    private var job: StudyWorkerStatus?
    private var task: Task<Void, Never>?
    private var root: URL?
    private var media: StudyOutputSnapshot?
    private var transcript: StudyOutputSnapshot?
    private var admitted = false
    private var disconnected = false
    private var idleTimer: DispatchSourceTimer?
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var beganAt = ProcessInfo.processInfo.systemUptime
    private static let admissionLock = NSLock()
    private static var sessions = 0

    func begin(_ bytes: NSData, reply: @escaping (NSString?) -> Void) {
        do {
            let request = try StudyWorkerRequest.decode(bytes as Data)
            let tools = try reviewedTools()
            lock.lock()
            guard job == nil, !disconnected else { lock.unlock(); throw StudyDownloadError.invalidManifest("One job per live connection.") }
            Self.admissionLock.lock()
            guard Self.sessions < 2 else {
                Self.admissionLock.unlock(); lock.unlock()
                throw StudyDownloadError.invalidManifest("Worker is busy. Retry after the current downloads finish.")
            }
            Self.sessions += 1
            admitted = true
            Self.admissionLock.unlock()
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldWorker-\(UUID())", isDirectory: true)
            root = directory
            job = .init(version: 1, jobID: request.jobID, phase: .starting)
            beganAt = ProcessInfo.processInfo.systemUptime
            lastActivity = beganAt
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in self?.expireIdleSession() }
            idleTimer = timer
            timer.resume()
            task = Task { [weak self] in
                guard let self else { return }
                await self.execute(request, tools: tools, directory: directory)
            }
            lock.unlock()
            reply(nil)
        } catch { reply(error.localizedDescription as NSString) }
    }

    private func reviewedTools() throws -> StudyTools {
        let bundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources")
        guard FileManager.default.fileExists(atPath: resources.appendingPathComponent("tool-hashes.json").path) else {
            throw StudyDownloadError.invalidManifest("Reviewed tools are not bundled.")
        }
        let data = try StudyBoundedFile.read(resources.appendingPathComponent("tool-hashes.json"), limit: 4096)
        let hashes = try JSONDecoder().decode([String: String].self, from: data)
        let reviewedData = try StudyBoundedFile.read(resources.appendingPathComponent("reviewed-input-hashes.json"), limit: 4096)
        let reviewed = try JSONDecoder().decode([String: String].self, from: reviewedData)
        guard Set(reviewed.keys) == ["yt-dlp", "deno", "ffmpeg", "ffprobe"],
              reviewed.values.allSatisfy({ $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }) else {
            throw StudyDownloadError.invalidManifest("Reviewed input provenance is missing or invalid.")
        }
        guard Set(hashes.keys) == ["yt-dlp", "deno", "ffmpeg", "ffprobe", "StudyToolLauncher"] else {
            throw StudyDownloadError.invalidManifest("Reviewed tools are not bundled.")
        }
        for (name, expected) in hashes {
            let file = bundle.appendingPathComponent(name)
            var info = stat()
            guard lstat(file.path, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  info.st_nlink == 1, info.st_size > 0, info.st_size <= 300_000_000,
                  (info.st_mode & 0o022) == 0, FileManager.default.isExecutableFile(atPath: file.path) else {
                throw StudyDownloadError.unsafePath
            }
            let digest = SHA256.hash(data: try Data(contentsOf: file, options: .mappedIfSafe))
                .map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw StudyDownloadError.invalidManifest("Bundled tool hash mismatch.") }
        }
        return StudyTools(ytdlp: bundle.appendingPathComponent("yt-dlp"), deno: bundle.appendingPathComponent("deno"),
                          ffmpeg: bundle.appendingPathComponent("ffmpeg"), ffprobe: bundle.appendingPathComponent("ffprobe"))
    }

    private func update(_ body: (inout StudyWorkerStatus) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if !disconnected, var value = job { body(&value); job = value }
    }

    private func execute(_ request: StudyWorkerRequest, tools: StudyTools, directory: URL) async {
        do {
            try Task.checkCancellation()
            let versions = try await tools.versions()
            update { $0.toolVersions = versions }
            update { $0.phase = .downloading }
            let fetcher = YTDLPRestrictedFetcher(ytdlpURL: tools.ytdlp, denoURL: tools.deno, ffmpegLocation: tools.ffmpeg)
            let fetched = try await fetcher.fetch(video: request.video, stagingDirectory: directory) { [weak self] progress in
                self?.update { $0.progress = progress }
            }
            update { $0.phase = .preparingMedia; $0.progress = nil }
            let prepared = try await MediaCompatibilityRepairer(ffprobeURL: tools.ffprobe, ffmpegURL: tools.ffmpeg).prepare(fetched)
            update { $0.phase = .validating }
            let text = directory.appendingPathComponent("\(request.video.id).txt")
            let validation = try await FFprobeMediaValidator(ffprobeURL: tools.ffprobe, ffmpegURL: tools.ffmpeg)
                .validate(mediaURL: prepared, expectedDuration: request.video.expectedDuration, transcriptURL: text)
            try Task.checkCancellation()
            let info = directory.appendingPathComponent("\(request.video.id).info.json")
            var title: String?
            if let metadata = try? StudyBoundedFile.read(info, limit: 2_000_000),
               let object = try? JSONSerialization.jsonObject(with: metadata) as? [String: Any],
               object["id"] as? String == request.video.id, let name = object["title"] as? String {
                title = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(160))
            }
            let output = try StudyOutputSnapshot(file: prepared, expectedSize: validation.fileSize,
                                                 maximumSize: 4_000_000_000)
            var textOutput: StudyOutputSnapshot?
            if validation.transcriptPresent {
                let contents = try StudyBoundedFile.read(text, limit: 2_000_000)
                guard !contents.isEmpty, String(data: contents, encoding: .utf8) != nil else {
                    throw StudyDownloadError.invalidMedia("Transcript is invalid.")
                }
                textOutput = try StudyOutputSnapshot(file: text, expectedSize: Int64(contents.count), maximumSize: 2_000_000)
            }
            publish(output, transcript: textOutput, title: title)
        } catch {
            update { $0.phase = Task.isCancelled ? .cancelled : .failed; $0.problem = String(error.localizedDescription.prefix(1024)) }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func publish(_ file: StudyOutputSnapshot, transcript text: StudyOutputSnapshot?, title: String?) {
        lock.lock(); defer { lock.unlock() }
        guard !disconnected, job?.phase != .cancelled else { return }
        media = file; transcript = text
        job?.title = title
        job?.mediaBytes = file.size
        job?.transcriptBytes = text?.size ?? 0
        job?.phase = .ready
    }

    func status(_ id: NSString, reply: @escaping (NSData?, NSString?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let job, job.jobID.uuidString == id as String else { reply(nil, "Unknown worker job"); return }
        lastActivity = ProcessInfo.processInfo.systemUptime
        do { reply(try JSONEncoder().encode(job) as NSData, nil) }
        catch { reply(nil, error.localizedDescription as NSString) }
    }

    func read(_ id: NSString, kind: NSString, offset: Int64, reply: @escaping (NSData?, NSString?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let job, job.jobID.uuidString == id as String, job.phase == .ready, offset >= 0,
              let file = kind == "media" ? media : (kind == "transcript" ? transcript : nil) else {
            reply(nil, "Output is unavailable"); return
        }
        lastActivity = ProcessInfo.processInfo.systemUptime
        do {
            reply(try file.read(offset: offset) as NSData, nil)
        } catch { reply(nil, error.localizedDescription as NSString) }
    }

    func cancel(_ id: NSString, reply: @escaping () -> Void) {
        lock.lock()
        let matches = job?.jobID.uuidString == id as String
        lock.unlock()
        if matches { disconnect() }
        reply()
    }
    private func expireIdleSession() {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        let expired = !disconnected && (now - lastActivity > 120 || now - beganAt > 3_900)
        lock.unlock()
        if expired { disconnect() }
    }
    func disconnect() {
        lock.lock()
        guard !disconnected else { lock.unlock(); return }
        disconnected = true
        idleTimer?.cancel()
        idleTimer = nil
        job?.phase = .cancelled
        job?.problem = "Worker session ended. Unfinished work can be retried."
        media = nil
        transcript = nil
        task?.cancel()
        let running = task; let directory = root; let release = admitted
        admitted = false
        lock.unlock()
        Task {
            await running?.value
            if let directory { try? FileManager.default.removeItem(at: directory) }
            if release { Self.releaseAdmission() }
        }
    }

    private static func releaseAdmission() {
        admissionLock.lock(); defer { admissionLock.unlock() }
        sessions -= 1
    }

    static func recoverAbandonedStaging() {
        // Called once before accepting clients, inside this XPC sandbox only.
        let temporary = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: temporary,
            includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("ShieldWorker-") {
            let suffix = String(file.lastPathComponent.dropFirst("ShieldWorker-".count))
            var info = stat()
            guard UUID(uuidString: suffix) != nil, lstat(file.path, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR), info.st_uid == geteuid(),
                  Date().timeIntervalSince1970 - Double(info.st_mtimespec.tv_sec) > 86_400 else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
