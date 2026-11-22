import Foundation
import Testing
@testable import Shield

/// Download Again: a saved video fetched again at the chosen
/// quality, with the transcript's timing. Fake yt-dlp/ffmpeg/ffprobe scripts
/// stand in for the network, as in the other downloader tests. The saved copy
/// must stay saved and playable whatever happens to the new one.
@MainActor
@Suite(.serialized)
struct DownloadAgainTests {
    static let id = "abcdefghijk"

    /// yt-dlp that writes `media` (and, when `captions`, an English caption
    /// file), fails with `exitCode`, or first waits `delay` seconds.
    private func ytdlp(media: String, captions: Bool = false, exitCode: Int = 0, delay: Int = 0) -> String {
        var script = "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo '2026.01.01'; exit 0; fi\n"
        if delay > 0 { script += "sleep \(delay)\n" }
        if exitCode != 0 { return script + "echo 'ERROR: fixture failure' >&2\nexit \(exitCode)\n" }
        script += "printf '\(media)' > \(Self.id).mp4\n"
        if captions {
            let vtt = "WEBVTT\\nKind: captions\\nLanguage: en\\n\\n" +
                "00:00:00.500 --> 00:00:03.000 align:start position:0%\\n \\nwelcome back\\n\\n" +
                "00:00:03.000 --> 00:00:06.000 align:start position:0%\\nwelcome back\\nto the lesson\\n"
            // "%" is printf's own marker: "position:0%" must be written as "0%%".
            script += "printf '\(vtt.replacingOccurrences(of: "%", with: "%%"))' > \(Self.id).en.vtt\n"
        }
        return script
    }

    private struct Fixture {
        let model: ShieldViewModel
        let root: URL
        let tools: URL
        var library: URL { root.appendingPathComponent("library") }
    }

