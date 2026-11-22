import Foundation
import Testing
@testable import Shield

/// Real yt-dlp error lines (Nov 15 audit): each must lead to the right fix.
struct DownloadFailureTextTests {
    private let cookiesHint = " Use --cookies-from-browser or --cookies for the authentication. "
        + "See https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp"

    @Test func privateMembersAndAgeErrorsAreNotRetriedEvenWithTheCookiesHint() {
        for signedIn in [false, true] {
            let privateVideo = StudyFailureText.describe(
                "ERROR: [youtube] abc: Private video. Sign in if you've been granted access to this video." + cookiesHint,
                signInFilePresent: signedIn)
            #expect(privateVideo.action == .remove)
            #expect(privateVideo.text.contains("private"))
            let members = StudyFailureText.describe(
                "ERROR: [youtube] abc: Join this channel to get access to members-only content like this video." + cookiesHint,
                signInFilePresent: signedIn)
            #expect(members.action == .remove)
        }
        let age = "ERROR: [youtube] abc: Sign in to confirm your age. This video may be inappropriate for some users." + cookiesHint
        #expect(StudyFailureText.describe(age, signInFilePresent: false).action == .signIn)
        #expect(StudyFailureText.describe(age, signInFilePresent: true).action == .remove)
    }

    @Test func botCheckStillAsksForSignInOrRetries() {
        let bot = "ERROR: [youtube] abc: Sign in to confirm you're not a bot." + cookiesHint
        #expect(StudyFailureText.describe(bot, signInFilePresent: false).action == .signIn)
        #expect(StudyFailureText.describe(bot, signInFilePresent: true).action == .retry)
    }

    @Test func temporaryRefusalsAreRetriedNotRemoved() {
        for raw in ["ERROR: [youtube] abc: Requested format is not available. Use --list-formats for a list of available formats",
                    "ERROR: [youtube] abc: This content isn't available, try again later."] {
            let failure = StudyFailureText.describe(raw, signInFilePresent: true)
            #expect(failure.action == .retry, "\(raw)")
        }
        #expect(StudyFailureText.describe("ERROR: [youtube] abc: Video unavailable. This video has been removed by the uploader",
                                          signInFilePresent: true).action == .remove)
    }

    @Test func diskFullTimeLimitAndMissingToolsSayWhatHappened() {
        let disk = StudyFailureText.describe("ERROR: unable to write data: [Errno 28] No space left on device",
                                             signInFilePresent: true)
        #expect(disk.text.contains("out of space"))
        let slow = StudyFailureText.describe("sandbox-exec exceeded its time limit.", signInFilePresent: true)
        #expect(slow.text.contains("too long"))
        #expect(slow.action == .retry)
        let tools = StudyFailureText.describe("Required tool is unavailable: yt-dlp", signInFilePresent: true)
        #expect(tools.text.contains("download tools"))
    }

    @Test func coordinatorRetriesOnlyWhatCanSucceed() {
        typealias C = StudyDownloadCoordinator
        #expect(C.isRetryable(StudyDownloadError.processFailed("yt-dlp", 1), attempt: 1))
        #expect(C.isRetryable(StudyDownloadError.timedOut("sandbox-exec"), attempt: 1))
        #expect(!C.isRetryable(StudyDownloadError.timedOut("sandbox-exec"), attempt: 2), "An hour-long stall gets one more try")
        #expect(C.isRetryable(StudyDownloadError.toolReported("yt-dlp", "HTTP Error 403: Forbidden"), attempt: 1))
        // Every way was already tried inside one round: a refusal gets one more round, not two.
        #expect(!C.isRetryable(StudyDownloadError.toolReported("yt-dlp", "unable to download video data: HTTP Error 403: Forbidden"),
                               attempt: 2))
        #expect(C.isRetryable(StudyDownloadError.toolReported("yt-dlp", "Read timed out."), attempt: 2),
                "Passing network trouble keeps every try")
        #expect(!C.isRetryable(StudyDownloadError.toolReported("yt-dlp", "ERROR: Private video." + cookiesHint), attempt: 1),
                "A private video never succeeds by retrying")
        #expect(!C.isRetryable(StudyDownloadError.cancelled, attempt: 1))
        #expect(!C.isRetryable(StudyDownloadError.invalidMedia("Not enough free space"), attempt: 1))
    }

    /// A download that prints nothing for five minutes is stopped, says so,
    /// and gets one more try (it used to sit for an hour, twice).
    @Test func aStuckDownloadIsStoppedSaysSoAndRetriesOnce() {
        let stuck = StudyDownloadError.stalled("sandbox-exec")
        #expect(StudyDownloadCoordinator.isRetryable(stuck, attempt: 1))
        #expect(!StudyDownloadCoordinator.isRetryable(stuck, attempt: 2))
        let text = StudyFailureText.describe(stuck.localizedDescription, signInFilePresent: false)
        #expect(text.text.contains("got stuck"))
        #expect(text.action == .retry)

        let clock = ActivityClock()
        let start = clock.last
        clock.note(errorLogSize: 0)
        #expect(clock.last == start, "An unchanged error log is not activity")
        clock.note(errorLogSize: 120)
        #expect(clock.last >= start, "A growing error log is activity")
    }

    @Test func partialFilesAreRemovedAndFinishedOnesKept() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("partials-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["a.mp4.part", "a.ytdl", "a.mp4.part-Frag3", "done.mp4", "done.info.json"] {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        YTDLPRestrictedFetcher.removePartialDownloads(in: folder)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(left == ["done.mp4", "done.info.json"])
    }

    @Test func crashLeftoversAreRemovedButNotCopiesInProgressOrVideos() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Leftovers-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent(".abcdefghijk.\(UUID().uuidString).validated")
        let fresh = root.appendingPathComponent(".abcdefghijk.\(UUID().uuidString).validated")
        let video = root.appendingPathComponent("abcdefghijk.mp4")
        let lookalike = root.appendingPathComponent(".notes.validated")
        for file in [old, fresh, video, lookalike] { try Data("x".utf8).write(to: file) }
        let hourAgo = Date().addingTimeInterval(-7_200)
        for file in [old, video, lookalike] {
            try FileManager.default.setAttributes([.modificationDate: hourAgo], ofItemAtPath: file.path)
        }

        #expect(ValidatedMediaInstaller.removeLeftovers(in: root) == 1)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path), "A copy being written now must stay")
        #expect(FileManager.default.fileExists(atPath: video.path))
        #expect(FileManager.default.fileExists(atPath: lookalike.path))
    }

    /// The Nov 17 failure: YouTube refused the file every way Shield tried.
    @Test func aRefusedVideoSaysYouTubeRefusedIt() {
        for raw in ["unable to download video data: HTTP Error 403: Forbidden", "ERROR: HTTP Error 403: Forbidden"] {
            for signedIn in [false, true] {
                let text = StudyFailureText.describe(raw, signInFilePresent: signedIn)
                #expect(text.text == "YouTube refused this video just now. Try again later.")
                #expect(text.action == .retry)
            }
        }
    }
}
