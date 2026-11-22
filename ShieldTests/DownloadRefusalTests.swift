import Foundation
import Testing
@testable import Shield

/// A refused try says so: a video YouTube refused sat on
/// "Downloading…" for minutes. A fake yt-dlp refuses (HTTP 403) every player
/// client but one, standing in for the network as in the other downloader tests.
@Suite(.serialized)
struct DownloadRefusalTests {
    static let id = "abcdefghijk"

    init() { WorkingWay.reset() }

    private final class Retries: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [[Int]] = []
        func add(_ number: Int, _ total: Int) { lock.lock(); seen.append([number, total]); lock.unlock() }
        var all: [[Int]] { lock.lock(); defer { lock.unlock() }; return seen }
    }

    /// A fetcher whose yt-dlp works only with `allowedClients` in its arguments.
    private func fetcher(in root: URL, allowedClients: String?) throws -> YTDLPRestrictedFetcher {
        let bin = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let works = allowedClients.map { "case \"$*\" in *\($0)*) printf 'media' > \(Self.id).mp4; exit 0;; esac\n" } ?? ""
        let scripts = [
            "yt-dlp": "#!/bin/sh\n" + works +
                "echo 'ERROR: unable to download video data: HTTP Error 403: Forbidden' >&2\nexit 1\n",
            "deno": "#!/bin/sh\necho 'deno 2.5.0'\n",
            "ffmpeg": "#!/bin/sh\nexit 0\n",
        ]
        for (name, script) in scripts {
            let url = bin.appendingPathComponent(name)
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        return YTDLPRestrictedFetcher(ytdlpURL: bin.appendingPathComponent("yt-dlp"),
                                      denoURL: bin.appendingPathComponent("deno"),
                                      ffmpegLocation: bin.appendingPathComponent("ffmpeg"))
    }

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldRefusal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private var video: StudyVideo {
        StudyVideo(id: Self.id, title: "One lesson", expectedDuration: 60, transcriptRequested: false)
    }

    @Test func eachRefusedTrySaysWhichWayIsNext() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = try fetcher(in: root, allowedClients: "player_client=tv,web_safari")
        let retries = Retries()
        let output = try await fetcher.fetch(video: video, stagingDirectory: root.appendingPathComponent("work"),
                                             onProgress: { _ in }, onRetry: { retries.add($0, $1) })
        #expect(try String(contentsOf: output, encoding: .utf8) == "media")
        #expect(retries.all == [[2, 3]], "The first way was refused; the second worked")
    }

    @Test func refusedEveryWayEndsWithTheRefusal() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = try fetcher(in: root, allowedClients: nil)
        let retries = Retries()
        await #expect(throws: StudyDownloadError.self) {
            _ = try await fetcher.fetch(video: video, stagingDirectory: root.appendingPathComponent("work"),
                                        onProgress: { _ in }, onRetry: { retries.add($0, $1) })
        }
        #expect(retries.all == [[2, 3], [3, 3]])
    }

    /// The row's text: the note while another way is tried, plain
    /// "Downloading…" again once bytes arrive.
    @Test func theCoordinatorPassesTheNoteToTheRow() async throws {
        struct Refusing: RestrictedVideoFetching {
            func fetch(video: StudyVideo, stagingDirectory: URL) async throws -> URL {
                throw StudyDownloadError.toolReported("yt-dlp", "unable to download video data: HTTP Error 403: Forbidden")
            }
            func fetch(video: StudyVideo, stagingDirectory: URL, onProgress: @escaping @Sendable (Double) -> Void,
                       onRetry: @escaping @Sendable (Int, Int) -> Void) async throws -> URL {
                onRetry(2, 4)
                onProgress(0.5)
                return try await fetch(video: video, stagingDirectory: stagingDirectory)
            }
        }
        final class Updates: @unchecked Sendable {
            private let lock = NSLock()
            private var jobs: [StudyJob] = []
            func add(_ job: StudyJob) { lock.lock(); jobs.append(job); lock.unlock() }
            var all: [StudyJob] { lock.lock(); defer { lock.unlock() }; return jobs }
        }
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let updates = Updates()
        let coordinator = StudyDownloadCoordinator(fetcher: Refusing(), validator: NativeLocalMediaValidator())
        let jobs = await coordinator.run(manifest: StudyManifest(schemaVersion: 1, courseTitle: "Refused", videos: [video]),
                                         stagingDirectory: root) { updates.add($0) }
        let notes = updates.all.map(\.note)
        #expect(notes.contains("YouTube refused it. Trying another way (2 of 4)…"))
        #expect(notes.contains("Trying again…"), "The second round says so")
        #expect(updates.all.contains { $0.progress == 0.5 && $0.note == nil }, "Bytes arriving clear the note")
        // Two rounds, not three: a refusal isn't retried a third time.
        #expect(updates.all.filter { if case .downloading = $0.state { $0.note == nil && $0.progress == nil } else { false } }.count == 1)
        guard case .failed(let reason) = try #require(jobs.first).state else { Issue.record("Expected a failure"); return }
        #expect(StudyFailureText.describe(reason, signInFilePresent: false).text.contains("refused"))
    }

    /// The way that worked goes first next time, for two hours, and is
    /// forgotten as soon as it fails.
    @Test func theWayThatWorkedGoesFirstUntilItFails() async throws {
        let ways = YTDLPRestrictedFetcher.attempts(hasSignIn: true)
        let now = Date()
        #expect(WorkingWay.ordered(ways, now: now) == ways)
        WorkingWay.worked(ways[1], now: now)
        let ordered = WorkingWay.ordered(ways, now: now)
        #expect(ordered.first == ways[1])
        #expect(ordered.count == ways.count && ways.allSatisfy(ordered.contains), "Every way is still tried")
        #expect(WorkingWay.ordered(ways, now: now.addingTimeInterval(WorkingWay.remembered + 1)) == ways, "Forgotten after a while")
        #expect(WorkingWay.ordered(YTDLPRestrictedFetcher.attempts(hasSignIn: false), now: now)
                == YTDLPRestrictedFetcher.attempts(hasSignIn: false), "A signed-in way isn't used without the sign-in file")
        WorkingWay.failed(ways[1])
        #expect(WorkingWay.ordered(ways, now: now) == ways)

        // End to end: after tv,web_safari worked once, the next video starts with it.
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fetcher = try fetcher(in: root, allowedClients: "player_client=tv,web_safari")
        _ = try await fetcher.fetch(video: video, stagingDirectory: root.appendingPathComponent("one"))
        let retries = Retries()
        _ = try await fetcher.fetch(video: video, stagingDirectory: root.appendingPathComponent("two"),
                                    onProgress: { _ in }, onRetry: { retries.add($0, $1) })
        #expect(retries.all.isEmpty, "No refused try for the second video")
    }

    @Test func eachRefusedWayIsLoggedBrieflyWithoutCookies() throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("download-problems.log")
        let way = YTDLPRestrictedFetcher.attempts(hasSignIn: true)[1]
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        DownloadProblemLog.note(videoID: Self.id, way: way,
                                error: .toolReported("yt-dlp", "unable to download video data: HTTP Error 403: Forbidden"),
                                to: log, now: date)
        DownloadProblemLog.note(videoID: Self.id, way: way, error: .cancelled, to: log, now: date)
        let text = try String(contentsOf: log, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 1, "Stop isn't a problem")
        #expect(text.contains("\(Self.id) [default,-web_embedded, signed in]"))
        #expect(text.contains("HTTP Error 403"))
        for _ in 0..<400 {
            DownloadProblemLog.note(videoID: Self.id, way: way, error: .toolReported("yt-dlp", String(repeating: "x", count: 250)),
                                    to: log, now: date)
        }
        #expect(try Data(contentsOf: log).count <= DownloadProblemLog.maximumBytes, "Kept small")
    }
}
