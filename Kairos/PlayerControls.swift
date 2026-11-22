import AVFoundation
import AVKit
import AppKit
import SwiftUI

// Shield's own video controls (Apple's built-in controls
// weren't enough). The video is drawn by an AVPlayerLayer; everything on top
// of it is here: the bar, the timeline with a picture preview, the speed and
// volume controls, and the little sign that confirms a key press.

/// Player choices kept from one video to the next.
enum PlayerPrefs {
    static let speedKey = "Shield.PlayerSpeed"
    static let volumeKey = "Shield.PlayerVolume"
    static let mutedKey = "Shield.PlayerMuted"
    static let autoplayKey = "Shield.PlayerAutoplay"
    static let captionsKey = "Shield.PlayerCaptions"
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    static func speedName(_ speed: Float) -> String {
        speed == 1 ? "1×" : "\(Double(speed).formatted(.number.precision(.fractionLength(0...2))))×"
    }

    /// The next listed speed up or down; stays put at either end.
    static func speed(after speed: Float, faster: Bool) -> Float {
        if faster { return speeds.first { $0 > speed + 0.001 } ?? speeds.last! }
        return speeds.last { $0 < speed - 0.001 } ?? speeds.first!
    }

    static var savedSpeed: Float {
        let saved = UserDefaults.standard.float(forKey: speedKey)
        return speeds.contains(saved) ? saved : 1
    }

    static var savedVolume: Float {
        guard UserDefaults.standard.object(forKey: volumeKey) != nil else { return 1 }
        return min(max(UserDefaults.standard.float(forKey: volumeKey), 0), 1)
    }

    /// "1:05", "12:40", "1:02:03".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds.rounded(.down) : 0))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Video surface

/// What the SwiftUI controls ask of the AppKit view: picture in picture and
/// the window's full screen.
@MainActor
final class PlayerSurfaceHandle {
    fileprivate weak var view: PlayerSurfaceNSView?
    var window: NSWindow? { view?.window }

    var supportsPictureInPicture: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func togglePictureInPicture() {
        guard let controller = view?.pictureInPicture else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() }
        else { controller.startPictureInPicture() }
    }

    func toggleFullScreen() { window?.toggleFullScreen(nil) }
}

final class PlayerSurfaceNSView: NSView {
    let playerLayer = AVPlayerLayer()
    fileprivate var pictureInPicture: AVPictureInPictureController?
    var onClick: ((Int) -> Void)?
    /// True when a press has been held long enough for 2×, false when let go.
    var onHold: ((Bool) -> Void)?
    private var holdTimer: DispatchWorkItem?
    private var holding = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.frame = bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(playerLayer)
        if AVPictureInPictureController.isPictureInPictureSupported() {
            pictureInPicture = AVPictureInPictureController(playerLayer: playerLayer)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Video")
        setAccessibilityIdentifier("studyVideoPlayer")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    // A click plays or pauses (when let go); a double-click goes full screen;
    // a press held down plays at 2× until it's let go.
    override func mouseDown(with event: NSEvent) {
        cancelHold()
        guard event.clickCount == 1 else { return }
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.holding = true
            self.onHold?(true)
        }
        holdTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + StudyPlayerView.holdDelay, execute: timer)
    }

    override func mouseUp(with event: NSEvent) {
        let held = holding
        cancelHold()
        if !held { onClick?(event.clickCount) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelHold() }
    }

    private func cancelHold() {
        holdTimer?.cancel()
        holdTimer = nil
        if holding { holding = false; onHold?(false) }
    }

    override var acceptsFirstResponder: Bool { false }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let handle: PlayerSurfaceHandle
    /// Spoken by VoiceOver and read by the UI tests.
    let accessibilityValue: String
    let onClick: (Int) -> Void
    var onHold: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> PlayerSurfaceNSView {
        let view = PlayerSurfaceNSView()
        view.playerLayer.player = player
        handle.view = view
        return view
    }

    func updateNSView(_ view: PlayerSurfaceNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        handle.view = view
        view.onClick = onClick
        view.onHold = onHold
        view.setAccessibilityValue(accessibilityValue)
    }
}

// MARK: - Timeline

/// Pictures for the timeline's hover preview, taken from the saved file.
@MainActor
final class TimelinePreviewer {
    private var generator: AVAssetImageGenerator?
    private var source: URL?
    private var pending: Task<Void, Never>?

    func image(at seconds: TimeInterval, in url: URL, deliver: @escaping @MainActor (CGImage?) -> Void) {
        if source != url {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 180)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
            self.generator = generator
            source = url
        }
        pending?.cancel()
        guard let generator else { return }
        pending = Task {
            // Only the place the pointer rests on, not every point it crosses.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            guard !Task.isCancelled else { return }
            deliver(image)
        }
    }

    func cancel() { pending?.cancel(); pending = nil }
}

