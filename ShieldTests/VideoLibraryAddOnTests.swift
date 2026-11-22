import Foundation
import Testing
@testable import Shield

/// The Video Library add-on: off for someone new, kept for
/// anyone who already has videos, and the user's choice always wins.
struct VideoLibraryAddOnTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldAddOn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func defaults() -> UserDefaults {
        let name = "ShieldAddOnTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aNewLibraryHasNothingToKeep() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!ShieldViewModel.hasVideoLibraryData(at: root))
        #expect(!ShieldViewModel.hasVideoLibraryData(at: root.appendingPathComponent("missing")))
    }

    @Test func savedVideosOrCollectionsKeepItOn() throws {
        for name in ["download-queue.json", "collections.json", ".link-queue-v1"] {
            let root = try folder()
            defer { try? FileManager.default.removeItem(at: root) }
            try Data("{}".utf8).write(to: root.appendingPathComponent(name))
            #expect(ShieldViewModel.hasVideoLibraryData(at: root), "\(name) means it's in use")
        }
    }

    @Test func theOwnersChoiceWins() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{}".utf8).write(to: root.appendingPathComponent("download-queue.json"))
        let store = defaults()
        store.set(false, forKey: ShieldViewModel.videoLibraryKey)
        #expect(!ShieldViewModel.videoLibraryInitiallyEnabled(libraryRoot: root, defaults: store),
                "Removed stays removed, even with videos on disk")
        store.set(true, forKey: ShieldViewModel.videoLibraryKey)
        #expect(ShieldViewModel.videoLibraryInitiallyEnabled(libraryRoot: try folder(), defaults: store))
    }

    @Test func toolsAreLookedForWhereDownloadsLook() throws {
        let home = try folder()
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let ytdlp = bin.appendingPathComponent("yt-dlp")
        try Data("#!/bin/sh\n".utf8).write(to: ytdlp)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ytdlp.path)
        let tools = VideoLibraryAddOn.tools(home: home)
        #expect(tools.map(\.name) == ["yt-dlp", "deno", "ffmpeg", "ffprobe"])
        #expect(tools.first { $0.name == "yt-dlp" }?.found == true)
    }
}
