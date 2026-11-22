import AVFoundation
import Darwin
import Foundation
import os

// Contained online downloads (docs/download-egress-threat-model.md §4).
// Every tool process (yt-dlp, deno, ffmpeg) runs
// under a Seatbelt profile that denies all network except one loopback port
// owned by the egress broker, denies DNS, and denies file writes outside the
// job's staging directory. The broker is the only process with real network
// access and only reaches allowlisted video hosts. System hosts blocking stays
// unchanged for every other process, including browsers.
struct StudyContainment: Sendable {
    let brokerURL: URL
    static let sandboxExec = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
    // Views read availability on every render, so the lookup is cached. It is
    // redone when a cached tool's file is gone (a `brew upgrade` while Shield
    // runs moves the resolved Cellar paths), or when no
    // tools were found yet and a minute has passed since the last look.
    static var discoveredTools: StudyTools? {
        guard enabled, !ShieldRuntime.isUIReview else { return nil }
        return toolCache.withLock { cache in
            let now = Date()
            if let tools = cache.tools,
               [tools.ytdlp, tools.deno, tools.ffmpeg, tools.ffprobe].allSatisfy({
                   FileManager.default.isExecutableFile(atPath: $0.path) }) {
                return tools
            }
            if cache.tools == nil, let last = cache.lastLook, now.timeIntervalSince(last) < 60 { return nil }
            cache.lastLook = now
            cache.tools = try? StudyTools.discover(contained: true)
            return cache.tools
        }
    }

    private struct ToolCache: Sendable {
        var tools: StudyTools?
        var lastLook: Date?
    }
    private static let toolCache = OSAllocatedUnfairLock(initialState: ToolCache())

    // On in the release candidate. Development builds (and their test hosts)
    // use it only when launched with SHIELD_CONTAINED_DOWNLOADS=1.
    static var enabled: Bool {
        #if SHIELD_RC
        return true
        #else
        return ProcessInfo.processInfo.environment["SHIELD_CONTAINED_DOWNLOADS"] == "1"
        #endif
    }

    static var bundled: StudyContainment? {
        guard enabled, !ShieldRuntime.isUIReview else { return nil }
        let broker = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ShieldEgressBroker")
        guard FileManager.default.isExecutableFile(atPath: broker.path),
              FileManager.default.isExecutableFile(atPath: sandboxExec.path) else { return nil }
        return StudyContainment(brokerURL: broker)
    }

    // Seatbelt matches the last applicable rule, so the narrow allows follow the denials.
    ///
    /// Beyond network and writes, the tools may not hand work to anything
    /// outside the sandbox (open URLs or apps, script other apps), may not read
    /// files in the home folder other than themselves and the job's folder
    /// (the user's documents, browser data, the original sign-in file), and,
    /// when `executables` is given, may run only those programs.
    static func toolProfile(stagingDirectory: URL, brokerPort: UInt16, executables: [URL] = []) throws -> String {
        let staging = try canonicalPath(stagingDirectory)
        let home = try canonicalPath(FileManager.default.homeDirectoryForCurrentUser)
        let programs = try executables.map(canonicalPath)
        var profile = """
        (version 1)
        (allow default)
        (deny network-outbound)
        (deny network-bind)
        (deny network-inbound)
        (allow network-outbound (remote ip "localhost:\(brokerPort)"))
        (deny mach-lookup (global-name "com.apple.dnssd.service"))
        (deny mach-lookup (global-name "com.apple.mDNSResponder"))
        (deny mach-lookup (global-name "com.apple.coreservices.launchservicesd"))
        (deny mach-lookup (global-name "com.apple.nsurlsessiond"))
        (deny appleevent-send)
        (deny lsopen)
        (deny file-write*)
        (allow file-write* (subpath "\(staging)") (literal "/dev/null") (literal "/dev/tty") (regex #"^/dev/fd/"))
        (deny file-read-data (subpath "\(home)"))
        (allow file-read-data (subpath "\(staging)")\(programs.map { " (literal \"\($0)\")" }.joined()))
        """
        if !programs.isEmpty {
            profile += "\n(deny process-exec)\n(allow process-exec" + programs.map { " (literal \"\($0)\")" }.joined() + ")"
        }
        return profile
    }

    /// Seatbelt matches the kernel's canonical path. Foundation's symlink
    /// resolution strips "/private" (e.g. /private/var/folders), so use realpath.
    private static func canonicalPath(_ url: URL) throws -> String {
        guard let canonical = realpath(url.path, nil) else { throw StudyDownloadError.unsafePath }
        let path = String(cString: canonical)
        free(canonical)
        guard path.hasPrefix("/"), path.count > 1,
              !path.contains("\""), !path.contains("\\"), !path.contains("\n") else {
            throw StudyDownloadError.unsafePath
        }
        return path
    }
}

extension StudyContainment {
    /// Same as the tool profile with no network at all: for converting a
    /// downloaded file, which needs nothing from the internet.
    static func offlineProfile(stagingDirectory: URL, executables: [URL] = []) throws -> String {
        try toolProfile(stagingDirectory: stagingDirectory, brokerPort: 1, executables: executables)
            .replacingOccurrences(of: "\n(allow network-outbound (remote ip \"localhost:1\"))", with: "")
    }
}

