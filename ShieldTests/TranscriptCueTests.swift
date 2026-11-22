import Foundation
import Testing
@testable import Shield

/// The transcript's timed lines: read from YouTube's rolling
/// captions, saved next to the transcript, checked when read back, and used to
/// find the line being said.
struct TranscriptCueTests {
    /// YouTube's rolling auto-captions: the first cue opens with a line that is
    /// just a space (written as \u{20} so editors keep it), each line repeats in the next cue, and 10 ms cues sit in between.
    static let rolling = """
    WEBVTT
    Kind: captions
    Language: en

    00:00:00.160 --> 00:00:02.869 align:start position:0%
    \u{20}
    hello<00:00:00.480><c> everyone</c><00:00:00.880><c> welcome</c>

    00:00:02.869 --> 00:00:02.879 align:start position:0%
    hello everyone welcome
    \u{20}

    00:00:02.879 --> 00:00:05.110 align:start position:0%
    hello everyone welcome
    to<00:00:03.120><c> the</c><00:00:03.360><c> course</c>

    00:00:05.110 --> 00:00:05.120 align:start position:0%
    to the course
    \u{20}

    00:00:09.000 --> 00:00:11.500 align:start position:0%
    to the course
    after<00:00:09.400><c> a</c><00:00:09.600><c> pause</c>

    """

    @Test func rollingCaptionsBecomeOneLineEachAtTheRightTime() throws {
        let cues = TranscriptFormatter().cues(vtt: Self.rolling)
        #expect(cues.map(\.text) == ["hello everyone welcome", "to the course", "after a pause"])
        #expect(abs(cues[0].start - 0.16) < 0.001, "The first line starts when it's said, not a cue late")
        #expect(abs(cues[0].end - 2.869) < 0.001, "A line lasts until its own cue ends…")
        #expect(abs(cues[1].start - 2.879) < 0.001)
        #expect(abs(cues[1].end - 5.11) < 0.001, "…and lasts no longer in a pause")
        #expect(cues.indices.dropLast().allSatisfy { cues[$0].end <= cues[$0 + 1].start },
                "…or until the next line starts")
        #expect(abs(cues[2].start - 9) < 0.001 && abs(cues[2].end - 11.5) < 0.001)
        // The readable transcript keeps the first line too.
        let text = TranscriptFormatter().document(title: nil, vtt: Self.rolling)
        #expect(text == "Hello everyone welcome to the course after a pause\n")
    }

    @Test func windowsLineEndingsReadTheSame() {
        let crlf = Self.rolling.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(TranscriptFormatter().cues(vtt: crlf) == TranscriptFormatter().cues(vtt: Self.rolling))
    }

    @Test func findsTheLineBeingSaid() {
        let cues = TranscriptFormatter().cues(vtt: Self.rolling)
        #expect(TranscriptCue.index(at: 0, in: cues) == nil, "Nothing before the first line")
        #expect(TranscriptCue.index(at: 1, in: cues) == 0)
        #expect(TranscriptCue.index(at: 2.879, in: cues) == 1)
        #expect(TranscriptCue.index(at: 7, in: cues) == nil, "No caption in a pause")
        #expect(TranscriptCue.lastStarted(at: 7, in: cues) == 1, "The transcript keeps its place in a pause")
        #expect(TranscriptCue.index(at: 10, in: cues) == 2)
        #expect(TranscriptCue.index(at: 12, in: cues) == nil)
        #expect(TranscriptCue.lastStarted(at: 0, in: cues) == nil)
        #expect(TranscriptCue.index(at: 1, in: []) == nil)
    }

    @Test func savedTimingIsCheckedWhenRead() throws {
        let cues = TranscriptFormatter().cues(vtt: Self.rolling)
        let data = try #require(TranscriptCue.encode(cues))
        #expect(try TranscriptCue.decode(data) == cues)
        #expect(TranscriptCue.encode([]) == nil)

        func file(_ body: String) -> Data { Data(#"{"version":1,"cues":[\#(body)]}"#.utf8) }
        let bad = [
            file(#"{"start":2,"end":1,"text":"ends before it starts"}"#),
            file(#"{"start":-1,"end":1,"text":"negative"}"#),
            file(#"{"start":5,"end":6,"text":"b"},{"start":1,"end":2,"text":"out of order"}"#),
            file(#"{"start":0,"end":1,"text":"\#(String(repeating: "x", count: 501))"}"#),
            Data(#"{"version":2,"cues":[]}"#.utf8),
            Data("not json".utf8),
        ]
        for data in bad {
            #expect(throws: StudyDownloadError.self) { try TranscriptCue.decode(data) }
        }
    }

    @Test func installedNextToTheTranscriptAndReadBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldCues-\(UUID())")
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "abcdefghijk"
        let staged = root.appendingPathComponent("\(id).cues.json")
        let cues = TranscriptFormatter().cues(vtt: Self.rolling)
        try #require(TranscriptCue.encode(cues)).write(to: staged)

        let installer = ValidatedMediaInstaller(libraryRoot: library)
        try installer.installCues(from: staged, videoID: id)
        #expect(try StudyPlaybackStore(root: library).cues(videoID: id) == cues)
        #expect(try StudyPlaybackStore(root: library).cues(videoID: "bbbbbbbbbbb") == nil, "Older videos have none")

        // A file with the wrong name or broken timing is never kept.
        let wrong = root.appendingPathComponent("other.cues.json")
        try Data().write(to: wrong)
        #expect(throws: StudyDownloadError.self) { try installer.installCues(from: wrong, videoID: id) }
        let broken = root.appendingPathComponent("zzzzzzzzzzz.cues.json")
        try Data(#"{"version":1,"cues":[{"start":3,"end":1,"text":"x"}]}"#.utf8).write(to: broken)
        #expect(throws: StudyDownloadError.self) { try installer.installCues(from: broken, videoID: "zzzzzzzzzzz") }
        #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent("zzzzzzzzzzz.cues.json").path))
    }
}