    private func install(_ script: String, in tools: URL) throws {
        let url = tools.appendingPathComponent("yt-dlp")
        try? FileManager.default.removeItem(at: url)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// A course with one video, downloaded once ("first-copy", no captions).
    private func savedVideo() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldDownloadAgain-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // The fixture backend's own hosts file (never the system one).
        try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
        let backend = try FixtureBackend(root: root)
        let now = Date()
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: now, commands: [.add(DomainRestriction(owner: .permanent,
                policyID: "safe-fixture", title: "Fixture", domains: ["fixture.example"]))]),
            now: now, calendar: .current)
        let bin = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let others = [
            "deno": "#!/bin/sh\necho 'deno 2.5.0'\n",
            "ffmpeg": "#!/bin/sh\nif [ \"$1\" = \"-version\" ]; then echo 'ffmpeg version 8.0'; fi\nexit 0\n",
            "ffprobe": "#!/bin/sh\nif [ \"$1\" = \"-version\" ]; then echo 'ffprobe version 8.0'; exit 0; fi\nprintf '{\"format\":{\"duration\":\"60\",\"format_name\":\"mp4\"},\"streams\":[{\"codec_type\":\"video\",\"codec_name\":\"h264\"},{\"codec_type\":\"audio\",\"codec_name\":\"aac\"}]}'\n",
        ]
        for (name, script) in others {
            let url = bin.appendingPathComponent(name)
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        try install(ytdlp(media: "first-copy"), in: bin)
        let tools = StudyTools(ytdlp: bin.appendingPathComponent("yt-dlp"), deno: bin.appendingPathComponent("deno"),
                               ffmpeg: bin.appendingPathComponent("ffmpeg"), ffprobe: bin.appendingPathComponent("ffprobe"))
        let manifest = StudyManifest(schemaVersion: 1, courseTitle: "Fixture Course", videos: [
            StudyVideo(id: Self.id, title: "One lesson", expectedDuration: 60, transcriptRequested: false)])
        let manifestURL = root.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let model = ShieldViewModel(authorityReader: AuthorityStateReader(fileURL: backend.paths.authority),
                                    enforcementReader: HostsEnforcementReader(fileURL: backend.paths.hosts),
                                    studyLibraryRoot: root.appendingPathComponent("library"),
                                    fixtureBackend: backend, studyToolsOverride: tools)
        model.refresh(now: now)
        model.importStudyManifest(from: manifestURL)
        for _ in 0..<400 where model.isRestoringStudy { try await Task.sleep(for: .milliseconds(30)) }
        model.approveStudyCourse()
        model.startDownloads()
        try await finish(model)
        let saved = try #require(model.mediaURL(for: Self.id), "First download: \(model.studyMessage ?? "")")
        #expect(try String(contentsOf: saved, encoding: .utf8) == "first-copy")
        return Fixture(model: model, root: root, tools: bin)
    }

    private func finish(_ model: ShieldViewModel) async throws {
        for _ in 0..<400 where model.isDownloading { try await Task.sleep(for: .milliseconds(30)) }
        #expect(!model.isDownloading)
    }

    private func isSaved(_ model: ShieldViewModel) -> Bool {
        guard let job = model.studyJobs.first(where: { $0.id == Self.id }), case .complete = job.state else { return false }
        return true
    }

    @Test func replacesTheCopyAndAddsTheTimedTranscript() async throws {
        let fixture = try await savedVideo()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.model
        let folder = try #require(model.mediaURL(for: Self.id)).deletingLastPathComponent()
        try install(ytdlp(media: "second-copy", captions: true), in: fixture.tools)

        model.refresh(now: Date())
        model.downloadAgain(id: Self.id)
        #expect(model.isDownloading)
        #expect(model.redownloadingIDs == [Self.id])
        #expect(isSaved(model), "It stays saved while the new copy is fetched")
        try await finish(model)

        #expect(model.redownloadingIDs.isEmpty)
        #expect(isSaved(model))
        let saved = try #require(model.mediaURL(for: Self.id))
        #expect(try String(contentsOf: saved, encoding: .utf8) == "second-copy", "\(model.studyMessage ?? "")")
        let store = StudyPlaybackStore(root: folder)
        #expect(try store.transcript(videoID: Self.id) == "Welcome back to the lesson\n")
        let cues = try #require(try store.cues(videoID: Self.id))
        #expect(cues.map(\.text) == ["welcome back", "to the lesson"])
        #expect(abs(cues[0].start - 0.5) < 0.001)
        #expect(model.studyMessage == "Downloaded “\(model.libraryTitle(Self.id))” again.")
    }

    @Test func aFailedTryKeepsTheSavedCopy() async throws {
        let fixture = try await savedVideo()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.model
        try install(ytdlp(media: "", exitCode: 1), in: fixture.tools)

        model.refresh(now: Date())
        model.downloadAgain(id: Self.id)
        try await finish(model)

        #expect(isSaved(model), "A failed try never marks a saved video as failed")
        #expect(try String(contentsOf: try #require(model.mediaURL(for: Self.id)), encoding: .utf8) == "first-copy")
        #expect(model.studyMessage?.contains("The saved copy is unchanged") == true)
        #expect(model.redownloadingIDs.isEmpty)
    }

    @Test func stoppingKeepsTheSavedCopy() async throws {
        let fixture = try await savedVideo()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.model
        try install(ytdlp(media: "never-written", delay: 5), in: fixture.tools)

        model.refresh(now: Date())
        model.downloadAgain(id: Self.id)
        try await Task.sleep(for: .milliseconds(400))
        model.cancelDownloads()
        try await finish(model)

        #expect(isSaved(model), "Stop doesn't turn a saved video into an unsaved one")
        #expect(try String(contentsOf: try #require(model.mediaURL(for: Self.id)), encoding: .utf8) == "first-copy")
    }

    @Test func onlySavedVideosAndNotWhileDownloading() async throws {
        let fixture = try await savedVideo()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.model
        model.downloadAgain(id: "zzzzzzzzzzz")
        #expect(!model.isDownloading, "Unknown videos are ignored")
        try install(ytdlp(media: "second-copy", delay: 2), in: fixture.tools)
        model.refresh(now: Date())
        model.downloadAgain(id: Self.id)
        #expect(model.isDownloading)
        model.downloadAgain(id: Self.id) // a second press while it runs does nothing
        #expect(model.redownloadingIDs == [Self.id])
        try await finish(model)
    }
}