/// Converts a download Apple's player can't play into H.264/AAC MP4, with
/// FFmpeg under the offline Seatbelt profile (no network, writes only in the
/// job's staging folder). Files already in H.264/AAC are left as they are.
struct ContainedMediaRepairer: MediaRepairing {
    let ffmpeg: URL

    static func isPlayable(_ media: URL) async -> Bool {
        let asset = AVURLAsset(url: media)
        guard let tracks = try? await asset.load(.tracks) else { return false }
        var video = false, audio = false
        for track in tracks {
            guard let formats = try? await track.load(.formatDescriptions) else { return false }
            for format in formats {
                let subtype = CMFormatDescriptionGetMediaSubType(format)
                switch track.mediaType {
                case .video: video = video || subtype == kCMVideoCodecType_H264
                case .audio: audio = audio || subtype == kAudioFormatMPEG4AAC
                default: break
                }
            }
        }
        return video && audio
    }

    func prepare(_ source: URL, force: Bool) async throws -> URL {
        if !force, await Self.isPlayable(source) { return source }
        let work = source.deletingLastPathComponent()
        let profile = work.deletingLastPathComponent().appendingPathComponent(".convert-\(UUID().uuidString).sb")
        try Data(StudyContainment.offlineProfile(stagingDirectory: work, executables: [ffmpeg]).utf8)
            .write(to: profile, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: profile) }
        let repaired = source.deletingPathExtension().appendingPathExtension("compatible.mp4")
        let convert = Process()
        convert.executableURL = StudyContainment.sandboxExec
        convert.currentDirectoryURL = work
        convert.environment = ["PATH": "/usr/bin:/bin", "HOME": work.path, "TMPDIR": work.path]
        convert.arguments = ["-f", profile.path, ffmpeg.path, "-nostdin", "-v", "error", "-xerror", "-n",
                             "-i", source.path, "-map", "0:v:0", "-map", "0:a:0",
                             "-c:v", "libx264", "-preset", "veryfast", "-crf", "21", "-pix_fmt", "yuv420p",
                             "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", repaired.path]
        convert.standardOutput = FileHandle.nullDevice
        convert.standardError = FileHandle.nullDevice
        try await StudyProcessRunner(confined: true).run(convert, timeout: 5_400)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: repaired.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard convert.terminationStatus == 0, bytes > 0, await Self.isPlayable(repaired) else {
            throw StudyDownloadError.invalidMedia("This video came in a format Shield couldn't convert for playback.")
        }
        return repaired
    }
}

// One broker per yt-dlp run: random loopback port, random per-job credential,
// bounded lifetime. It exits on its own when the lifetime ends.
final class StudyEgressBrokerProcess: @unchecked Sendable {
    let port: UInt16
    let secret: String
    private let process = Process()
    private let log: Pipe

    init(executable: URL, lifetime: TimeInterval = 3_900) throws {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw StudyDownloadError.invalidManifest("Could not create a download credential.")
        }
        secret = bytes.map { String(format: "%02x", $0) }.joined()
        port = UInt16.random(in: 20_000...60_000)
        let credential = "Basic " + Data("shield:\(secret)".utf8).base64EncodedString()
        process.executableURL = executable
        process.environment = ["SHIELD_BROKER_PORT": String(port), "SHIELD_BROKER_CREDENTIAL": credential,
                               "SHIELD_BROKER_SECONDS": String(Int(min(lifetime, 3_900))),
                               "SHIELD_BROKER_RESOLVER": "doh"]
        log = Pipe()
        process.standardError = log
        process.standardOutput = FileHandle.nullDevice
    }

    var proxyURL: String { "http://shield:\(secret)@127.0.0.1:\(port)" }

    // Waits for the broker's "listening" record; anything else fails closed.
    func start(timeout: TimeInterval = 5) throws {
        let ready = DispatchSemaphore(value: 0)
        let buffer = LockedData()
        log.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; ready.signal(); return }
            if buffer.append(data).range(of: Data("\"event\":\"listening\"".utf8)) != nil { ready.signal() }
        }
        try process.run()
        guard ready.wait(timeout: .now() + timeout) == .success, process.isRunning,
              buffer.contents.range(of: Data("\"mode\":\"doh\"".utf8)) != nil else {
            stop()
            throw StudyDownloadError.invalidManifest("The download network helper did not start.")
        }
        // Keep draining so the broker never blocks on a full pipe.
        log.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
    }

    func stop() {
        log.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    deinit { stop() }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) -> Data {
        lock.lock(); defer { lock.unlock() }
        if data.count < 16_384 { data.append(more) }
        return data
    }
    var contents: Data { lock.lock(); defer { lock.unlock() }; return data }
}