struct PlayerTimeline: View {
    let session: StudyPlayerSession
    @State private var hoverX: CGFloat?
    @State private var dragging = false
    @State private var preview: CGImage?
    @State private var previewer = TimelinePreviewer()

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let duration = max(session.duration, 0.001)
            let progress = CGFloat(min(max(session.time / duration, 0), 1))
            let active = hoverX != nil || dragging
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.28))
                    .frame(height: active ? 6 : 4)
                if let hoverX {
                    Capsule().fill(Color.white.opacity(0.35))
                        .frame(width: max(0, min(hoverX, width)), height: active ? 6 : 4)
                }
                Capsule().fill(Color.shieldAccent)
                    .frame(width: progress * width, height: active ? 6 : 4)
                Circle().fill(Color.white)
                    .frame(width: active ? 14 : 0, height: active ? 14 : 0)
                    .shadow(color: .black.opacity(0.35), radius: 2)
                    .offset(x: progress * width - (active ? 7 : 0))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .bottomLeading) {
                if let hoverX {
                    let seconds = Double(min(max(hoverX / width, 0), 1)) * session.duration
                    let previewWidth: CGFloat = preview == nil ? 64 : 176
                    VStack(spacing: 4) {
                        if let preview {
                            Image(decorative: preview, scale: 1).resizable().aspectRatio(16 / 9, contentMode: .fit)
                                .frame(width: 176)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.5)))
                        }
                        Text(PlayerPrefs.clock(seconds))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.75), in: Capsule())
                    }
                    .foregroundStyle(.white)
                    .fixedSize()
                    .offset(x: min(max(hoverX - previewWidth / 2, 0), width - previewWidth), y: -22)
                    .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverX = point.x
                    requestPreview(at: Double(min(max(point.x / width, 0), 1)) * session.duration)
                case .ended:
                    if !dragging { hoverX = nil; preview = nil; previewer.cancel() }
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !dragging { dragging = true; session.beginScrubbing() }
                    let x = min(max(drag.location.x, 0), width)
                    hoverX = x
                    session.scrub(to: Double(x / width) * session.duration)
                    requestPreview(at: Double(x / width) * session.duration)
                }
                .onEnded { drag in
                    let x = min(max(drag.location.x, 0), width)
                    session.endScrubbing(at: Double(x / width) * session.duration)
                    dragging = false
                })
            .animation(.easeOut(duration: 0.12), value: active)
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityLabel("Timeline")
        .accessibilityValue("\(PlayerPrefs.clock(session.time)) of \(PlayerPrefs.clock(session.duration))")
        .accessibilityAdjustableAction { direction in
            session.skip(direction == .increment ? 10 : -10)
        }
        .accessibilityIdentifier("playerTimeline")
    }

    private func requestPreview(at seconds: TimeInterval) {
        guard let url = session.mediaURL else { return }
        previewer.image(at: seconds, in: url) { image in if hoverX != nil { preview = image } }
    }
}

// MARK: - Bar

struct PlayerControlBar: View {
    let session: StudyPlayerSession
    let nextTitle: String?
    let onNext: () -> Void
    let theater: Bool
    let fullScreen: Bool
    let supportsPictureInPicture: Bool
    let onTheater: () -> Void
    let onPictureInPicture: () -> Void
    let onFullScreen: () -> Void
    @Binding var autoplay: Bool
    @Binding var captions: Bool
    @Binding var hoveringBar: Bool
    @AppStorage("Shield.PlayerShowsRemaining") private var showsRemaining = false
    @State private var hoveringVolume = false

