import AVFoundation
import Foundation
import Testing
@testable import Shield

/// Shield's own player controls, driven against a real saved
/// video: play/pause, skipping, the timeline, speed and volume that carry over,
/// playing to the end, looping, and Next playing in the same player.
@MainActor
@Suite(.serialized)
struct PlayerControlsTests {
    private static let keys = [PlayerPrefs.speedKey, PlayerPrefs.volumeKey, PlayerPrefs.mutedKey]

    /// A library with two saved copies of the 2-second test video.
    private func library() async throws -> (ShieldViewModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldPlayerControls-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let originals = root.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: false)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/controlled-media.mp4")
        for id in ["aaaaaaaaaaa", "bbbbbbbbbbb"] {
            try FileManager.default.copyItem(at: fixture, to: originals.appendingPathComponent("\(id).mp4"))
        }
        let manifest = StudyManifest(schemaVersion: 1, courseTitle: "Player controls", videos: [
            StudyVideo(id: "aaaaaaaaaaa", title: "First", expectedDuration: 2, transcriptRequested: false),
            StudyVideo(id: "bbbbbbbbbbb", title: "Second", expectedDuration: 2, transcriptRequested: false),
        ])
        let manifestURL = root.appendingPathComponent("course.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        let model = ShieldViewModel(studyLibraryRoot: root.appendingPathComponent("library"))
        model.importStudyManifest(from: manifestURL)
        for _ in 0..<200 where model.isRestoringStudy { try await Task.sleep(for: .milliseconds(25)) }
        await model.importExistingMedia(from: originals)
        #expect(model.studyCompletedCount == 2)
        return (model, root)
    }

