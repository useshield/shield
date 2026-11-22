import Foundation
import Testing
@testable import Shield

struct OverpassLogicTests {
    @Test func downloadFailuresReadInPlainLanguage() {
        let bot = "yt-dlp: [youtube] gTwBMP7K-bU: Sign in to confirm you're not a bot. Use --cookies-from-browser"
        #expect(StudyFailureText.describe(bot, signInFilePresent: false).action == .signIn)
        #expect(StudyFailureText.describe(bot, signInFilePresent: true) ==
                .init(text: "YouTube paused this download. Try again later.", action: .retry))
        #expect(StudyFailureText.describe("ERROR: Private video. Sign in if you've been granted access",
                                          signInFilePresent: true).action == .remove)
        #expect(StudyFailureText.describe("ERROR: Video unavailable", signInFilePresent: true).action == .remove)
        #expect(StudyFailureText.describe("The request timed out.", signInFilePresent: true).action == .retry)
        #expect(StudyFailureText.describe("Current protection blocks YouTube.", signInFilePresent: true).action == .none)
        let other = StudyFailureText.describe("exit 1: something odd", signInFilePresent: true)
        #expect(other.text == "Couldn't download this video." && other.action == .retry)
        #expect(!other.text.contains("exit"), "Raw tool text never reaches the row.")
    }

    @Test func scheduleTimesAreShort() {
        let afternoon = AllowedAccessWindow(startMinutes: 14 * 60, endMinutes: 20 * 60)!
        #expect(ScheduleText.short(afternoon) == "2–8 PM")
        let crossing = AllowedAccessWindow(startMinutes: 10 * 60, endMinutes: 14 * 60 + 30)!
        #expect(ScheduleText.short(crossing) == "10 AM–2:30 PM")
        let overnight = AllowedAccessWindow(startMinutes: 22 * 60, endMinutes: 6 * 60)!
        #expect(ScheduleText.short(overnight) == "10 PM–6 AM · overnight")
        // Noon to midnight is the same day (Nov 13: the imported list showed "· overnight").
        let untilMidnight = AllowedAccessWindow(startMinutes: 12 * 60, endMinutes: 0)!
        #expect(ScheduleText.short(untilMidnight) == "12 PM–12 AM")
        #expect(ScheduleText.time(0) == "12 AM")
        #expect(ScheduleText.time(12 * 60) == "12 PM")
    }

    @Test func allowedNowHandlesMidnight() {
        let afternoon = AllowedAccessWindow(startMinutes: 14 * 60, endMinutes: 20 * 60)!
        #expect(afternoon.contains(14 * 60))
        #expect(!afternoon.contains(20 * 60), "The end minute is already blocked.")
        let overnight = AllowedAccessWindow(startMinutes: 22 * 60, endMinutes: 6 * 60)!
        #expect(overnight.contains(23 * 60) && overnight.contains(60) && !overnight.contains(12 * 60))
        #expect(afternoon.minutes(from: 21 * 60, to: afternoon.startMinutes) == 17 * 60)
    }
}

@MainActor
struct LibraryNoticeTests {
    @Test func addNoticeCountsDuplicatesAndBadLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryNotice-\(UUID())")
        let authority = root.appendingPathComponent("authority")
        try FileManager.default.createDirectory(at: authority, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let backend = try FixtureBackend(root: authority)
        try backend.initializeEmptyAuthority(now: .now, calendar: .current)
        let model = ShieldViewModel(studyLibraryRoot: root.appendingPathComponent("library"), fixtureBackend: backend)
        defer { model.stop() }
        #expect(model.addVideoLinks("https://youtu.be/abcdefghijk"))
        #expect(model.queueNotice == "Added 1")
        // The first add opened the library; wait for its check to finish.
        for _ in 0..<200 where model.isRestoringStudy { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.addVideoLinks("https://youtu.be/abcdefghijk https://example.com/x https://youtu.be/bcdefghijkl"))
        #expect(model.queueNotice == "Added 1 · 1 already in your library · 1 not a YouTube link")
        // The open library gains the row at once, without re-checking saved files.
        #expect(!model.isRestoringStudy)
        #expect(model.libraryJobs(in: nil).map(\.id) == ["abcdefghijk", "bcdefghijkl"])
        model.deleteVideo("abcdefghijk")
        #expect(!model.isRestoringStudy)
        #expect(model.libraryJobs(in: nil).map(\.id) == ["bcdefghijkl"])
    }
}