struct StudyContainedFetcher: RestrictedVideoFetching {
    let tools: StudyTools
    let containment: StudyContainment
    var cookiesSource: URL = StudyCookies.file
    /// Tallest video to download (Settings › Video quality).
    var maxHeight: Int = YTDLPRestrictedFetcher.defaultQuality
    // Receives (video ID, title) from yt-dlp's info file after a successful fetch.
    var onMetadata: @Sendable (String, String) -> Void = { _, _ in }

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
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // A sign-in file that can't be used means no sign-in: plain tries still
        // run, and its problem is shown only if YouTube then asks for a sign-in.
        var signInProblem: Error?
        let cookies: URL?
        do { cookies = try StudyCookies.stagedCopy(from: cookiesSource, into: stagingDirectory) } catch {
            cookies = nil
            signInProblem = error
        }
        defer { if let cookies { try? FileManager.default.removeItem(at: cookies) } }
        let fetcher = YTDLPRestrictedFetcher(ytdlpURL: tools.ytdlp, denoURL: tools.deno,
                                             ffmpegLocation: tools.ffmpeg,
                                             containment: .init(start: {
                                                 try Self.startSession(containment, video: video, tools: tools,
                                                                       stagingDirectory: stagingDirectory)
                                             }, cookies: cookies),
                                             maxHeight: maxHeight)
        let output: URL
        do {
            output = try await fetcher.fetch(video: video, stagingDirectory: stagingDirectory,
                                             onProgress: onProgress, onRetry: onRetry)
        } catch let error as StudyDownloadError where YTDLPRestrictedFetcher.asksForSignIn(error) {
            throw signInProblem ?? error
        }
        let info = stagingDirectory.appendingPathComponent("\(video.id).info.json")
        if let data = try? StudyBoundedFile.read(info, limit: 16_000_000), let title = Self.title(fromInfoJSON: data) {
            onMetadata(video.id, title)
        }
        return output
    }

    // A fresh broker for every yt-dlp run, so none reaches the end of its
    // lifetime mid-download. A random port can collide; a fresh broker is
    // tried a bounded number of times.
    static func startSession(_ containment: StudyContainment, video: StudyVideo, tools: StudyTools,
                             stagingDirectory: URL) throws -> YTDLPRestrictedFetcher.Session {
        var lastError: Error?
        for _ in 0..<3 {
            let broker = try StudyEgressBrokerProcess(executable: containment.brokerURL)
            do { try broker.start() } catch { lastError = error; continue }
            let profile = stagingDirectory.deletingLastPathComponent()
                .appendingPathComponent(".\(video.id)-\(UUID().uuidString).sb")
            do {
                // yt-dlp runs deno and ffmpeg/ffprobe; nothing else may start.
                try Data(StudyContainment.toolProfile(stagingDirectory: stagingDirectory, brokerPort: broker.port,
                                                      executables: [tools.ytdlp, tools.deno,
                                                                    tools.ffmpeg, tools.ffprobe]).utf8)
                    .write(to: profile, options: [.atomic])
            } catch {
                broker.stop()
                throw error
            }
            return .init(profile: profile, proxyURL: broker.proxyURL) {
                broker.stop()
                try? FileManager.default.removeItem(at: profile)
            }
        }
        throw lastError ?? StudyDownloadError.invalidManifest("The download network helper did not start.")
    }

    // One line of plain text, 1–160 characters, or nil.
    static func title(fromInfoJSON data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["title"] as? String else { return nil }
        let title = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : String(title.prefix(160))
    }
}

// Optional sign-in for YouTube's bot check. The user
// exports a cookies.txt from a dedicated Google account to `file`; Shield never
// handles a password. Each job gets a private copy inside its staging directory,
// holding only YouTube and Google cookies, so the Seatbelt write rule is
// unchanged. The copy is deleted when the job ends.
enum StudyCookies {
    static var file: URL { ShieldRuntime.supportDirectory.appendingPathComponent("youtube-cookies.txt") }
    static let maximumBytes = 1_048_576

    static func stagedCopy(from source: URL, into staging: URL) throws -> URL? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: source.path) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size > 0, size <= maximumBytes,
              let text = String(data: try Data(contentsOf: source), encoding: .utf8),
              let filtered = filtered(text) else {
            throw StudyDownloadError.invalidManifest("The YouTube sign-in file isn't a cookies.txt export.")
        }
        let copy = staging.appendingPathComponent(".cookies.txt")
        try Data(filtered.utf8).write(to: copy, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
        return copy
    }

    // Netscape format: 7 tab-separated fields per cookie. Nil when none are for YouTube.
    static func filtered(_ text: String) -> String? {
        let kept = text.split(whereSeparator: \.isNewline).filter { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 7 else { return false }
            let domain = fields[0].replacingOccurrences(of: "#HttpOnly_", with: "").lowercased()
            return ["youtube.com", "google.com"].contains { domain == $0 || domain == "." + $0 || domain.hasSuffix("." + $0) }
        }
        guard kept.contains(where: { $0.lowercased().contains("youtube.com") }) else { return nil }
        return (["# Netscape HTTP Cookie File"] + kept.map(String.init)).joined(separator: "\n") + "\n"
    }
}
