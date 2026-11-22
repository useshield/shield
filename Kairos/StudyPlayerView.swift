import AVKit
import AppKit
import Observation
import SwiftUI

struct StudyPlaybackSelection: Identifiable {
    let video: StudyVideo
    let store: StudyPlaybackStore
    let showTranscript: Bool
    var id: String { video.id }
}

@MainActor
@Observable
final class StudyPlayerSession {
    /// The video playing now; Next swaps it in place.
    private(set) var selection: StudyPlaybackSelection
    let player = AVPlayer()
    private(set) var loading = true
    private(set) var playbackError: String?
    private(set) var saveError: String?
    private(set) var transcript: String?
    private(set) var transcriptError: String?
    /// The transcript's timed lines (empty for videos saved without them).
    private(set) var cues: [TranscriptCue] = []
    /// The saved place (every 5 s), and where playback is now (4× a second).
    private(set) var position: TimeInterval = 0
    private(set) var time: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var needsPositionReset = false
    /// The video played through to its end (offers the next one).
    private(set) var reachedEnd = false
    private(set) var isPlaying = false
    private(set) var speed: Float = PlayerPrefs.savedSpeed
    private(set) var volume: Float = PlayerPrefs.savedVolume
    private(set) var muted = UserDefaults.standard.bool(forKey: PlayerPrefs.mutedKey)
    var loops = false
    /// Held down (mouse or space bar): plays at 2× until let go.
    private(set) var boosted = false
    @ObservationIgnored private var pauseAfterBoost = false
    @ObservationIgnored private(set) var mediaURL: URL?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var clock: Any?
    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var preparationID = UUID()
    @ObservationIgnored private var canCheckpoint = false
    @ObservationIgnored private var scrubbing = false
    @ObservationIgnored private var resumeAfterScrub = false

