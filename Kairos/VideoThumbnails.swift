import AVFoundation
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// A still from each saved video, taken from the file on this Mac (no network).
// Kept in memory and in the app's Caches folder; the library is never written.
// Everything that touches the disk or decodes an image runs off the main
// thread, so scrolling a long list never waits on it.

@MainActor @Observable
final class VideoThumbnailCache {
    static let shared = VideoThumbnailCache()
    /// Recent stills only (about 120 MB at most); older ones reload from disk.
    @ObservationIgnored private let memory: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 120_000_000
        return cache
    }()
    @ObservationIgnored private var running: [String: Task<CGImage?, Never>] = [:]
    /// Bumped when a video's file goes away or is replaced, so an older load
    /// can't put its still back and pictures already on screen reload.
    private var generation: [String: Int] = [:]

    /// Changes whenever this video's still must be taken again.
    func revision(_ videoID: String) -> Int { generation[videoID, default: 0] }

    /// A video's file was just saved again: drop the in-memory still so
    /// pictures on screen reload. The disk copy is named after the file's
    /// size and date, so a new file never reuses it.
    func refresh(_ videoID: String) {
        memory.removeObject(forKey: videoID as NSString)
        running[videoID] = nil
        generation[videoID, default: 0] += 1
    }

    /// Instant: what's already in memory for this video.
    func cached(_ videoID: String) -> CGImage? { memory.object(forKey: videoID as NSString) }

    func image(_ videoID: String, store: StudyPlaybackStore) async -> CGImage? {
        if let hit = cached(videoID) { return hit }
        if let task = running[videoID] { return await task.value }
        let started = generation[videoID, default: 0]
        let task = Task.detached(priority: .utility) { await Self.load(videoID, store: store) }
        running[videoID] = task
        let image = await task.value
        guard generation[videoID, default: 0] == started else { return nil }
        running[videoID] = nil
        if let image { memory.setObject(image, forKey: videoID as NSString, cost: image.bytesPerRow * image.height) }
        return image
    }

    /// Drops a deleted or replaced video's still from memory and disk.
    func forget(_ videoID: String) {
        refresh(videoID)
        guard let folder = Self.folder,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(videoID + "-") && name.hasSuffix(".jpg") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    nonisolated private static var folder: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ShieldThumbnails", isDirectory: true)
    }

    /// The disk copy's name changes when the saved file changes.
    nonisolated private static func key(_ media: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: media.path),
              let size = attributes[.size] as? Int,
              let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 else { return nil }
        return "\(media.deletingPathExtension().lastPathComponent)-\(size)-\(Int(modified))"
    }

    nonisolated private static func load(_ videoID: String, store: StudyPlaybackStore) async -> CGImage? {
        guard let media = try? store.mediaURL(videoID: videoID), let key = key(media) else { return nil }
        let disk = folder?.appendingPathComponent(key + ".jpg")
        if let disk, let source = CGImageSourceCreateWithURL(disk as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            return image
        }
        guard let image = await render(media) else { return nil }
        if let disk, let folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let destination = CGImageDestinationCreateWithURL(disk as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
                CGImageDestinationFinalize(destination)
            }
        }
        return image
    }

    /// A frame a little way in, past any title card.
    nonisolated private static func render(_ media: URL) async -> CGImage? {
        let asset = AVURLAsset(url: media)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let at = duration.isFinite && duration > 0 ? min(max(duration * 0.12, 1), 45) : 1
        return try? await generator.image(at: CMTime(seconds: at, preferredTimescale: 600)).image
    }
}

/// A 16:9 picture for a video: its own still once saved, otherwise a soft
/// coloured tile with a symbol.
struct VideoThumbnail: View {
    let videoID: String?
    let store: StudyPlaybackStore?
    var tint: Color = .shieldAccent
    var symbol = "play.fill"
    var cornerRadius: CGFloat = 12
    @State private var image: CGImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(tint.opacity(0.18))
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image = image ?? videoID.flatMap(VideoThumbnailCache.shared.cached) {
                    Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(tint.opacity(0.8))
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.06)))
            .task(id: ThumbnailKey(videoID: videoID,
                                   revision: videoID.map(VideoThumbnailCache.shared.revision) ?? 0)) {
                // Never keep showing another video's still, or an old one of this video.
                image = nil
                guard let videoID, let store, VideoThumbnailCache.shared.cached(videoID) == nil else { return }
                image = await VideoThumbnailCache.shared.image(videoID, store: store)
            }
            .accessibilityHidden(true)
    }
}

private struct ThumbnailKey: Equatable {
    let videoID: String?
    let revision: Int
}

/// Tracks the pointer for one row or card only, so moving across a list
/// (or scrolling under the pointer) redraws that row, not the whole list.
struct HoverTracking<Content: View>: View {
    var selected = false
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering || selected)
            .onHover { hovering = $0 }
    }
}
