import Foundation
import Testing
@testable import Shield

struct PersistenceAndDownloaderTests {
    @Test func ambiguousVideoLinksAndOversizedPastesNeverEnterQueue() {
        for link in ["https://youtube.com/watch?v=abcdefghijk&v=lmnopqrstuv",
                     "https://youtube.com/watch?v=abcdefghijk&v=abcdefghijk",
                     "https://youtu.be/abcdefghijk?v=lmnopqrstuv",
                     "https://youtube.com/shorts/abcdefghijk?v=lmnopqrstuv",
                     "https://youtu.be//abcdefghijk", "https://youtu.be/abcdefghijk/",
                     "https://youtube.com/%77atch?v=abcdefghijk"] {
            let result = StudyYouTubeLinks.parse(link)
            #expect(result.ids.isEmpty)
            #expect(result.rejectedCount == 1)
        }
        let oversized = StudyYouTubeLinks.parse("https://youtu.be/abcdefghijk " + String(repeating: "x", count: 32_768))
        #expect(oversized.tooMany && oversized.ids.isEmpty)
        #expect(StudyYouTubeLinks.parse("https://youtube.com/watch?v=abcdefghijk&t=12").ids == ["abcdefghijk"])
    }

    @Test func storageBudgetBoundsRejectEmptyAndOversizedSourcesWithoutOverflow() throws {
        #expect(try StudyStorageBudget.requiredBytes(sourceBytes: 1) == 268_435_459)
        #expect(try StudyStorageBudget.requiredBytes(sourceBytes: 4_000_000_000) == 12_268_435_456)
        for bytes in [Int64(0), -1, 4_000_000_001, Int64.max] {
            #expect(throws: StudyDownloadError.self) { try StudyStorageBudget.requiredBytes(sourceBytes: bytes) }
        }
    }