    init(selection: StudyPlaybackSelection) {
        self.selection = selection
        player.allowsExternalPlayback = false
        player.defaultRate = speed
        player.volume = volume
        player.isMuted = muted
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.timeControlStatus != .paused
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying != playing else { return }
                self.isPlaying = playing
            }
        }
    }

    func prepare() async {
        endBoost()
        stopObserving()
        player.pause()
        player.replaceCurrentItem(with: nil)
        loading = true
        playbackError = nil
        saveError = nil
        duration = 0
        time = 0
        canCheckpoint = false
        mediaURL = nil
        loadTranscript()
        let attempt = UUID()
        preparationID = attempt
        do {
            let saved: StudyPlaybackPosition?
            do {
                saved = try selection.store.load(videoID: selection.id)
                needsPositionReset = false
            } catch {
                needsPositionReset = true
                throw error
            }
            let url = try selection.store.mediaURL(videoID: selection.id)
            let asset = AVURLAsset(url: url)
            let playable = try await asset.load(.isPlayable)
            let seconds = CMTimeGetSeconds(try await asset.load(.duration))
            try Task.checkCancellation()
            guard preparationID == attempt else { return }
            guard playable, seconds.isFinite, seconds > 0 else {
                throw StudyDownloadError.invalidMedia("This saved video cannot be played. Import it again.")
            }
            mediaURL = url
            duration = seconds
            position = min(saved?.resumeSeconds ?? 0, seconds - min(2, seconds * 0.02))
            let item = AVPlayerItem(asset: asset)
            // Speech stays clear and at its own pitch at 1.5× or 2×.
            item.audioTimePitchAlgorithm = .timeDomain
            itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                let detail = item.error?.localizedDescription ?? "The video stopped unexpectedly."
                Task { @MainActor [weak self] in
                    guard let self, self.preparationID == attempt else { return }
                    self.playbackError = detail
                }
            }
            player.replaceCurrentItem(with: item)
            reachedEnd = false
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                 object: item, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.preparationID == attempt else { return }
                    if self.loops {
                        self.seek(to: 0)
                        self.player.play()
                    } else {
                        self.reachedEnd = true
                        self.time = self.duration
                        self.checkpoint()
                    }
                }
            }
            let sought = await player.seek(to: CMTime(seconds: position, preferredTimescale: 600),
                                          toleranceBefore: .zero, toleranceAfter: .zero)
            try Task.checkCancellation()
            guard preparationID == attempt else { return }
            guard sought else { throw StudyDownloadError.invalidMedia("The saved position could not be loaded. Try again.") }
            let actualPosition = CMTimeGetSeconds(player.currentTime())
            guard actualPosition.isFinite, actualPosition >= 0 else {
                throw StudyDownloadError.invalidMedia("The player returned an invalid position. Try again.")
            }
            position = actualPosition
            time = actualPosition
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.checkpoint() }
            }
            clock = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                                                   queue: .main) { [weak self] now in
                let seconds = CMTimeGetSeconds(now)
                Task { @MainActor [weak self] in
                    guard let self, !self.scrubbing, seconds.isFinite else { return }
                    self.time = min(max(seconds, 0), self.duration)
                }
            }
            loading = false
            canCheckpoint = true
            // Opening a transcript does not start audio behind the text panel.
            if !selection.showTranscript { player.play() }
        } catch {
            guard preparationID == attempt else { return }
            loading = false
            if !(error is CancellationError) { playbackError = error.localizedDescription }
        }
    }

    /// Saves this video's place and plays another in the same player.
    func switchTo(_ next: StudyPlaybackSelection) async {
        close()
        selection = next
        reachedEnd = false
        await prepare()
    }

    func loadTranscript() {
        do {
            // Older downloads saved one caption per line; show them as paragraphs.
            transcript = try selection.store.transcript(videoID: selection.id).map(TranscriptFormatter().readable)
            transcriptError = nil
        } catch { transcript = nil; transcriptError = error.localizedDescription }
        // Timing is extra: without it the transcript is plain text, as before.
        cues = transcript == nil ? [] : ((try? selection.store.cues(videoID: selection.id)) ?? nil) ?? []
    }

    func checkpoint() {
        guard canCheckpoint, duration > 0, !loading, !needsPositionReset else { return }
        let seconds = CMTimeGetSeconds(player.currentTime())
        guard seconds.isFinite, seconds >= 0 else { return }
        position = seconds
        do {
            try selection.store.save(videoID: selection.id, seconds: seconds, duration: duration)
            saveError = nil
        } catch { saveError = "Position could not be saved: \(error.localizedDescription)" }
    }

    func resetPosition() async {
        do {
            try selection.store.reset(videoID: selection.id)
            await prepare()
        } catch { playbackError = error.localizedDescription }
    }

    func close(save: Bool = true) {
        endBoost()
        if save { checkpoint() }
        canCheckpoint = false
        preparationID = UUID()
        player.pause()
        stopObserving()
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Controls

    var canControl: Bool { !loading && playbackError == nil && duration > 0 }

    func play() {
        guard canControl else { return }
        if reachedEnd { seek(to: 0) }
        player.play()
    }

    func pause() { player.pause() }

    func togglePlay() { isPlaying ? pause() : play() }

    func seek(to seconds: TimeInterval) {
        guard canControl else { return }
        let target = min(max(seconds, 0), max(duration - 0.05, 0))
        time = target
        if target < duration - 0.5 { reachedEnd = false }
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ seconds: TimeInterval) {
        let now = CMTimeGetSeconds(player.currentTime())
        seek(to: (now.isFinite ? now : time) + seconds)
    }

    /// One frame at a time (pauses first).
    func step(_ frames: Int) {
        guard canControl, let item = player.currentItem else { return }
        pause()
        item.step(byCount: frames)
        let now = CMTimeGetSeconds(player.currentTime())
        if now.isFinite { time = now }
    }

    func beginScrubbing() {
        guard canControl else { return }
        scrubbing = true
        resumeAfterScrub = isPlaying
        pause()
    }

    /// While dragging: a nearby frame is enough, so the picture keeps up.
    func scrub(to seconds: TimeInterval) {
        guard canControl else { return }
        time = min(max(seconds, 0), duration)
        let tolerance = CMTime(seconds: 0.4, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func endScrubbing(at seconds: TimeInterval) {
        guard scrubbing else { return }
        scrubbing = false
        seek(to: seconds)
        if resumeAfterScrub { player.play() }
        checkpoint()
    }

    func setSpeed(_ value: Float) {
        guard PlayerPrefs.speeds.contains(value) else { return }
        speed = value
        UserDefaults.standard.set(value, forKey: PlayerPrefs.speedKey)
        // While held at 2×, the new speed starts when it's let go.
        guard !boosted else { return }
        player.defaultRate = value
        if isPlaying { player.rate = value }
    }

    static let boostRate: Float = 2

    /// Holding the video or the space bar: 2× for as long as it's held. A
    /// paused video plays while held and pauses again when let go. The chosen
    /// speed is never changed or saved.
    func beginBoost() {
        guard canControl, !boosted, !scrubbing else { return }
        boosted = true
        // The player's own rate: isPlaying catches up a moment later.
        pauseAfterBoost = player.rate == 0
        if reachedEnd { seek(to: 0) }
        player.defaultRate = Self.boostRate
        player.rate = Self.boostRate
    }

    func endBoost() {
        guard boosted else { return }
        boosted = false
        player.defaultRate = speed
        if pauseAfterBoost { player.pause() }
        else if player.rate != 0 { player.rate = speed }
    }

    func setVolume(_ value: Float) {
        volume = min(max(value, 0), 1)
        player.volume = volume
        if muted && volume > 0 { muted = false; player.isMuted = false }
        UserDefaults.standard.set(volume, forKey: PlayerPrefs.volumeKey)
        UserDefaults.standard.set(muted, forKey: PlayerPrefs.mutedKey)
    }

    func toggleMute() {
        muted.toggle()
        if !muted && volume == 0 { setVolume(0.5) }
        player.isMuted = muted
        UserDefaults.standard.set(muted, forKey: PlayerPrefs.mutedKey)
    }

    private func stopObserving() {
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        if let clock { player.removeTimeObserver(clock) }
        clock = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        itemObservation = nil
    }
}

@MainActor
struct StudyPlayerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: StudyPlayerSession
    @State private var showingTranscript: Bool

    /// The video's current name (it can be renamed after the library opened).
    private let videoTitle: (String) -> String?
    /// The next saved video after this one in the list being watched.
    private let nextID: (String) -> String?
    /// Opens a video for playing; nil when it can't be played.
    private let selectionFor: (String) -> StudyPlaybackSelection?
    /// Runs for each video when the player leaves it (Back, Next, or quit).
    private let onLeave: (String) -> Void
    /// Theater and full screen hide the sidebar.
    private let onTheater: (Bool) -> Void

    @AppStorage(PlayerPrefs.autoplayKey) private var autoplay = true
    @AppStorage(PlayerPrefs.captionsKey) private var captions = false
    @State private var theater = false
    @State private var fullScreen = false
    @State private var surface = PlayerSurfaceHandle()
    @State private var controlsShown = true
    @State private var hoveringBar = false
    @State private var hideControls: Task<Void, Never>?
    @State private var flash: PlayerFlash?
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    /// A space bar press that becomes 2× if it's still held after a moment.
    @State private var spaceHold: Task<Void, Never>?
    @FocusState private var playerFocused: Bool

    @State private var transcriptQuery = ""
    @State private var copied = false
    /// The transcript's size beside (wide) or below (narrow) the video,
    /// dragged on the divider and kept for next time.
    @AppStorage("Shield.TranscriptWidth") private var transcriptWidth = 360.0
    @AppStorage("Shield.TranscriptHeight") private var transcriptHeight = 220.0
    /// Size when the current drag began; resets itself if the drag is cancelled.
    @GestureState private var dragStart: Double?
    /// The size while dragging. Saved once when the drag ends, not on every
    /// mouse move (each save re-laid out the whole transcript; lag audit).
    @State private var liveSize: Double?

    init(selection: StudyPlaybackSelection,
         title: @escaping (String) -> String? = { _ in nil },
         nextID: @escaping (String) -> String? = { _ in nil },
         selectionFor: @escaping (String) -> StudyPlaybackSelection? = { _ in nil },
         onTheater: @escaping (Bool) -> Void = { _ in },
         onLeave: @escaping (String) -> Void = { _ in }) {
        self.videoTitle = title
        self.nextID = nextID
        self.selectionFor = selectionFor
        self.onTheater = onTheater
        self.onLeave = onLeave
        _session = State(initialValue: StudyPlayerSession(selection: selection))
        _showingTranscript = State(initialValue: selection.showTranscript)
    }

    private var currentID: String { session.selection.id }
    private var upNextID: String? { nextID(currentID) }
    private var upNextTitle: String? {
        upNextID.map { videoTitle($0) ?? session.selection.video.title }
    }
    private var immersive: Bool { theater || fullScreen }

    var body: some View {
        VStack(spacing: 12) {
            if let error = session.playbackError {
                ContentUnavailableView {
                    Label("This video can't be played", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(session.needsPositionReset ? "Its saved position doesn't match the file."
                                                    : "The saved file couldn't be opened.")
                        .help(error)
                } actions: {
                    Button("Try Again") { Task { await session.prepare() } }
                    if session.needsPositionReset {
                        Button("Start from the Beginning") { Task { await session.resetPosition() } }
                    }
                    if upNextID != nil { Button("Play Next Video") { playNext() } }
                }
                .shieldBubble(padding: 24)
                .frame(maxWidth: 760, maxHeight: .infinity, alignment: .top)
            } else {
                // The video takes all remaining space and grows with the window;
                // the transcript sits beside it when wide and below it when narrow.
                GeometryReader { proxy in
                    let wide = proxy.size.width >= 900
                    let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                    layout {
                        video
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .frame(minWidth: wide ? 320 : nil, minHeight: 180)
                        if showingTranscript && !immersive {
                            let width = Self.clamp(wide ? liveSize ?? transcriptWidth : transcriptWidth,
                                                   240, proxy.size.width - 340)
                            let height = Self.clamp(wide ? transcriptHeight : liveSize ?? transcriptHeight,
                                                    120, proxy.size.height - 200)
                            SplitHandle(sideBySide: wide)
                                // Global coordinates: the handle itself moves while it's
                                // dragged, so local ones made it jitter.
                                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                    .updating($dragStart) { _, start, _ in
                                        if start == nil { start = wide ? width : height }
                                    }
                                    .onChanged { drag in
                                        // Dragging toward the video makes the transcript bigger.
                                        let start = dragStart ?? (wide ? width : height)
                                        liveSize = wide
                                            ? Self.clamp(start - drag.translation.width, 240, proxy.size.width - 340)
                                            : Self.clamp(start - drag.translation.height, 120, proxy.size.height - 200)
                                    }
                                    .onEnded { _ in
                                        if let liveSize {
                                            if wide { transcriptWidth = liveSize } else { transcriptHeight = liveSize }
                                        }
                                        liveSize = nil
                                    })
                                .onTapGesture(count: 2) {
                                    withAnimation(.snappy) { transcriptWidth = 360; transcriptHeight = 220 }
                                }
                            transcript
                                .frame(width: wide ? width : nil, height: wide ? nil : height)
                                .frame(maxHeight: wide ? .infinity : nil)
                        }
                    }
                }
            }
            if session.saveError != nil && !fullScreen {
                Label("Your place in this video couldn't be saved.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .help(session.saveError ?? "")
            }
        }
        .padding(fullScreen ? 0 : 16)
        .frame(minWidth: 380, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
        .background(fullScreen ? Color.black : Color.shieldPage)
        .buttonBorderShape(.capsule)
        .navigationTitle(videoTitle(currentID) ?? session.selection.video.title)
        .toolbar {
            if upNextID != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: playNext) { Label("Next", systemImage: "forward.end.fill") }
                        .help("Next: \(upNextTitle ?? "")")
                        .keyboardShortcut(.rightArrow, modifiers: [.command])
                        .accessibilityIdentifier("playerNextToolbar")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $showingTranscript) { Label("Transcript", systemImage: "text.quote") }
                    .help(showingTranscript ? "Hide transcript" : "Show transcript")
                    .accessibilityIdentifier("playerTranscript")
            }
        }
        .task { await session.prepare(); playerFocused = true; poke() }
        .onDisappear {
            countdownTask?.cancel()
            hideControls?.cancel()
            NSCursor.setHiddenUntilMouseMoves(false)
            let id = currentID
            session.close()
            onLeave(id)
            if theater { onTheater(false) }
            if fullScreen { surface.toggleFullScreen() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.checkpoint() }
        }
        .onChange(of: session.reachedEnd) { _, ended in
            if ended { startCountdown() } else { cancelCountdown() }
        }
        .onChange(of: session.isPlaying) { _, _ in poke() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === surface.window else { return }
            fullScreen = true
            onTheater(true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard (note.object as? NSWindow) === surface.window else { return }
            fullScreen = false
            onTheater(theater)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            session.close()
        }
    }

    // MARK: Video and controls

    private var video: some View {
        ZStack {
            PlayerSurface(player: session.player, handle: surface,
                          accessibilityValue: "Playback position \(Int(session.position)) seconds",
                          onClick: click,
                          onHold: { holding in
                              playerFocused = true
                              if holding { session.beginBoost() } else { session.endBoost() }
                          })
            if session.loading {
                ProgressView("Opening video…").controlSize(.large).tint(.white).foregroundStyle(.white)
            }
            if let flash {
                PlayerFlashView(flash: flash)
                    .id(flash.id)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.85)),
                                            removal: .opacity.combined(with: .scale(scale: 1.15))))
            }
            if session.reachedEnd && !session.boosted { endCard }
        }
        .overlay(alignment: .top) {
            if session.boosted {
                Label("2×", systemImage: "forward.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.top, 16)
                    .transition(.opacity)
                    .accessibilityIdentifier("playerBoost")
            }
        }
        .overlay(alignment: .bottom) {
            if captions, !session.cues.isEmpty, !session.reachedEnd {
                CaptionOverlay(cues: session.cues, session: session, large: immersive)
                    .padding(.bottom, controlsShown || !session.isPlaying ? 84 : 28)
                    .animation(.easeOut(duration: 0.18), value: controlsShown || !session.isPlaying)
            }
        }
        .overlay(alignment: .bottom) {
            if controlsShown || !session.isPlaying {
                PlayerControlBar(session: session, nextTitle: upNextTitle, onNext: playNext,
                                 theater: theater, fullScreen: fullScreen,
                                 supportsPictureInPicture: surface.supportsPictureInPicture,
                                 onTheater: toggleTheater,
                                 onPictureInPicture: { surface.togglePictureInPicture() },
                                 onFullScreen: { surface.toggleFullScreen() },
                                 autoplay: $autoplay, captions: $captions, hoveringBar: $hoveringBar)
                    .disabled(!session.canControl)
                    .transition(.opacity)
            }
        }
        .background(Color.black)
        .clipShape(fullScreen ? AnyShape(Rectangle()) : AnyShape(ShieldBubble.shape))
        .animation(.easeOut(duration: 0.18), value: controlsShown || !session.isPlaying)
        .animation(.easeOut(duration: 0.12), value: flash)
        .animation(.easeOut(duration: 0.12), value: session.boosted)
        .onContinuousHover { phase in
            if case .active = phase { poke() }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($playerFocused)
        .onKeyPress(phases: [.down, .repeat, .up]) { press in handleKey(press) }
        // A key let go somewhere else never leaves the video stuck at 2×.
        .onChange(of: playerFocused) { _, focused in if !focused { stopSpaceHold() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard (note.object as? NSWindow) === surface.window else { return }
            stopSpaceHold()
        }
    }

    private var endCard: some View {
        VStack(spacing: 14) {
            if let upNextTitle {
                VStack(spacing: 4) {
                    Text(countdown.map { "Next video in \($0)" } ?? "Up next")
                        .font(.callout).foregroundStyle(.white.opacity(0.75))
                    Text(upNextTitle).font(.title3.weight(.semibold)).foregroundStyle(.white)
                        .lineLimit(2).multilineTextAlignment(.center)
                }
                HStack(spacing: 10) {
                    Button("Play Now", action: playNext)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("playNextLesson")
                    if countdown != nil {
                        Button("Cancel") { cancelCountdown() }.accessibilityIdentifier("cancelAutoplay")
                    } else {
                        Button("Watch Again") { session.play() }
                    }
                }
            } else {
                Button { session.play() } label: { Label("Watch Again", systemImage: "arrow.counterclockwise") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("replayVideo")
            }
        }
        .padding(22)
        .frame(maxWidth: 420)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .controlSize(.large)
    }

    /// Shows the controls, and hides them again after a pause while playing.
    private func poke() {
        controlsShown = true
        hideControls?.cancel()
        guard session.isPlaying else { return }
        hideControls = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, session.isPlaying, !hoveringBar else { return }
            controlsShown = false
            if fullScreen { NSCursor.setHiddenUntilMouseMoves(true) }
        }
    }

    private func show(_ symbol: String, _ text: String? = nil) {
        let next = PlayerFlash(symbol: symbol, text: text)
        flash = next
        Task {
            try? await Task.sleep(for: PlayerFlashView.duration(next))
            if flash == next { flash = nil }
        }
    }

    private func click(_ count: Int) {
        playerFocused = true
        guard session.canControl else { return }
        if count == 2 {
            // The first click already played or paused; put that back.
            session.togglePlay()
            surface.toggleFullScreen()
        } else if count == 1 {
            session.togglePlay()
            show(session.isPlaying ? "pause.fill" : "play.fill")
        }
        poke()
    }

    private func toggleTheater() {
        theater.toggle()
        onTheater(theater || fullScreen)
        poke()
    }

    private func playNext() {
        cancelCountdown()
        guard let id = upNextID, let next = selectionFor(id) else { return }
        let leaving = currentID
        Task {
            await session.switchTo(StudyPlaybackSelection(video: next.video, store: next.store, showTranscript: false))
            onLeave(leaving)
            playerFocused = true
            poke()
        }
    }

    private func startCountdown() {
        cancelCountdown()
        guard autoplay, upNextID != nil, !session.loops else { return }
        countdown = 5
        countdownTask = Task {
            while let left = countdown, left > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                countdown = left - 1
            }
            guard !Task.isCancelled, session.reachedEnd else { return }
            playNext()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    // MARK: Keys

    /// Space: a tap plays or pauses (when let go); held, it plays at 2×
    /// until let go, like YouTube.
    private func spaceKey(_ phase: KeyPress.Phases) -> KeyPress.Result {
        switch phase {
        case .down:
            guard spaceHold == nil, !session.boosted else { return .handled }
            poke()
            spaceHold = Task {
                try? await Task.sleep(for: .seconds(StudyPlayerView.holdDelay))
                guard !Task.isCancelled else { return }
                session.beginBoost()
            }
        case .up:
            let tapped = !session.boosted && spaceHold != nil
            stopSpaceHold()
            if tapped { session.togglePlay(); show(session.isPlaying ? "pause.fill" : "play.fill") }
            poke()
        default: break // key repeat while held
        }
        return .handled
    }

    private func stopSpaceHold() {
        spaceHold?.cancel()
        spaceHold = nil
        session.endBoost()
    }

    /// How long a press must last to become 2× (mouse and space bar).
    static let holdDelay = 0.35

    /// YouTube-style keys while the video has focus. Anything with ⌘ is left
    /// for the menus (⌘→ is Next).
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard session.canControl, !press.modifiers.contains(.command) else { return .ignored }
        if press.key == .space { return spaceKey(press.phase) }
        // Only the first press counts for the other keys, as before.
        guard press.phase == .down else { return .ignored }
        poke()
        switch press.key {
        case .leftArrow:
            session.skip(-5); show("gobackward.5"); return .handled
        case .rightArrow:
            session.skip(5); show("goforward.5"); return .handled
        case .upArrow:
            session.setVolume(session.volume + 0.1)
            show("speaker.wave.2.fill", "\(Int((session.volume * 100).rounded()))%"); return .handled
        case .downArrow:
            session.setVolume(session.volume - 0.1)
            show(session.volume == 0 ? "speaker.slash.fill" : "speaker.wave.1.fill",
                 "\(Int((session.volume * 100).rounded()))%"); return .handled
        default: break
        }
        switch press.characters.lowercased() {
        case "k":
            session.togglePlay(); show(session.isPlaying ? "pause.fill" : "play.fill")
        case "j":
            session.skip(-10); show("gobackward.10")
        case "l":
            session.skip(10); show("goforward.10")
        case "m":
            session.toggleMute(); show(session.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
        case "f":
            surface.toggleFullScreen()
        case "t":
            if !fullScreen { toggleTheater() }
        case "p":
            if surface.supportsPictureInPicture { surface.togglePictureInPicture() }
        case "c":
            guard !session.cues.isEmpty else { return .ignored }
            captions.toggle()
            show(captions ? "captions.bubble.fill" : "captions.bubble", captions ? "Captions on" : "Captions off")
        case "n":
            if upNextID != nil { playNext() } else { return .ignored }
        case ",":
            session.step(-1)
        case ".":
            session.step(1)
        case "<":
            session.setSpeed(PlayerPrefs.speed(after: session.speed, faster: false))
            show("tortoise.fill", PlayerPrefs.speedName(session.speed))
        case ">":
            session.setSpeed(PlayerPrefs.speed(after: session.speed, faster: true))
            show("hare.fill", PlayerPrefs.speedName(session.speed))
        case let digit where digit.count == 1 && digit.first!.isNumber:
            let tenth = Double(digit) ?? 0
            session.seek(to: session.duration * tenth / 10)
            show("arrow.right.to.line", PlayerPrefs.clock(session.duration * tenth / 10))
        default:
            return .ignored
        }
        return .handled
    }
}

extension StudyPlayerView {
    private var transcriptText: String {
        if session.transcriptError != nil { return "The transcript couldn't be read." }
        guard let text = session.transcript else { return "No transcript for this video." }
        let query = transcriptQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return text }
        let matches = text.split(whereSeparator: \.isNewline).filter { $0.localizedCaseInsensitiveContains(query) }
        return matches.isEmpty ? "No lines mention “\(query)”." : matches.joined(separator: "\n\n")
    }

    fileprivate static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), max(low, high))
    }

    /// Title and Copy, a search field, then the text.
    fileprivate var transcript: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Text("Transcript").font(.headline)
                    Spacer()
                    Button(action: copyTranscript) {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.borderless)
                    .disabled(session.transcript == nil)
                    .help("Copy the whole transcript")
                    .accessibilityIdentifier("copyTranscript")
                }
                if session.transcript != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("Search transcript", text: $transcriptQuery)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("transcriptSearch")
                        if !transcriptQuery.isEmpty {
                            Button { transcriptQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.tertiary)
                                .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }
            }
            .padding(14)
            Divider().opacity(0.6)
            if !session.cues.isEmpty {
                TimedTranscriptList(cues: session.cues, session: session,
                                    query: transcriptQuery.trimmingCharacters(in: .whitespaces))
            } else {
            ScrollView {
                Text(transcriptText)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .foregroundStyle(session.transcript == nil ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .accessibilityIdentifier("playerTranscriptText")
            }
            }
        }
        .background(Color.shieldCard, in: ShieldBubble.shape)
        .overlay(ShieldBubble.shape.strokeBorder(Color.shieldCardBorder))
        .clipShape(ShieldBubble.shape)
    }

    private func copyTranscript() {
        guard let text = session.transcript else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { return }
        withAnimation { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation { copied = false }
        }
    }
}

