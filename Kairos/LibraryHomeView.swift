import AppKit
import SwiftUI

// The Library's front page: what you were watching, your collections, and
// what's still waiting to download. Every video is one click away under
// All Videos; nothing here changes the library itself.

struct LibraryHomeView: View {
    @Bindable var model: ShieldViewModel
    let title: (StudyJob) -> String
    let onPlay: (String) -> Void
    let onShowAll: () -> Void
    let onDownload: () -> Void
    let downloadBlockedReason: String?
    // Reordering: the tile follows the pointer itself, so no
    // system drag picture is left floating or sliding back after a click.
    @State private var dragging: String?
    @State private var dragPoint: CGPoint = .zero
    @State private var grab: CGSize = .zero
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var suppressTap = false
    private static let gridSpace = "collectionTiles"

    private var jobs: [StudyJob] { model.libraryJobs(in: nil) }
    /// One row, always: the three most recent; the rest are in All Videos.
    static let continueLimit = 3

    /// Saved videos started but not finished, most recent first.
    private var continuing: [(job: StudyJob, position: StudyPlaybackPosition)] {
        jobs.compactMap { job in
            guard job.isSaved, let position = model.playbackPositions[job.id],
                  !position.finished, position.seconds >= 5 else { return nil }
            return (job, position)
        }
        .sorted { $0.position.updatedAt > $1.position.updatedAt }
        .prefix(Self.continueLimit).map { $0 }
    }