    @Test func explicitMP4FileAndFolderSelectionsRejectSymlinksAndDoNotRecurse() throws {
        let root = try testDirectory()
        let folder = root.appendingPathComponent("chosen", isDirectory: true)
        let nested = folder.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let media = folder.appendingPathComponent("Lecture [abcdefghijk].mp4")
        let transcript = folder.appendingPathComponent("Lecture [abcdefghijk].txt")
        try Data("fixture".utf8).write(to: media)
        try Data("transcript".utf8).write(to: transcript)
        try Data("nested".utf8).write(to: nested.appendingPathComponent("other.mp4"))
        try FileManager.default.createSymbolicLink(
            at: folder.appendingPathComponent("linked.mp4"), withDestinationURL: media)
        let chosen = try StudyMediaSourceSelection.collect(from: [media, folder])
        let canonical = { (url: URL) in url.resolvingSymlinksInPath().standardizedFileURL.path }
        #expect(chosen.count == 2)
        #expect(Set(chosen.map(canonical)) == Set([media, transcript].map(canonical)))
        #expect(StudyMediaImportMatcher.candidates(for: "abcdefghijk", in: chosen)
            .map(canonical) == [canonical(media)])
        #expect(throws: StudyDownloadError.self) {
            try StudyMediaSourceSelection.collect(from: [
                folder.appendingPathComponent("linked.mp4")])
        }
        #expect(throws: StudyDownloadError.self) {
            try StudyMediaSourceSelection.collect(from: [folder], maximumFiles: 1)
        }
    }


    @Test func youtubeLinksAcceptMixedPasteAndRejectHostConfusion() {
        let parsed = StudyYouTubeLinks.parse("""
            https://www.youtube.com/watch?v=abcdefghijk
            https://youtu.be/lmnopqrstuv
            https://youtube.com/shorts/abcdefghijk
            https://youtube.com.evil.test/watch?v=abcdefghijk
            http://youtu.be/abcdefghijk
            https://someone@youtu.be/abcdefghijk
            https://youtu.be/short
            """)
        #expect(parsed.ids == ["abcdefghijk", "lmnopqrstuv"])
        #expect(parsed.rejectedCount == 4)
        #expect(!parsed.tooMany)
        #expect(StudyYouTubeLinks.parse(Array(repeating: "https://youtu.be/abcdefghijk",
                                              count: 101).joined(separator: " ")).tooMany)
    }

    @Test func exactVideoLinkCollectionAllowsUnknownDurationButRejectsBadDuration() throws {
        let local = StudyManifest(schemaVersion: 1, courseTitle: "Queued videos",
            videos: [StudyVideo(id: "abcdefghijk", title: "Video abcdefghijk",
                                expectedDuration: nil, transcriptRequested: false)])
        #expect(try local.validated().videos.count == 1)
        let invalid = StudyManifest(schemaVersion: 1, courseTitle: "Queued videos",
            videos: [StudyVideo(id: "abcdefghijk", title: "Video abcdefghijk",
                                expectedDuration: .infinity, transcriptRequested: false)])
        #expect(throws: StudyDownloadError.self) { try invalid.validated() }
    }

    @Test func injectedRequestStoreWritesOnlyItsOwnFixture() throws {
        let root = try testDirectory()
        let chosen = root.appendingPathComponent("chosen.plist")
        let unrelated = root.appendingPathComponent("unrelated.plist")
        try Data("sentinel".utf8).write(to: unrelated)
        let store = PolicyRequestStore(fileURL: chosen)
        let request = PolicyRequest(youtubeEnabled: true, socialEnabled: false)
        try store.save(request)
        #expect(try store.load().youtubeEnabled)
        #expect(try !store.load().socialEnabled)
        #expect(try String(contentsOf: unrelated, encoding: .utf8) == "sentinel")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("config.plist").path))
    }

    @Test func firstRunDefaultsRequireTrulyAbsentPreferences() throws {
        let root = try testDirectory()
        let settings = root.appendingPathComponent("first-run.plist")
        let store = PolicyRequestStore(fileURL: settings)
        let defaults = try store.load()
        #expect(defaults.youtubeEnabled == false)
        #expect(defaults.socialEnabled == true)
        #expect(defaults.windowMinutes["YouTubeStartMinutes"] == 840)
        #expect(defaults.windowMinutes["YouTubeEndMinutes"] == 1_080)
        #expect(!FileManager.default.fileExists(atPath: settings.path))
        try Data().write(to: settings)
        #expect(throws: Error.self) { try store.load() }
        try FileManager.default.removeItem(at: settings)
        try Data("unrelated file".utf8).write(to: root.appendingPathComponent("outside.txt"))
        try FileManager.default.createSymbolicLink(
            at: settings, withDestinationURL: root.appendingPathComponent("outside.txt"))
        #expect(throws: Error.self) { try store.load() }
    }

    @Test func managedHostsPreservesUnrelatedEntries() throws {
        let original = """
        127.0.0.1 localhost
        10.0.0.5 intranet.local
        # BEGIN KAIROS
        0.0.0.0 old.example
        # END KAIROS
        """
        let updated = try ManagedHostsDocument().replacingManagedSection(
            in: original,
            domains: ["permanent.example", "october.example"]
        )
        #expect(updated.contains("10.0.0.5 intranet.local"))
        #expect(!updated.contains("old.example"))
        #expect(updated.contains("0.0.0.0 permanent.example"))
        #expect(updated.contains("0.0.0.0 october.example"))
        #expect(updated.contains("::1 permanent.example"))
        #expect(updated.contains("::1 october.example"))
    }

    @Test func malformedManagedMarkersAreRejected() {
        let original = """
        127.0.0.1 localhost
        # BEGIN KAIROS
        0.0.0.0 example.com
        """
        #expect(throws: ReconciliationError.self) {
            try ManagedHostsDocument().replacingManagedSection(
                in: original,
                domains: []
            )
        }
    }

    @Test func duplicatedMarkersAndInvalidDomainsAreRejected() {
        for text in [
            "# BEGIN KAIROS\n# BEGIN KAIROS\n# END KAIROS",
            "# END KAIROS\n# BEGIN KAIROS",
            "# BEGIN KAIROS\n0.0.0.0 bad/name\n# END KAIROS"
        ] {
            #expect(throws: Error.self) { _ = try HostsEnforcementReader().parse(text) }
        }
    }

    @Test func atomicStoreRejectsSymlinkedRoot() throws {
        let root = try testDirectory()
        let link = root.deletingLastPathComponent().appendingPathComponent("root-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(throws: ReconciliationError.self) {
            try AtomicFixtureStore(allowedRoot: link).write(Data("bad".utf8), to: link.appendingPathComponent("state"))
        }
    }

    @Test func atomicStoreRejectsSymlink() throws {
        let root = try testDirectory()
        let real = root.appendingPathComponent("real")
        let link = root.appendingPathComponent("link")
        try Data("safe".utf8).write(to: real)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: real
        )

        #expect(throws: ReconciliationError.self) {
            try AtomicFixtureStore(allowedRoot: root).write(
                Data("replacement".utf8),
                to: link
            )
        }
        #expect(try String(contentsOf: real, encoding: .utf8) == "safe")
    }

    @Test func interruptedTemporaryWriteDoesNotReplaceDestination() throws {
        let root = try testDirectory()
        let destination = root.appendingPathComponent("authority.plist")
        try Data("valid".utf8).write(to: destination)
        let abandoned = root.appendingPathComponent(".authority.plist.interrupted.tmp")
        try Data("partial".utf8).write(to: abandoned)

        #expect(try String(contentsOf: destination, encoding: .utf8) == "valid")
    }

    @Test func exclusiveLockRejectsConcurrentOwner() throws {
        let root = try testDirectory()
        let lockURL = root.appendingPathComponent("reconcile.lock")
        let first = try ExclusiveFileLock(url: lockURL)
        #expect(throws: ReconciliationError.self) {
            _ = try ExclusiveFileLock(url: lockURL)
        }
        withExtendedLifetime(first) {}
    }

    @Test func fixtureReconciliationKeepsCommittedDomainsAcrossRestart() throws {
        let root = try testDirectory()
        let now = Date()
        let authorityURL = root.appendingPathComponent("authority.plist")
        let hostsURL = root.appendingPathComponent("hosts")
        let lockURL = root.appendingPathComponent("reconcile.lock")
        let state = AuthorityState(
            schemaVersion: 1, generation: 3, generatedAt: now, reconciliationID: UUID(),
            lastSuccessfulReconciliation: now, commitments: [],
            effectiveRestrictions: [DomainRestriction(owner: .permanent, policyID: "fixture",
                                                       title: "Fixture", domains: ["committed.example"])]
        )
        try PropertyListEncoder().encode(state).write(to: authorityURL)
        try Data("127.0.0.1 localhost\n".utf8).write(to: hostsURL)
        let paths = ReconciliationPaths(authorityURL: authorityURL, hostsURL: hostsURL, lockURL: lockURL)
        let reconciler = FixtureReconciler(paths: paths, allowedRoot: root, maximumAuthorityAge: 300)
        let first = try reconciler.reconcile(requestedDomains: ["new.example"], now: now)
        #expect(first.immediateStrengthening == ["new.example"])
        #expect(first.delayedWeakening == ["committed.example"])
        let second = try reconciler.reconcile(requestedDomains: [], now: now)
        #expect(second.effectiveDomains.contains("committed.example"))
        #expect(try String(contentsOf: hostsURL, encoding: .utf8).contains("0.0.0.0 committed.example"))
    }

    @Test func manifestRejectsDuplicateAndUnsafeIDs() {
        let duplicate = StudyManifest(
            schemaVersion: 1,
            courseTitle: "Course",
            videos: [
                StudyVideo(id: "same", title: "One", expectedDuration: nil, transcriptRequested: false),
                StudyVideo(id: "same", title: "Two", expectedDuration: nil, transcriptRequested: false)
            ]
        )
        let unsafe = StudyManifest(
            schemaVersion: 1,
            courseTitle: "Course",
            videos: [
                StudyVideo(id: "../escape", title: "Unsafe", expectedDuration: nil, transcriptRequested: false)
            ]
        )
        #expect(throws: StudyDownloadError.self) { try duplicate.validated() }
        #expect(throws: StudyDownloadError.self) { try unsafe.validated() }
    }

    @Test func manifestRejectsInvalidExplicitDuration() {
        let missingDuration = StudyManifest(schemaVersion: 1, courseTitle: "Course", videos: [
            StudyVideo(id: "abcdefghijk", title: "Lecture", expectedDuration: nil, transcriptRequested: false)
        ])
        let badDuration = StudyManifest(schemaVersion: 1, courseTitle: "Course", videos: [
            StudyVideo(id: "abcdefghijk", title: "Lecture", expectedDuration: .infinity, transcriptRequested: false)
        ])
        #expect((try? missingDuration.validated()) != nil)
        #expect(throws: StudyDownloadError.self) { try badDuration.validated() }
    }

    @Test func subprocessCancellationStopsChild() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let task = Task { try await StudyProcessRunner().run(process, timeout: 20) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            try await task.value
            Issue.record("Expected cancellation.")
        } catch {
            #expect(!process.isRunning)
        }
    }

    @Test func containedLauncherLimitsDescriptorsAndCancelsDescendants() async throws {
        let root = try testDirectory()
        let limit = Process()
        let output = Pipe()
        limit.executableURL = URL(fileURLWithPath: "/bin/sh")
        limit.arguments = ["-c", "ulimit -n"]
        limit.standardOutput = output
        limit.standardError = FileHandle.nullDevice
        try await StudyProcessRunner().run(limit, timeout: 5)
        let descriptorLimit = String(data: output.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(descriptorLimit == "256")

        let marker = root.appendingPathComponent("leaked-child")
        let script = root.appendingPathComponent("descendant.sh")
        try Data("(sleep 2; echo leaked > \"\(marker.path)\") & wait\n".utf8).write(to: script)
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = [script.path]
        parent.standardOutput = FileHandle.nullDevice
        parent.standardError = FileHandle.nullDevice
        let task = Task { try await StudyProcessRunner().run(parent, timeout: 10) }
        try await Task.sleep(for: .milliseconds(250))
        task.cancel()
        await #expect(throws: Error.self) { try await task.value }
        try await Task.sleep(for: .seconds(3))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func exitedLeaderCannotLeaveTermIgnoringDescendant() async throws {
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("escaped-child")
        let script = root.appendingPathComponent("leader.sh")
        try Data("(trap '' TERM; sleep 5; echo leaked > '\(marker.path)') &\nsleep 0.3\nexit 0\n".utf8).write(to: script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try await StudyProcessRunner().run(process, timeout: 10)
        #expect(process.terminationStatus == 0)
        try await Task.sleep(for: .seconds(3))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func downloaderRetriesOnlyFailedVideo() async {
        let counter = AttemptCounter(failuresBeforeSuccess: 1)
        let coordinator = StudyDownloadCoordinator(
            fetcher: FixtureFetcher(counter: counter),
            validator: FixtureValidator(),
            maximumAttempts: 3
        )
        let manifest = StudyManifest(
            schemaVersion: 1,
            courseTitle: "Fixture Course",
            videos: [
                StudyVideo(
                    id: "lessonVid13",
                    title: "Lesson 13",
                    expectedDuration: 60,
                    transcriptRequested: true
                )
            ]
        )
        let jobs = await coordinator.run(
            manifest: manifest,
            stagingDirectory: FileManager.default.temporaryDirectory
        )
        #expect(jobs.count == 1)
        guard case .complete(let validation) = jobs.first?.state else {
            Issue.record("Expected successful retry.")
            return
        }
        #expect(validation.isPlayable)
        #expect(await counter.attempts == 2)
    }

    @Test func mediaCorruptionBecomesJobFailure() async {
        let coordinator = StudyDownloadCoordinator(
            fetcher: AlwaysSucceedsFetcher(),
            validator: CorruptFixtureValidator(),
            maximumAttempts: 2
        )
        let manifest = StudyManifest(
            schemaVersion: 1,
            courseTitle: "Fixture Course",
            videos: [
                StudyVideo(
                    id: "approved123",
                    title: "Damaged",
                    expectedDuration: 60,
                    transcriptRequested: false
                )
            ]
        )
        let jobs = await coordinator.run(
            manifest: manifest,
            stagingDirectory: FileManager.default.temporaryDirectory
        )
        guard case .failed = jobs.first?.state else {
            Issue.record("Expected validation failure.")
            return
        }
    }

    @Test func transcriptCleanerRemovesTimestampsAndDuplicates() {
        let raw = """
        00:00:01.000 Introduction
        00:00:02.000 Introduction

        01:03 Next concept
        """
        let clean = TranscriptCleaner().clean(raw)
        #expect(clean == "Introduction\nNext concept")
    }

    @Test func transcriptFormatterAddsTitleAndJoinsRollingCaptions() {
        let vtt = """
        WEBVTT
        Kind: captions
        Language: en

        00:00:00.000 --> 00:00:02.000
        <c>hi everyone welcome</c>

        00:00:02.000 --> 00:00:04.000
        hi everyone welcome
        to my channel &amp; more
        """
        let text = TranscriptFormatter().document(title: "Lesson 1", vtt: vtt)
        #expect(text == "Lesson 1\n\nHi everyone welcome to my channel & more\n")
        #expect(TranscriptFormatter().document(title: "Lesson 1", vtt: "WEBVTT\nKind: captions\n") == "")
    }

    @Test func transcriptFormatterStartsParagraphsAtPausesOnceLong() {
        func cue(_ second: Int, _ words: Int, _ word: String) -> String {
            "00:00:\(String(format: "%02d", second)).000 --> 00:00:\(String(format: "%02d", second + 1)).000\n"
                + Array(repeating: word, count: words).joined(separator: " ") + "\n"
        }
        // 30 + 40 words, then a 9 s pause: one break, after the 70th word.
        let vtt = "WEBVTT\n\n" + [cue(0, 30, "a"), cue(1, 40, "b"), cue(10, 5, "c")].joined(separator: "\n")
        let paragraphs = TranscriptFormatter().document(title: nil, vtt: vtt)
            .trimmingCharacters(in: .newlines).components(separatedBy: "\n\n")
        #expect(paragraphs.count == 2)
        #expect(paragraphs.first?.split(separator: " ").count == 70)
        #expect(paragraphs.last == "C c c c c")
    }

    @Test func olderOneLinePerCaptionTranscriptsReadAsParagraphs() {
        let saved = "Kind: captions\nLanguage: en\nhi everyone\nwelcome to my channel"
        #expect(TranscriptFormatter().readable(saved) == "Hi everyone welcome to my channel\n")
        let formatted = "Title\n\nAlready formatted.\n"
        #expect(TranscriptFormatter().readable(formatted) == formatted)
        let imported = "Line one\nLine two"
        #expect(TranscriptFormatter().readable(imported) == imported)
    }

    @Test func validatedInstallerNeverOverwritesWithInvalidMedia() throws {
        let root = try testDirectory()
        let staged = root.appendingPathComponent("staged.mp4")
        let library = root.appendingPathComponent("library", isDirectory: true)
        try Data("candidate".utf8).write(to: staged)
        try FileManager.default.createDirectory(
            at: library,
            withIntermediateDirectories: true
        )
        let existing = library.appendingPathComponent("approved.mp4")
        try Data("known-good".utf8).write(to: existing)

        let invalid = MediaValidation(
            duration: 0,
            hasVideo: false,
            hasAudio: false,
            fileSize: 0,
            transcriptPresent: false
        )
        #expect(throws: StudyDownloadError.self) {
            try ValidatedMediaInstaller(libraryRoot: library).install(
                stagedMedia: staged,
                validation: invalid,
                videoID: "approved"
            )
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "known-good")
    }

    @MainActor
    @Test func viewModelSurfacesEmptyAuthorityAsError() {
        let model = ShieldViewModel(
            authorityReader: FixedAuthorityReader(status: .unavailable(.empty)),
            enforcementReader: FixedEnforcementReader(),
            installationInspector: BackendInstallationInspector()
        )
        model.refresh()
        #expect(model.authorityError?.contains("empty") == true)
        #expect(!model.health.isVerifiedHealthy)
    }

    @Test func savedLibraryStateSurvivesRestartAndRejectsUnknownVideo() throws {
        let root = try testDirectory()
        let manifest = StudyManifest(schemaVersion: 1, courseTitle: "Fixture course",
                                     videos: [StudyVideo(id: "abcdefghijk", title: "Lesson",
                                                         expectedDuration: 90, transcriptRequested: false)])
        let store = StudyLibraryStore(root: root)
        let saved = StudyLibrarySnapshot(version: 1, manifest: manifest,
                                         completedIDs: ["abcdefghijk"], failures: [:], updatedAt: .now)
        try store.save(saved)
        #expect(try StudyLibraryStore(root: root).load()?.completedIDs == ["abcdefghijk"])
        let invalid = StudyLibrarySnapshot(version: 1, manifest: manifest,
                                           completedIDs: ["unknown"], failures: [:], updatedAt: .now)
        #expect(throws: StudyDownloadError.self) { try store.save(invalid) }
        #expect(try store.load()?.completedIDs == saved.completedIDs)
        try JSONEncoder().encode(invalid).write(to: root.appendingPathComponent("library-state.json"))
        #expect(throws: StudyDownloadError.self) { try store.load() }
    }

    @Test func toolDiscoveryFindsLocalToolsAndRunsVersionChecks() async throws {
        let home = try testDirectory()
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for name in ["yt-dlp", "deno", "ffmpeg", "ffprobe"] {
            let file = bin.appendingPathComponent(name)
            let version = ["yt-dlp": "2026.01.01", "deno": "deno 2.5.0",
                           "ffmpeg": "ffmpeg version 8.0", "ffprobe": "ffprobe version 8.0"][name]!
            try Data("#!/bin/sh\nprintf '\(version)\\n'\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let tools = try StudyTools.discover(home: home, searchRoots: [])
        #expect(tools.ytdlp.path == bin.appendingPathComponent("yt-dlp").path)
        #expect(try await tools.versions()["ffprobe"] == "ffprobe version 8.0")
        try Data("#!/bin/sh\nprintf '2024.12.31\\n'\n".utf8)
            .write(to: bin.appendingPathComponent("yt-dlp"))
        await #expect(throws: StudyDownloadError.self) { try await tools.versions() }
        try FileManager.default.removeItem(at: bin.appendingPathComponent("deno"))
        #expect(throws: StudyDownloadError.self) { try StudyTools.discover(home: home, searchRoots: []) }
    }

    @Test func mediaValidatorChecksBothDecodeSamples() async throws {
        let root = try testDirectory()
        let media = root.appendingPathComponent("sample.mp4")
        try Data("fixture".utf8).write(to: media)
        let probe = root.appendingPathComponent("ffprobe")
        try Data("#!/bin/sh\nprintf '{\"format\":{\"duration\":\"60\"},\"streams\":[{\"codec_type\":\"video\"},{\"codec_type\":\"audio\"}]}'\n".utf8)
            .write(to: probe)
        let decode = root.appendingPathComponent("ffmpeg")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: decode)
        for url in [probe, decode] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let validator = FFprobeMediaValidator(ffprobeURL: probe, ffmpegURL: decode)
        #expect(try await validator.validate(mediaURL: media, expectedDuration: 60,
                                             transcriptURL: nil).isPlayable)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: decode)
        await #expect(throws: StudyDownloadError.self) {
            try await validator.validate(mediaURL: media, expectedDuration: 60,
                                         transcriptURL: nil)
        }
    }

    @Test func compatibilityRepairOnlyTranscodesWhenInspectionRequiresIt() async throws {
        let root = try testDirectory()
        let media = root.appendingPathComponent("lesson.mp4")
        try Data("original".utf8).write(to: media)
        let probe = root.appendingPathComponent("ffprobe")
        let decode = root.appendingPathComponent("ffmpeg")
        let probeScript = """
        #!/bin/sh
        for last; do :; done
        case "$last" in *.compatible.mp4) repaired=1 ;; *) repaired=0 ;; esac
        if [ -f "\(root.path)/incompatible" ] && [ "$repaired" -eq 0 ]; then
          printf '{"format":{"format_name":"matroska"},"streams":[{"codec_type":"video","codec_name":"vp9"},{"codec_type":"audio","codec_name":"opus"}]}'
        else
          printf '{"format":{"format_name":"mov,mp4"},"streams":[{"codec_type":"video","codec_name":"h264"},{"codec_type":"audio","codec_name":"aac"}]}'
        fi
        """
        try Data(probeScript.utf8).write(to: probe)
        try Data("#!/bin/sh\nfor last; do :; done\nprintf 'repaired' > \"$last\"\n".utf8).write(to: decode)
        for file in [probe, decode] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let repairer = MediaCompatibilityRepairer(ffprobeURL: probe, ffmpegURL: decode)
        #expect(try await repairer.prepare(media) == media)
        try Data().write(to: root.appendingPathComponent("incompatible"))
        let repaired = try await repairer.prepare(media)
        #expect(repaired != media)
        #expect(try String(contentsOf: repaired, encoding: .utf8) == "repaired")
        #expect(try String(contentsOf: media, encoding: .utf8) == "original")
    }

    @MainActor
    @Test func importedManifestDoesNotAuthorizeNewDownloadIDs() async throws {
        let root = try testDirectory()
        let model = ShieldViewModel(authorityReader: FixedAuthorityReader(status: .unavailable(.missing)),
                                    enforcementReader: FixedEnforcementReader(),
                                    studyLibraryRoot: root.appendingPathComponent("library"))
        let imported = StudyManifest(schemaVersion: 1, courseTitle: "Unreviewed course",
                                     videos: [StudyVideo(id: "abcdefghijk", title: "Other video",
                                                         expectedDuration: 60, transcriptRequested: false)])
        let file = root.appendingPathComponent("imported.json")
        try JSONEncoder().encode(imported).write(to: file)
        model.importStudyManifest(from: file)
        #expect(model.studyManifestTitle == "Unreviewed course")
        #expect(!model.canDownloadStudyCourse)
        for _ in 0..<400 { // a cold first build can take several seconds
            if !model.isRestoringStudy { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        model.approveStudyCourse()
        #expect(model.canDownloadStudyCourse)
    }

    @MainActor
    @Test func studyViewModelRunsFixtureProcessesAndRestoresValidatedMedia() async throws {
        let root = try testDirectory()
        try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
        let backend = try FixtureBackend(root: root)
        let now = Date()
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: now, commands: [.add(DomainRestriction(owner: .permanent,
                policyID: "safe-fixture", title: "Fixture", domains: ["fixture.example"]))]),
            now: now, calendar: .current)
        let bin = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let id = "abcdefghijk"
        let scripts = [
            "yt-dlp": "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo '2026.01.01'; exit 0; fi\nprintf 'fixture-media' > abcdefghijk.mp4\n",
            "deno": "#!/bin/sh\necho 'deno 2.5.0'\n",
            "ffmpeg": "#!/bin/sh\nif [ \"$1\" = \"-version\" ]; then echo 'ffmpeg version 8.0'; fi\nexit 0\n",
            "ffprobe": "#!/bin/sh\nif [ \"$1\" = \"-version\" ]; then echo 'ffprobe version 8.0'; exit 0; fi\nprintf '{\"format\":{\"duration\":\"60\",\"format_name\":\"mp4\"},\"streams\":[{\"codec_type\":\"video\",\"codec_name\":\"h264\"},{\"codec_type\":\"audio\",\"codec_name\":\"aac\"}]}'\n"
        ]
        for (name, script) in scripts {
            let url = bin.appendingPathComponent(name)
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let tools = StudyTools(ytdlp: bin.appendingPathComponent("yt-dlp"),
                               deno: bin.appendingPathComponent("deno"),
                               ffmpeg: bin.appendingPathComponent("ffmpeg"),
                               ffprobe: bin.appendingPathComponent("ffprobe"))
        let manifest = StudyManifest(schemaVersion: 1, courseTitle: "Fixture Course",
                                     videos: [StudyVideo(id: id, title: "One lesson",
                                                         expectedDuration: 60, transcriptRequested: false)])
        let manifestURL = root.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let library = root.appendingPathComponent("library")
        let model = ShieldViewModel(authorityReader: AuthorityStateReader(fileURL: backend.paths.authority),
                                    enforcementReader: HostsEnforcementReader(fileURL: backend.paths.hosts),
                                    studyLibraryRoot: library, fixtureBackend: backend, studyToolsOverride: tools)
        model.refresh(now: now)
        model.importStudyManifest(from: manifestURL)
        for _ in 0..<400 { // a cold first build can take several seconds
            if !model.isRestoringStudy { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(!model.canDownloadStudyCourse)
        model.approveStudyCourse()
        model.startDownloads()
        for _ in 0..<200 {
            if !model.isDownloading { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard let saved = model.mediaURL(for: id) else {
            Issue.record("Fixture download did not install media: \(model.studyMessage ?? "unknown error")")
            return
        }
        #expect(try String(contentsOf: saved, encoding: .utf8) == "fixture-media")
        let reopened = ShieldViewModel(authorityReader: AuthorityStateReader(fileURL: backend.paths.authority),
                                       enforcementReader: HostsEnforcementReader(fileURL: backend.paths.hosts),
                                       studyLibraryRoot: library, fixtureBackend: backend, studyToolsOverride: tools)
        reopened.refresh(now: now)
        reopened.importStudyManifest(from: manifestURL)
        for _ in 0..<400 {
            if !reopened.isRestoringStudy { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(reopened.studyJobs.contains { job in
            if case .complete = job.state { return true }
            return false
        })
    }

    @MainActor
    @Test func existingMediaImportCopiesApprovedIDWithoutChangingOriginal() async throws {
        let root = try testDirectory()
        let bin = root.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let scripts = [
            "yt-dlp": "#!/bin/sh\necho '2026.01.01'\n",
            "deno": "#!/bin/sh\necho 'deno 2.5.0'\n",
            "ffmpeg": "#!/bin/sh\nif [ \"$1\" = \"-version\" ]; then echo 'ffmpeg version 8.0'; fi\nexit 0\n",
            "ffprobe": "#!/bin/sh\nif [ \"$1\" = \"-version\" ]; then echo 'ffprobe version 8.0'; exit 0; fi\nprintf '{\"format\":{\"duration\":\"60\",\"format_name\":\"mp4\"},\"streams\":[{\"codec_type\":\"video\",\"codec_name\":\"h264\"},{\"codec_type\":\"audio\",\"codec_name\":\"aac\"}]}'\n"
        ]
        for (name, script) in scripts {
            let url = bin.appendingPathComponent(name)
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let tools = StudyTools(ytdlp: bin.appendingPathComponent("yt-dlp"),
            deno: bin.appendingPathComponent("deno"), ffmpeg: bin.appendingPathComponent("ffmpeg"),
            ffprobe: bin.appendingPathComponent("ffprobe"))
        let id = "abcdefghijk"
        let manifest = StudyManifest(schemaVersion: 1, courseTitle: "Imported course",
            videos: [StudyVideo(id: id, title: "Lesson", expectedDuration: 60,
                                transcriptRequested: false)])
        let manifestURL = root.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let originals = root.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let original = originals.appendingPathComponent("Lesson [\(id)].mp4")
        try Data("original-video".utf8).write(to: original)
        let model = ShieldViewModel(authorityReader: FixedAuthorityReader(status: .unavailable(.missing)),
            enforcementReader: FixedEnforcementReader(),
            studyLibraryRoot: root.appendingPathComponent("library"), studyToolsOverride: tools)
        model.importStudyManifest(from: manifestURL)
        for _ in 0..<400 { // a cold first build can take several seconds
            if !model.isRestoringStudy { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        await model.importExistingMedia(from: originals)
        #expect(try String(contentsOf: original, encoding: .utf8) == "original-video")
        let saved = try #require(model.mediaURL(for: id))
        #expect(try String(contentsOf: saved, encoding: .utf8) == "original-video")
        #expect(!model.canDownloadStudyCourse)
    }

    @MainActor
    @Test func nativeLocalImportValidatesRealMediaAndRestoresLibrary() async throws {
        let root = try testDirectory()
        let id = "abcdefghijk"
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/controlled-media.mp4")
        let originals = root.appendingPathComponent("selected-folder")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        let selected = originals.appendingPathComponent("Lesson [\(id)].mp4")
        try FileManager.default.copyItem(at: fixture, to: selected)
        let manifest = StudyManifest(schemaVersion: 1, courseTitle: "Native media course",
            videos: [StudyVideo(id: id, title: "Controlled lesson", expectedDuration: 2,
                                transcriptRequested: false)])
        let manifestURL = root.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let library = root.appendingPathComponent("library")
        let model = ShieldViewModel(studyLibraryRoot: library)
        model.importStudyManifest(from: manifestURL)
        for _ in 0..<200 where model.isRestoringStudy {
            try await Task.sleep(for: .milliseconds(30))
        }
        await model.importExistingMedia(from: originals)
        #expect(model.studyCompletedCount == 1)
        let saved = try #require(model.mediaURL(for: id))
        #expect(FileManager.default.fileExists(atPath: saved.path))
        #expect(try Data(contentsOf: selected) == Data(contentsOf: saved))

        let reopened = ShieldViewModel(studyLibraryRoot: library)
        reopened.openSavedCourse(manifest)
        for _ in 0..<200 where reopened.isRestoringStudy {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(reopened.studyCompletedCount == 1)
        #expect(!reopened.studyCourseApproved)
        let invalid = root.appendingPathComponent("invalid.mp4")
        try Data("not media".utf8).write(to: invalid)
        await #expect(throws: Error.self) {
            _ = try await NativeLocalMediaValidator().validate(mediaURL: invalid,
                expectedDuration: 2, transcriptURL: nil)
        }
    }

    @Test func localImportRequiresExactIDClaimAndRejectsSymlinkSource() throws {
        let root = try testDirectory()
        let id = "abcdefghijk"
        let files = ["Lesson [abcdefghijk].mp4", "abcdefghijk2.mp4",
                     "unrelated-abcdefghijk-extra.mp4", "abcdefghijk.mp4"]
            .map { root.appendingPathComponent($0) }
        #expect(StudyMediaImportMatcher.candidates(for: id, in: files).count == 2)
        #expect(StudyMediaImportMatcher.candidates(for: id, in: [files[1], files[2]]).isEmpty)
        let original = root.appendingPathComponent("original.mp4")
        try Data("original".utf8).write(to: original)
        let alias = root.appendingPathComponent("alias.mp4")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        #expect(throws: StudyDownloadError.self) {
            try StudyMediaImportStager.copyRegularFile(from: alias,
                to: root.appendingPathComponent("staged.mp4"))
        }
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
    }

    @MainActor
    @Test func savedCourseCanReopenWithoutNewManifestSelection() async throws {
        let root = try testDirectory()
        let library = root.appendingPathComponent("library")
        let manifest = StudyManifest(schemaVersion: 1, courseTitle: "Saved algebra",
            videos: [StudyVideo(id: "abcdefghijk", title: "Lesson", expectedDuration: 60,
                                transcriptRequested: false)])
        let file = root.appendingPathComponent("course.json")
        try JSONEncoder().encode(manifest).write(to: file)
        let first = ShieldViewModel(authorityReader: FixedAuthorityReader(status: .unavailable(.missing)),
            enforcementReader: FixedEnforcementReader(),
            studyLibraryRoot: library)
        first.importStudyManifest(from: file)
        #expect(first.studyManifestTitle == "Saved algebra")
        let reopened = ShieldViewModel(authorityReader: FixedAuthorityReader(status: .unavailable(.missing)),
            enforcementReader: FixedEnforcementReader(),
            studyLibraryRoot: library)
        reopened.loadSavedCourses()
        for _ in 0..<50 {
            if !reopened.savedCourses.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let saved = try #require(reopened.savedCourses.first)
        reopened.openSavedCourse(saved)
        #expect(reopened.studyManifestTitle == "Saved algebra")
        #expect(!reopened.studyCourseApproved)
        #expect(!reopened.canDownloadStudyCourse)
    }
}

private actor AttemptCounter {
    private(set) var attempts = 0
    let failuresBeforeSuccess: Int

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func attempt() throws {
        attempts += 1
        if attempts <= failuresBeforeSuccess {
            throw StudyDownloadError.processFailed("fixture", 1)
        }
    }
}

private struct FixtureFetcher: RestrictedVideoFetching {
    let counter: AttemptCounter

    func fetch(video: StudyVideo, stagingDirectory: URL) async throws -> URL {
        try await counter.attempt()
        return stagingDirectory.appendingPathComponent("\(video.id).mp4")
    }
}

private struct AlwaysSucceedsFetcher: RestrictedVideoFetching {
    func fetch(video: StudyVideo, stagingDirectory: URL) async throws -> URL {
        stagingDirectory.appendingPathComponent("\(video.id).mp4")
    }
}

private struct FixtureValidator: MediaValidating {
    func validate(
        mediaURL: URL,
        expectedDuration: TimeInterval?,
        transcriptURL: URL?
    ) async throws -> MediaValidation {
        MediaValidation(
            duration: expectedDuration ?? 60,
            hasVideo: true,
            hasAudio: true,
            fileSize: 1_024,
            transcriptPresent: transcriptURL != nil
        )
    }
}

private struct CorruptFixtureValidator: MediaValidating {
    func validate(
        mediaURL: URL,
        expectedDuration: TimeInterval?,
        transcriptURL: URL?
    ) async throws -> MediaValidation {
        throw StudyDownloadError.invalidMedia("corrupt fixture")
    }
}

private struct FixedAuthorityReader: AuthorityStateReading {
    let status: AuthorityStatus
    func read(now: Date) -> AuthorityStatus { status }
}

private struct FixedEnforcementReader: EnforcementStateReading {
    func read() -> Result<EnforcementSnapshot, Error> {
        .success(
            EnforcementSnapshot(
                observedAt: .now,
                blockedDomains: [],
                managedSectionPresent: false
            )
        )
    }
}

private func testDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("KairosPersistenceTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: url,
        withIntermediateDirectories: true
    )
    return url
}
