import AppKit
import SwiftUI

// Presentation-only building blocks for the native redesign. Nothing here
// reads or writes policy; callers pass already-derived, truthful values.

extension ShieldGroupKind {
    /// Category identity colour for the rounded-square icon. Deliberately not
    /// green, amber or red, which are reserved for protection status.
    var tint: Color {
        switch self {
        case .social: return .blue
        case .video: return .pink
        case .adult: return .indigo
        case .food: return .teal
        case .custom: return .gray
        case .location: return .purple
        case .other: return .gray
        }
    }

    var iconSymbol: String {
        switch self {
        case .social: return "bubble.left.and.bubble.right.fill"
        case .video: return "play.rectangle.fill"
        case .adult: return "hand.raised.fill"
        case .food: return "fork.knife"
        case .custom: return "lock.fill"
        case .location: return "mappin.and.ellipse"
        case .other: return "square.stack.fill"
        }
    }
}

extension ShieldCategoryColor {
    var color: Color {
        switch self {
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .brown: .brown
        case .gray: .gray
        }
    }
}

/// System Settings–style rounded-square symbol.
struct CategoryIcon: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 24

    init(_ kind: ShieldGroupKind, size: CGFloat = 24) {
        self.symbol = kind.iconSymbol
        self.tint = kind.tint
        self.size = size
    }

    init(_ category: ShieldCategory, size: CGFloat = 24) {
        self.symbol = category.symbol
        self.tint = category.color.color
        self.size = size
    }

    init(symbol: String, tint: Color, size: CGFloat = 24) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Compact trailing status: a small dot (or lock) and secondary text.
struct StatusLabel: View {
    let status: ShieldRuleStatus
    var body: some View {
        HStack(spacing: 5) {
            if status == .permanent {
                Image(systemName: "lock.fill").font(.caption2)
            } else {
                Circle().fill(status.tint).frame(width: 6, height: 6)
            }
            Text(status.title)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.title)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// ⌘[ Back for drill-downs: SwiftUI's toolbar back button has no shortcut.
struct NavigateBackKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var navigateBack: (() -> Void)? {
        get { self[NavigateBackKey.self] }
        set { self[NavigateBackKey.self] = newValue }
    }
}

struct ShieldModelKey: FocusedValueKey { typealias Value = ShieldViewModel }
extension FocusedValues {
    var shieldModel: ShieldViewModel? {
        get { self[ShieldModelKey.self] }
        set { self[ShieldModelKey.self] = newValue }
    }
}

/// App-wide commands; pages open their sheets when they see the request.
enum ShieldCommand: Equatable { case newCategory, addVideos }

struct ShieldNavigationCommands: Commands {
    @FocusedValue(\.navigateBack) private var navigateBack
    @FocusedValue(\.shieldModel) private var model
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Category…") {
                model?.selectedSection = .protection
                model?.command = .newCategory
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(model == nil)  // the sheet itself says when locks can't be made
            Button("Add Videos…") {
                model?.selectedSection = .studyLibrary
                model?.command = .addVideos
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(model?.canAddVideoLinks != true || model?.videoLibraryEnabled != true)
        }
        CommandGroup(after: .sidebar) {
            Button("Back") { navigateBack?() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(navigateBack == nil)
            Button("Refresh") { model?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model == nil || model?.isSubmittingPolicy == true)
        }
    }
}

/// A disclosure row whose whole title is a button: a larger target than the
/// chevron alone, with a press action for VoiceOver and keyboard users.
struct DisclosureRow<Content: View>: View {
    let title: String
    let identifier: String
    @Binding var isExpanded: Bool
    /// A short explanation shown by an ⓘ beside the title on hover.
    var info: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded, content: content) {
            HStack(spacing: 6) {
                Button(title) { withAnimation(.snappy) { isExpanded.toggle() } }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(identifier)
                if let info { InfoHint(info) }
            }
        }
    }
}

/// A small ⓘ that explains one setting in a short line when the pointer
/// rests on it.
/// The hint is a light floating bubble that appears at once and fades in
/// quickly; a popover was slow and jumpy, and the system tooltip waits.
struct InfoHint: View {
    let text: String
    @State private var hovering = false
    @State private var token = UUID()

    init(_ text: String) { self.text = text }