    // Fewer things on the bar, more room between them. Play,
    // Next, volume and the time on the left; full screen on the right; speed,
    // theater, picture in picture, autoplay and loop live in the ⋯ menu.
    // Skipping 10 seconds stays on J / L and the arrow keys.
    var body: some View {
        VStack(spacing: 8) {
            PlayerTimeline(session: session)
            HStack(spacing: 18) {
                barButton(session.isPlaying ? "pause.fill" : (session.reachedEnd ? "arrow.counterclockwise" : "play.fill"),
                          session.isPlaying ? "Pause (Space)" : "Play (Space)", "playerPlayPause", size: 18) {
                    session.togglePlay()
                }
                if let nextTitle {
                    barButton("forward.end.fill", "Next: \(nextTitle) (N)", "playerNext", action: onNext)
                }
                volume
                Button {
                    showsRemaining.toggle()
                } label: {
                    Text(showsRemaining
                         ? "-\(PlayerPrefs.clock(session.duration - session.time)) / \(PlayerPrefs.clock(session.duration))"
                         : "\(PlayerPrefs.clock(session.time)) / \(PlayerPrefs.clock(session.duration))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help(showsRemaining ? "Show time played" : "Show time left")
                .accessibilityIdentifier("playerTime")
                Spacer(minLength: 12)
                // Only shown when it isn't normal speed, so it's never forgotten on.
                if session.speed != 1 {
                    Text(PlayerPrefs.speedName(session.speed))
                        .font(.callout.monospacedDigit().weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .accessibilityLabel("Speed \(PlayerPrefs.speedName(session.speed))")
                }
                optionsMenu
                barButton(fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          fullScreen ? "Exit full screen (F)" : "Full screen (F)", "playerFullScreen", action: onFullScreen)
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 18)
        .padding(.top, 30)
        .padding(.bottom, 12)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false))
        // The bar sits on the video, so it is drawn dark in light mode too.
        .environment(\.colorScheme, .dark)
        .onHover { hoveringBar = $0 }
    }

    private func barButton(_ symbol: String, _ help: String, _ identifier: String, size: CGFloat = 15,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlayerButtonStyle())
        .help(help)
        .accessibilityLabel(help.components(separatedBy: " (").first ?? help)
        .accessibilityIdentifier(identifier)
    }

    /// The speaker; its slider slides out while the pointer is over it.
    private var volume: some View {
        HStack(spacing: 4) {
            barButton(volumeSymbol, session.muted ? "Unmute (M)" : "Mute (M)", "playerMute") { session.toggleMute() }
            Slider(value: Binding(get: { Double(session.muted ? 0 : session.volume) },
                                  set: { session.setVolume(Float($0)) }), in: 0...1)
                .controlSize(.mini)
                .tint(.white)
                .frame(width: hoveringVolume ? 72 : 0)
                .opacity(hoveringVolume ? 1 : 0)
                .clipped()
                .accessibilityLabel("Volume")
                .accessibilityIdentifier("playerVolume")
        }
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { hoveringVolume = hovering } }
    }

    private var volumeSymbol: String {
        let level = session.muted ? 0 : session.volume
        if level == 0 { return "speaker.slash.fill" }
        return level < 0.34 ? "speaker.wave.1.fill" : (level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
    }

    private var optionsMenu: some View {
        Menu {
            Picker(selection: Binding(get: { session.speed }, set: { session.setSpeed($0) })) {
                ForEach(PlayerPrefs.speeds.reversed(), id: \.self) { speed in
                    Text(PlayerPrefs.speedName(speed)).tag(speed)
                }
            } label: {
                Text("Speed: \(PlayerPrefs.speedName(session.speed))")
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("playerSpeed")
            // Captions come from the transcript's timing, which videos
            // downloaded before Nov 16 don't have.
            Toggle(session.cues.isEmpty ? "Captions (not available for this video)" : "Captions",
                   isOn: $captions)
                .disabled(session.cues.isEmpty)
                .accessibilityIdentifier("playerCaptions")
            Divider()
            Toggle("Theater Mode", isOn: Binding(get: { theater }, set: { _ in onTheater() }))
                .disabled(fullScreen)
                .accessibilityIdentifier("playerTheater")
            if supportsPictureInPicture {
                Button("Picture in Picture", action: onPictureInPicture)
                    .accessibilityIdentifier("playerPictureInPicture")
            }
            Divider()
            Toggle("Play Next Video Automatically", isOn: $autoplay)
            Toggle("Loop This Video", isOn: Binding(get: { session.loops }, set: { session.loops = $0 }))
            Divider()
            Button("Start from the Beginning") { session.seek(to: 0); session.play() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Speed and more")
        .accessibilityLabel("Player options")
        .accessibilityIdentifier("playerOptions")
    }
}

struct PlayerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
    }
}

// MARK: - Feedback

/// The short sign in the middle of the video after a key press or click.
struct PlayerFlash: Equatable {
    let symbol: String
    var text: String? = nil
    let id = UUID()
}

struct PlayerFlashView: View {
    let flash: PlayerFlash
    var body: some View {
        Group {
            if let text = flash.text {
                Label(text, systemImage: flash.symbol)
                    .font(.headline.monospacedDigit())
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.5), in: Capsule())
            } else {
                // Play and pause: a small round sign that's gone in a blink.
                Image(systemName: flash.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 56, height: 56)
                    .background(.black.opacity(0.5), in: Circle())
            }
        }
        .foregroundStyle(.white)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// How long it stays before fading: a blink for play/pause, a little
    /// longer when there's a value to read.
    static func duration(_ flash: PlayerFlash) -> Duration {
        flash.text == nil ? .milliseconds(220) : .milliseconds(500)
    }
}