    private var waiting: Int { jobs.count { !$0.isSaved && !$0.isFailed } }
    /// Failures another try could fix; the rest (private, removed) show in All Videos.
    private var failed: Int { jobs.count { $0.isFailed && model.isDownloadable($0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if !continuing.isEmpty {
                    BubbleSection(title: "Continue Watching", spacing: 12) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .top),
                                                 count: Self.continueLimit),
                                  alignment: .leading, spacing: 18) {
                            ForEach(continuing, id: \.job.id) { item in continueCard(item.job, item.position) }
                        }
                    }
                }
                BubbleSection(title: "Collections", spacing: 12) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 12)],
                              alignment: .leading, spacing: 12) {
                        tile(name: "All Videos", symbol: "play.rectangle.on.rectangle.fill", tint: .shieldAccent,
                             videos: jobs, identifier: "showAllVideos", action: onShowAll)
                        ForEach(model.collectionLayout.collections) { collection in
                            tile(name: collection.name, symbol: collection.symbol, tint: collection.color.color,
                                 videos: model.libraryJobs(in: collection.id),
                                 identifier: "homeCollection-\(collection.id)") {
                                if !suppressTap { model.selectedCollectionID = collection.id }
                            }
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.gridSpace)) } action: {
                                tileFrames[collection.id] = $0
                            }
                            // Drag a tile onto another to reorder; the sidebar follows.
                            // While it's lifted, its place shows as a faint slot.
                            .opacity(dragging == collection.id ? 0.15 : 1)
                            .simultaneousGesture(reorderGesture(collection.id))
                        }
                        Button { model.collectionEditor = .new } label: {
                            Label("New Collection", systemImage: "plus")
                                .frame(maxWidth: .infinity, minHeight: ShieldMetrics.headerIcon + 28)
                                .foregroundStyle(.secondary)
                                .background {
                                    RoundedRectangle(cornerRadius: ShieldBubble.radius, style: .continuous)
                                        .strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                                }
                                .contentShape(RoundedRectangle(cornerRadius: ShieldBubble.radius, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(!model.canAddCollection)
                        .accessibilityIdentifier("homeNewCollection")
                    }
                    .coordinateSpace(.named(Self.gridSpace))
                    .overlay(alignment: .topLeading) { liftedTile }
                }
                if model.studyExecutionAvailable && (waiting > 0 || failed > 0) { downloadsStrip }
            }
            // Same gutters as the other pages (ShieldBubblePage), wider for the cards.
            .padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 36)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity)
            .buttonStyle(ShieldPillButtonStyle())
        }
        .background(Color.shieldPage)
        .onDisappear { dragging = nil; suppressTap = false }
        .animation(.snappy(duration: 0.22), value: model.collectionLayout.collections.map(\.id))
        .buttonBorderShape(.capsule)
        .modifier(HardTopEdge())
        .accessibilityIdentifier("libraryHome")
    }

    private func continueCard(_ job: StudyJob, _ position: StudyPlaybackPosition) -> some View {
        let home = model.collectionLayout.collections(containing: job.id).first
        let tint = home?.color.color ?? .shieldAccent
        let fraction = position.duration > 0 ? min(1, position.seconds / position.duration) : 0
        let store = model.thumbnailStore
        return Button { onPlay(job.id) } label: {
            HoverTracking { hovering in
            VStack(alignment: .leading, spacing: 8) {
                VideoThumbnail(videoID: job.id, store: store, tint: tint)
                    .overlay {
                        Image(systemName: "play.fill").font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(Color.black.opacity(0.45), in: Circle())
                            .opacity(hovering ? 1 : 0)
                            .animation(.easeOut(duration: 0.12), value: hovering)
                    }
                    .overlay(alignment: .bottom) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.3))
                                Capsule().fill(.white).frame(width: proxy.size.width * fraction)
                            }
                        }
                        .frame(height: 4)
                        .padding(10)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(job)).fontWeight(.medium).lineLimit(2).multilineTextAlignment(.leading)
                    if let home { Text(home.name).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
        .help("Resume at \(PlaybackClock.text(position.seconds))")
        .accessibilityLabel("\(title(job)), resume at \(PlaybackClock.text(position.seconds))")
        .accessibilityIdentifier("continue-\(job.id)")
    }

    private func tile(name: String, symbol: String, tint: Color, videos: [StudyJob], identifier: String,
                      action: @escaping () -> Void) -> some View {
        let detail = "\(videos.count) video\(videos.count == 1 ? "" : "s")"
        return Button(action: action) {
            tileLabel(name: name, symbol: symbol, tint: tint, detail: detail)
        }
        .buttonStyle(BubbleLinkStyle())
        .accessibilityLabel("\(name), \(detail)")
        .accessibilityIdentifier(identifier)
    }

    private func tileLabel(name: String, symbol: String, tint: Color, detail: String) -> some View {
        HStack(spacing: 14) {
            // The collection's own icon and colour, as chosen in Edit Collection.
            RuleKindTile(symbol: symbol, tint: tint, size: ShieldMetrics.headerIcon)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).fontWeight(.medium).lineLimit(1)
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .shieldBubble(padding: 14)
    }

    // MARK: Reordering

    /// Moves with the pointer; entering another tile moves the dragged one
    /// there at once. A plain click never starts it (6 pt of movement first).
    private func reorderGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.gridSpace))
            .onChanged { value in
                if dragging == nil {
                    guard let frame = tileFrames[id] else { return }
                    suppressTap = true
                    grab = CGSize(width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY)
                    dragPoint = value.location
                    dragging = id
                }
                guard dragging == id else { return }
                dragPoint = value.location
                if let target = model.collectionLayout.collections.first(where: {
                    $0.id != id && tileFrames[$0.id]?.contains(value.location) == true
                }) {
                    model.moveCollection(id, to: target.id)
                }
            }
            .onEnded { _ in
                guard dragging == id else { return }
                // Settle into its new place, then show the real tile again.
                if let frame = tileFrames[id] {
                    withAnimation(.snappy(duration: 0.2)) {
                        dragPoint = CGPoint(x: frame.minX + grab.width, y: frame.minY + grab.height)
                    } completion: {
                        dragging = nil
                    }
                } else {
                    dragging = nil
                }
                // The click that ends a drag isn't a click on the tile.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { suppressTap = false }
            }
    }

    /// The lifted copy of the tile being dragged, under the pointer.
    @ViewBuilder private var liftedTile: some View {
        if let id = dragging, let collection = model.collectionLayout.collection(id),
           let frame = tileFrames[id] {
            let count = model.libraryJobs(in: id).count
            tileLabel(name: collection.name, symbol: collection.symbol, tint: collection.color.color,
                      detail: "\(count) video\(count == 1 ? "" : "s")")
                .frame(width: frame.width, height: frame.height)
                .scaleEffect(1.02)
                .shadow(color: .black.opacity(0.22), radius: 14, y: 6)
                .position(x: dragPoint.x - grab.width + frame.width / 2,
                          y: dragPoint.y - grab.height + frame.height / 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var downloadsStrip: some View {
        HStack(spacing: 14) {
            Image(systemName: failed > 0 && waiting == 0 ? "exclamationmark.arrow.circlepath" : "arrow.down.circle.fill")
                .font(.title2).foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if waiting > 0 {
                    Text("\(waiting) video\(waiting == 1 ? "" : "s") waiting to download.").fontWeight(.medium)
                }
                if failed > 0 {
                    Text("\(failed) didn't download. Retrying tries other ways to fetch \(failed == 1 ? "it" : "them").")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let downloadBlockedReason {
                    Text(downloadBlockedReason).font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Download \(min(waiting + failed, ShieldViewModel.downloadBatchLimit))", action: onDownload)
                .buttonStyle(.borderedProminent)
                .disabled(downloadBlockedReason != nil)
                .accessibilityIdentifier("homeDownloadAll")
        }
        .shieldBubble(padding: 16)
    }
}

extension StudyJob {
    var isSaved: Bool { if case .complete = state { true } else { false } }
    var isFailed: Bool { if case .failed = state { true } else { false } }
}

/// A video length or position as 4:05 or 1:02:05.
enum PlaybackClock {
    static func text(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs)
                         : String(format: "%d:%02d", minutes, secs)
    }
}