    var body: some View {
        Image(systemName: "info.circle")
            .font(.callout)
            .foregroundStyle(hovering ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
            .contentShape(Rectangle().inset(by: -4))
            .onHover { inside in
                hovering = inside
                if inside { HintBubblePanel.shared.show(text, for: token) } else { HintBubblePanel.shared.hide(for: token) }
            }
            .onDisappear {
                hovering = false
                HintBubblePanel.shared.hide(for: token)
            }
            .accessibilityLabel("About")
            .accessibilityValue(text)
    }
}

/// One borderless, click-through panel reused by every ⓘ, so a hint is never
/// clipped by its row and costs nothing to show. It is placed from the
/// pointer's own screen position (Placing it from the row's
/// layout put every hint far below its ⓘ inside the Settings form).
@MainActor final class HintBubblePanel {
    static let shared = HintBubblePanel()
    private var owner: UUID?

    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }()

    func show(_ text: String, for token: UUID) {
        owner = token
        let host = NSHostingController(rootView: HintBubble(text: text))
        // Every hint showed far below its ⓘ. With its default
        // sizing the controller stretched the panel to ~600 pt tall (top kept)
        // right after it was placed, drawing the bubble at the bottom.
        // Measured with a standalone probe; with no sizing it stays put.
        host.sizingOptions = []
        let size = host.sizeThatFits(in: CGSize(width: 264, height: 600))
        host.view.frame = CGRect(origin: .zero, size: size)
        panel.appearance = (NSApp.keyWindow ?? NSApp.mainWindow)?.effectiveAppearance ?? NSApp.effectiveAppearance
        panel.contentViewController = host
        let frame = Self.frame(size: size, pointer: NSEvent.mouseLocation,
                               screen: NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }?.visibleFrame)
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 1
        }
    }

    func hide(for token: UUID) {
        guard owner == token else { return }
        owner = nil
        panel.orderOut(nil)
    }

    /// Just below and centred on the pointer (above it near the bottom of
    /// the screen), kept fully on screen. Screen coordinates, origin bottom-left.
    nonisolated static func frame(size: CGSize, pointer: CGPoint, screen: CGRect?) -> CGRect {
        var origin = CGPoint(x: pointer.x - size.width / 2, y: pointer.y - size.height - 16)
        if let screen {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            if origin.y < screen.minY + 8 { origin.y = pointer.y + 12 }
        }
        return CGRect(origin: origin, size: size)
    }
}

private struct HintBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}

/// A settings row's name with its ⓘ beside it.
struct SettingTitle: View {
    let title: String
    let info: String

    init(_ title: String, info: String) {
        self.title = title
        self.info = info
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            InfoHint(info)
        }
    }
}

/// A setting's name that shows what it does when clicked and hides it on the
/// next click, the way a block's row shows its websites.
/// Replaces the ⓘ on rows whose name alone isn't enough.
struct ExplainedSettingTitle: View {
    let title: String
    let identifier: String
    let info: String
    @State private var showing = false

    init(_ title: String, identifier: String, info: String) {
        self.title = title
        self.identifier = identifier
        self.info = info
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { withAnimation(.snappy(duration: 0.22)) { showing.toggle() } } label: {
                // Drawn like the Settings disclosure rows' own arrow.
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 12)
                        .rotationEffect(.degrees(showing ? 90 : 0))
                    Text(title)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(showing ? "Hide what this does" : "What this does")
            .accessibilityLabel(title)
            .accessibilityValue(showing ? info : "")
            .accessibilityHint("Shows or hides what this does")
            .accessibilityIdentifier(identifier)
            if showing {
                Text(info)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 16)
                    .transition(.opacity)
                    .accessibilityIdentifier(identifier + "Text")
            }
        }
    }
}

/// One set of sizes for every page, so rows and headers line up everywhere.
enum ShieldMetrics {
    /// The rounded icon at the start of every row.
    static let rowIcon: CGFloat = 32
    static let rowSpacing: CGFloat = 12
    /// Where a row's text starts: details under a row line up with its name.
    static let detailIndent: CGFloat = rowIcon + rowSpacing
    /// The icon beside a page's or sheet's title.
    static let headerIcon: CGFloat = 44
    static let sheetIcon: CGFloat = 34
}

/// What kind of block a row is, in the same rounded style as category icons.
struct RuleKindTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = ShieldMetrics.rowIcon

    var body: some View { CategoryIcon(symbol: symbol, tint: tint, size: size) }
}