/// The transcript line by line with its times: the line being
/// said is highlighted and kept in view, and clicking a line plays from there.
/// Scrolling by hand stops the following for a few seconds.
private struct TimedTranscriptList: View {
    let cues: [TranscriptCue]
    let session: StudyPlayerSession
    let query: String
    @State private var followPausedUntil = Date.distantPast

    private var shown: [Int] {
        guard !query.isEmpty else { return Array(cues.indices) }
        return cues.indices.filter { cues[$0].text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let current = TranscriptCue.lastStarted(at: session.time, in: cues)
        let rows = shown
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if rows.isEmpty {
                        Text("No lines mention “\(query)”.").foregroundStyle(.secondary).padding(8)
                    }
                    ForEach(rows, id: \.self) { index in
                        row(index, isCurrent: index == current)
                    }
                }
                .padding(8)
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating {
                    followPausedUntil = Date().addingTimeInterval(4)
                }
            }
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            .onChange(of: current) { _, line in
                guard let line, query.isEmpty, Date() >= followPausedUntil else { return }
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(line, anchor: .center) }
            }
        }
        .accessibilityIdentifier("playerTranscriptLines")
    }

    private func row(_ index: Int, isCurrent: Bool) -> some View {
        let cue = cues[index]
        return Button {
            session.seek(to: cue.start)
            session.play()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(PlayerPrefs.clock(cue.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.shieldAccent : .secondary)
                    .frame(width: 48, alignment: .leading)
                Text(cue.text)
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(isCurrent ? Color.shieldAccent.opacity(0.12) : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Play from \(PlayerPrefs.clock(cue.start))")
        .accessibilityLabel("\(PlayerPrefs.clock(cue.start)), \(cue.text)")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("transcriptLine-\(index)")
        .animation(.easeOut(duration: 0.2), value: isCurrent)
    }
}

/// Captions on the video, from the transcript's timing: the line being said,
/// with the one before it while they run together.
private struct CaptionOverlay: View {
    let cues: [TranscriptCue]
    let session: StudyPlayerSession
    let large: Bool

    var body: some View {
        if let index = TranscriptCue.index(at: session.time, in: cues) {
            let current = cues[index]
            let previous = index > 0 && current.start - cues[index - 1].end < 1 ? cues[index - 1].text : nil
            Text([previous, current.text].compactMap { $0 }.joined(separator: "\n"))
                .font(large ? .title2.weight(.medium) : .title3.weight(.medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 40)
                .allowsHitTesting(false)
                .accessibilityIdentifier("playerCaptionText")
        }
    }
}

/// The divider between the video and the transcript: drag to resize,
/// double-click to reset.
private struct SplitHandle: View {
    let sideBySide: Bool
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            Capsule()
                .fill(Color.primary.opacity(hovering ? 0.35 : 0.15))
                .frame(width: sideBySide ? 4 : 40, height: sideBySide ? 40 : 4)
        }
        .frame(width: sideBySide ? 16 : nil, height: sideBySide ? nil : 16)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pointerStyle(sideBySide ? .columnResize : .rowResize)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help("Drag to resize · double-click to reset")
        .accessibilityLabel("Resize transcript")
    }
}