    private func keepingPrefs(_ body: () async throws -> Void) async rethrows {
        let saved = Self.keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(Self.keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        try await body()
    }

    private func waitUntil(_ seconds: Double = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
    }

    @Test func speedsStepAndTimesRead() {
        #expect(PlayerPrefs.speed(after: 1, faster: true) == 1.25)
        #expect(PlayerPrefs.speed(after: 1, faster: false) == 0.75)
        #expect(PlayerPrefs.speed(after: 3, faster: true) == 3)
        #expect(PlayerPrefs.speed(after: 0.5, faster: false) == 0.5)
        #expect(PlayerPrefs.speedName(1) == "1×")
        #expect(PlayerPrefs.speedName(1.5) == "1.5×")
        #expect(PlayerPrefs.speedName(1.25) == "1.25×")
        #expect(PlayerPrefs.clock(65) == "1:05")
        #expect(PlayerPrefs.clock(3723) == "1:02:03")
        #expect(PlayerPrefs.clock(.nan) == "0:00")
    }

    @Test func controlsDriveTheRealPlayer() async throws {
        try await keepingPrefs {
            let (model, root) = try await library()
            defer { try? FileManager.default.removeItem(at: root) }
            let selection = try #require(model.playbackSelection(for: "aaaaaaaaaaa"))
            let session = StudyPlayerSession(selection: selection)
            await session.prepare()
            #expect(session.playbackError == nil)
            #expect(session.canControl)
            #expect(session.mediaURL != nil, "The timeline preview needs the file")

            // Play and pause.
            try await waitUntil { session.isPlaying }
            #expect(session.isPlaying, "A video opened without its transcript starts playing")
            session.togglePlay()
            try await waitUntil { !session.isPlaying }
            #expect(!session.isPlaying)

            // Skipping and seeking stay inside the video.
            session.seek(to: 1)
            try await waitUntil { abs(CMTimeGetSeconds(session.player.currentTime()) - 1) < 0.1 }
            #expect(abs(CMTimeGetSeconds(session.player.currentTime()) - 1) < 0.1)
            session.skip(-10)
            try await waitUntil { CMTimeGetSeconds(session.player.currentTime()) < 0.05 }
            #expect(CMTimeGetSeconds(session.player.currentTime()) < 0.05)
            session.skip(10)
            try await waitUntil { CMTimeGetSeconds(session.player.currentTime()) > session.duration - 0.2 }
            #expect(CMTimeGetSeconds(session.player.currentTime()) <= session.duration)

            // Dragging the timeline pauses, then plays on from where it was let go.
            session.seek(to: 0)
            session.play()
            try await waitUntil { session.isPlaying }
            session.beginScrubbing()
            try await waitUntil { !session.isPlaying }
            #expect(!session.isPlaying)
            session.scrub(to: 0.8)
            #expect(abs(session.time - 0.8) < 0.01)
            session.endScrubbing(at: 0.5)
            try await waitUntil { session.isPlaying }
            #expect(session.isPlaying, "Playback resumes after a drag that started while playing")
            session.pause()

            // Speed: used at once, kept for the next video, and pitch-corrected.
            session.setSpeed(1.5)
            #expect(session.player.defaultRate == 1.5)
            #expect(PlayerPrefs.savedSpeed == 1.5)
            #expect(session.player.currentItem?.audioTimePitchAlgorithm == .timeDomain)
            session.setSpeed(1.1) // not offered: ignored
            #expect(session.speed == 1.5)

            // Volume and mute carry over too.
            session.setVolume(0.4)
            #expect(abs(session.player.volume - 0.4) < 0.001)
            session.toggleMute()
            #expect(session.player.isMuted && session.muted)
            session.setVolume(0.6) // moving the slider unmutes
            #expect(!session.player.isMuted && !session.muted)
            #expect(abs(PlayerPrefs.savedVolume - 0.6) < 0.001)
            session.setVolume(3)
            #expect(session.volume == 1)

            let second = StudyPlayerSession(selection: selection)
            #expect(second.speed == 1.5 && second.player.defaultRate == 1.5)
            #expect(second.volume == 1 && !second.muted)
            session.close()
        }
    }

    /// Held down (mouse or space bar): 2× while held, then back to the chosen
    /// speed, which is never changed or saved.
    @Test func holdingPlaysAtDoubleSpeedUntilLetGo() async throws {
        try await keepingPrefs {
            UserDefaults.standard.set(Float(1.25), forKey: PlayerPrefs.speedKey)
            let (model, root) = try await library()
            defer { try? FileManager.default.removeItem(at: root) }
            let session = StudyPlayerSession(selection: try #require(model.playbackSelection(for: "aaaaaaaaaaa")))
            await session.prepare()
            try await waitUntil { session.isPlaying }

            // Playing: 2× while held, the chosen speed again after.
            session.beginBoost()
            #expect(session.boosted)
            #expect(session.player.rate == 2)
            #expect(session.speed == 1.25 && PlayerPrefs.savedSpeed == 1.25, "Holding never changes the chosen speed")
            session.beginBoost() // a second press while held does nothing
            session.endBoost()
            #expect(!session.boosted)
            #expect(session.player.rate == 1.25)
            #expect(session.isPlaying, "Letting go keeps a playing video playing")

            // Paused: plays while held, pauses again when let go.
            session.pause()
            session.seek(to: 0)
            try await waitUntil { !session.isPlaying }
            session.beginBoost()
            try await waitUntil { session.isPlaying }
            #expect(session.isPlaying && session.player.rate == 2)
            session.endBoost()
            try await waitUntil { !session.isPlaying }
            #expect(!session.isPlaying, "A video that was paused is paused again")
            #expect(session.player.defaultRate == 1.25)

            // Changing speed while held takes effect when let go.
            session.play()
            session.beginBoost()
            session.setSpeed(1.5)
            #expect(session.player.rate == 2)
            session.endBoost()
            #expect(session.player.rate == 1.5)

            // Closing or switching never leaves the next video at 2×.
            session.beginBoost()
            await session.switchTo(try #require(model.playbackSelection(for: "bbbbbbbbbbb")))
            #expect(!session.boosted)
            try await waitUntil { session.isPlaying }
            #expect(session.player.rate == 1.5)
            session.close()
        }
    }

    @Test func timedTranscriptAndCaptionsComeWithTheVideo() async throws {
        let (model, root) = try await library()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(model.playbackSelection(for: "aaaaaaaaaaa"))
        let folder = first.store.root
        try Data("Hello everyone welcome to the course\n".utf8)
            .write(to: folder.appendingPathComponent("aaaaaaaaaaa.txt"))
        let cues = [TranscriptCue(start: 0, end: 1, text: "hello everyone"),
                    TranscriptCue(start: 1, end: 2, text: "welcome to the course")]
        try #require(TranscriptCue.encode(cues)).write(to: folder.appendingPathComponent("aaaaaaaaaaa.cues.json"))
        // The second video has a transcript saved before timing was kept.
        try Data("Plain text only\n".utf8).write(to: folder.appendingPathComponent("bbbbbbbbbbb.txt"))

        let session = StudyPlayerSession(selection: first)
        await session.prepare()
        #expect(session.transcript != nil)
        #expect(session.cues == cues)
        session.seek(to: 1.4)
        try await waitUntil { abs(session.time - 1.4) < 0.1 }
        #expect(TranscriptCue.index(at: session.time, in: session.cues) == 1, "The line being said follows the video")

        // Next: the second video's plain transcript, and no captions offered.
        await session.switchTo(try #require(model.playbackSelection(for: "bbbbbbbbbbb")))
        #expect(session.transcript == "Plain text only\n")
        #expect(session.cues.isEmpty)
        session.close()
    }

    @Test func endingLoopingAndNextInTheSamePlayer() async throws {
        try await keepingPrefs {
            UserDefaults.standard.set(Float(2), forKey: PlayerPrefs.speedKey)
            let (model, root) = try await library()
            defer { try? FileManager.default.removeItem(at: root) }
            #expect(model.nextSavedVideo(after: "aaaaaaaaaaa") == "bbbbbbbbbbb")
            #expect(model.nextSavedVideo(after: "bbbbbbbbbbb") == nil)
            let first = try #require(model.playbackSelection(for: "aaaaaaaaaaa"))
            let session = StudyPlayerSession(selection: first)
            await session.prepare()

            // Played through to the end: offers what's next; Play starts over.
            session.seek(to: session.duration - 0.3)
            session.play()
            try await waitUntil(6) { session.reachedEnd }
            #expect(session.reachedEnd)
            #expect(!session.isPlaying)
            session.play()
            try await waitUntil { !session.reachedEnd && session.isPlaying }
            #expect(!session.reachedEnd)
            #expect(CMTimeGetSeconds(session.player.currentTime()) < 1)
            session.pause()

            // Looping starts the video again instead of stopping.
            session.loops = true
            session.seek(to: session.duration - 0.3)
            session.play()
            try await Task.sleep(for: .seconds(1.2))
            #expect(!session.reachedEnd, "A looping video never stops at its end")
            #expect(session.isPlaying)
            session.loops = false
            session.pause()

            // Next: the same player switches to the second video and saves the first's place.
            session.seek(to: 0.7)
            try await waitUntil { abs(CMTimeGetSeconds(session.player.currentTime()) - 0.7) < 0.1 }
            let next = try #require(model.playbackSelection(for: "bbbbbbbbbbb"))
            await session.switchTo(next)
            #expect(session.selection.id == "bbbbbbbbbbb")
            #expect(session.playbackError == nil)
            #expect(session.player.currentItem != nil)
            try await waitUntil { session.isPlaying }
            #expect(session.isPlaying, "Next plays at once")
            #expect(session.player.rate == 2, "The chosen speed carries over to the next video")
            let saved = try first.store.load(videoID: "aaaaaaaaaaa")
            #expect(abs((saved?.seconds ?? 0) - 0.7) < 0.15, "Leaving a video keeps its place")
            session.close()
        }
    }
}