/// A page's own heading inside its form: a large icon, the name, one line.
struct PageHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            // Decorative: the title says it. Kept out of the text element so
            // its white-on-colour glyph isn't read as low-contrast text.
            CategoryIcon(symbol: symbol, tint: tint, size: ShieldMetrics.headerIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold)).lineLimit(2)
                if !subtitle.isEmpty {
                    // Darker than .secondary: grey on a tinted header failed contrast (audit).
                    Text(subtitle).foregroundStyle(.primary.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

/// A 24-hour bar that highlights the ALLOWED window (never the stored blocked
/// complement). Optional tick labels and a "now" marker.
struct AllowedHoursBar: View {
    let window: AllowedAccessWindow?
    var nowMinutes: Int?
    var height: CGFloat = 8

    private var segments: [(start: Int, length: Int)] {
        guard let window else { return [] }
        if window.endMinutes > window.startMinutes {
            return [(window.startMinutes, window.endMinutes - window.startMinutes)]
        }
        // Ending exactly at midnight is one piece, not a sliver at 12 AM.
        return [(window.startMinutes, 1440 - window.startMinutes), (0, window.endMinutes)].filter { $0.1 > 0 }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.09))
                ForEach([360, 720, 1080], id: \.self) { minute in
                    Rectangle().fill(Color.primary.opacity(0.10))
                        .frame(width: 1)
                        .offset(x: width * CGFloat(minute) / 1440)
                }
                ForEach(segments.indices, id: \.self) { index in
                    let segment = segments[index]
                    Rectangle().fill(Color.shieldAccent.gradient)
                        .frame(width: max(2, width * CGFloat(segment.length) / 1440))
                        .offset(x: width * CGFloat(segment.start) / 1440)
                }
            }
            .clipShape(Capsule())
            .overlay(alignment: .leading) {
                if let nowMinutes {
                    Capsule().fill(Color.primary.opacity(0.45))
                        .frame(width: 2, height: height + 8)
                        .offset(x: width * CGFloat(nowMinutes) / 1440 - 1)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// Hour labels aligned with `AllowedHoursBar`.
struct HourAxisLabels: View {
    private let marks: [(Int, String)] = [(0, "12 AM"), (360, "6 AM"), (720, "12 PM"), (1080, "6 PM"), (1440, "12 AM")]
    var body: some View {
        GeometryReader { proxy in
            ForEach(marks, id: \.0) { minute, label in
                let x = proxy.size.width * CGFloat(minute) / 1440
                Text(label)
                    .fixedSize()
                    .frame(width: 60, alignment: minute == 0 ? .leading : (minute == 1440 ? .trailing : .center))
                    .position(x: minute == 0 ? x + 30 : (minute == 1440 ? x - 30 : x), y: 6)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

/// Prominent only while actionable. A disabled filled button still reads as
/// enabled in Dark Mode, so unavailable primary actions fall back to a dimmed pill.
struct ProminentWhenEnabledStyle: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        if isEnabled {
            Button(configuration).buttonStyle(.borderedProminent)
        } else {
            Button(configuration).buttonStyle(ShieldPillButtonStyle())
        }
    }
}

extension PrimitiveButtonStyle where Self == ProminentWhenEnabledStyle {
    static var prominentWhenEnabled: ProminentWhenEnabledStyle { ProminentWhenEnabledStyle() }
}

extension ShieldViewModel {
    /// Current wall-clock minute in the schedule's own time zone.
    var scheduleNowMinutes: Int {
        let parts = scheduleCalendar.dateComponents([.hour, .minute], from: .now)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    var scheduleTimeZoneDescription: String {
        let zone = scheduleCalendar.timeZone
        let name = zone.localizedName(for: .generic, locale: .current) ?? zone.identifier
        return "\(name) (\(zone.identifier.replacingOccurrences(of: "_", with: " ")))"
    }
}

/// Subtle, always-visible statement of what this build is connected to.
struct RuntimeModeFooter: View {
    let model: ShieldViewModel

    var body: some View {
        #if DEBUG
        if !MarketingRender.isActive { footer }
        #endif
    }

    #if DEBUG
    private var footer: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ShieldRuntime.isUIReview ? "eye" : "hammer")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(ShieldRuntime.isUIReview ? "UI Review" : "Development")
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier(ShieldRuntime.isUIReview ? "reviewModeText" : "developmentModeText")
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("developmentBanner")
    }
    #endif

    private var detail: String {
        if ShieldRuntime.isUIReview { return "Sandboxed preview. Nothing on this Mac changes." }
        if model.isServiceMode {
            if model.backendSnapshot == nil { return "Service unavailable. Local library only." }
            return model.isPrivilegedDevelopmentMode ? "Disposable system-hosts test." : "Fixture rules only. No production changes."
        }
        return "Simulated rules only. No production changes."
    }
}
