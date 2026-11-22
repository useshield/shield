import AppKit
import SwiftUI

// Shared colours: the Library's page and card backgrounds, and a steady
// colour per rule row. Presentation only.

extension Color {
    private static func adaptive(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    /// Behind every page.
    static let shieldPage = adaptive(dark: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.122, alpha: 1),
                                     light: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.969, alpha: 1))
    /// A card on the page.
    static let shieldCard = adaptive(dark: NSColor(srgbRed: 0.157, green: 0.157, blue: 0.173, alpha: 1),
                                     light: .white)
    static let shieldCardBorder = adaptive(dark: NSColor(white: 1, alpha: 0.07), light: NSColor(white: 0, alpha: 0.06))
    /// Shield's one blue: the sidebar's selection colour, which macOS draws
    /// itself. The +, prominent buttons, switches and selections all use it
    ///. Category colours are separate.
    /// Follows the Mac's accent colour setting.
    static let shieldAccent = Color(nsColor: .selectedContentBackgroundColor)
}

/// A steady colour per row, so rows in a category don't all look alike:
/// well-known services get their own colour, everything else one from its name.
enum RowTint {
    private static let palette: [Color] = [.blue, .pink, .orange, .purple, .teal, .indigo, .mint, .cyan, .brown]
    private static let brands: [(String, Color)] = [
        ("youtube", .red), ("netflix", Color(red: 0.70, green: 0.03, blue: 0.08)),
        ("pinterest", Color(red: 0.90, green: 0.0, blue: 0.14)), ("instagram", Color(red: 0.84, green: 0.16, blue: 0.47)),
        ("tiktok", Color(red: 0.0, green: 0.72, blue: 0.78)), ("x.com", Color(white: 0.30)), ("twitter", Color(white: 0.30)),
        ("reddit", Color(red: 1, green: 0.27, blue: 0)), ("tumblr", Color(red: 0.20, green: 0.27, blue: 0.40)),
        ("twitch", .purple), ("facebook", .blue), ("snapchat", .yellow), ("discord", .indigo), ("kick", .green),
    ]

    /// Looks at the first 8 websites alphabetically, picked without sorting
    /// the whole list (category lists can hold thousands).
    static func color(name: String, domains: Set<String>) -> Color {
        var first: [String] = []
        for domain in domains where first.count < 8 || domain < first[first.count - 1] {
            let at = first.firstIndex { domain < $0 } ?? first.count
            first.insert(domain, at: at)
            if first.count > 8 { first.removeLast() }
        }
        return color(name: name, domains: first)
    }

    static func color(name: String, domains: [String]) -> Color {
        let lowered = domains.prefix(8).map { $0.lowercased() }
        for (brand, color) in brands {
            let inDomains = lowered.contains { domain in
                brand.contains(".") ? (domain == brand || domain.hasSuffix("." + brand)) : domain.contains(brand)
            }
            if inDomains || (!brand.contains(".") && name.lowercased().contains(brand)) { return color }
        }
        // Not Swift's per-launch hash: the same name keeps its colour.
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return palette[sum % palette.count]
    }
}

// MARK: - Bubbles: the Library's rounded tiles on every page

enum ShieldBubble {
    static let radius: CGFloat = 18
    static let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
}

extension View {
    /// A rounded tile on the page, like the Library's. A tint washes the tile
    /// with a soft gradient of that colour.
    func shieldBubble(padding: CGFloat = 16, tint: Color? = nil) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    ShieldBubble.shape.fill(Color.shieldCard)
                    if let tint {
                        ShieldBubble.shape.fill(LinearGradient(colors: [tint.opacity(0.24), tint.opacity(0.05)],
                                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                }
            }
            .overlay(ShieldBubble.shape.strokeBorder(Color.shieldCardBorder))
    }
}

/// A scrolling page of bubbles on the Library's background, centred at a
/// readable width. The window's toolbar carries the page title.
struct ShieldBubblePage<Content: View>: View {
    var maxWidth: CGFloat = 900
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) { content }
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 36)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                // Inside the scroll view, so the window's toolbar keeps its own buttons.
                .buttonStyle(ShieldPillButtonStyle())
        }
        .background(Color.shieldPage)
        .scrollIndicators(.never)
        .buttonBorderShape(.capsule)
        .modifier(HardTopEdge())
        .accessibilityIdentifier("pageScrollView")
    }
}

/// Keeps the title crisp when rows scroll under the glass toolbar.
struct HardTopEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.scrollEdgeEffectStyle(.hard, for: .top) } else { content }
    }
}

/// A heading over bubbles, as on the Library's front page.
struct BubbleSection<Content: View>: View {
    let title: String?
    var footer: String? = nil
    var footerTint: Color? = nil
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if let title {
                Text(title).font(.headline).padding(.horizontal, 4).accessibilityAddTraits(.isHeader)
            }
            content
            if let footer, !footer.isEmpty {
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(footerTint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A whole bubble you click to open: lifts a little under the pointer.
struct BubbleLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BubbleLinkBody(configuration: configuration)
    }

    private struct BubbleLinkBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        var body: some View {
            configuration.label
                .contentShape(ShieldBubble.shape)
                .overlay(ShieldBubble.shape.fill(Color.primary.opacity(hovering ? 0.04 : 0)).allowsHitTesting(false))
                .shadow(color: .black.opacity(hovering ? 0.16 : 0), radius: 8, y: 3)
                .scaleEffect(configuration.isPressed ? 0.985 : (hovering ? 1.005 : 1))
                // The lift goes the moment the pointer leaves.
                .animation(.easeOut(duration: hovering ? 0.12 : 0.07), value: hovering)
                .animation(.snappy(duration: 0.12), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// One category on the Protection page: its icon and name. What each rule
/// inside is doing shows on the category's own page.
struct CategoryBubble: View {
    let group: ShieldRuleGroup

    var body: some View {
        HStack(spacing: 14) {
            CategoryIcon(group.category, size: 36)
            Text(group.title).font(.body.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .shieldBubble(padding: 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.title)
        .accessibilityHint("Shows the rules in this group")
    }
}

// MARK: - The blue +

/// One thing the blue + can add.
struct AddMenuItem {
    let title: String
    let identifier: String
    var dividerBefore = false
    var enabled = true
    let action: () -> Void
}

/// The filled blue + in a page's toolbar. It's a button, not a SwiftUI Menu:
/// a toolbar Menu won't fill with colour on macOS 26. Clicking it opens a
/// native menu of what you can add.
struct AddMenuButton: View {
    let items: [AddMenuItem]
    let help: String
    let identifier: String

    var body: some View {
        // Drawn by hand: the toolbar strips the fill from prominent button
        // styles, so a styled button showed as a plain white +.
        // One item: the + does it straight away, no one-line menu.
        Button {
            if items.count == 1 { items[0].action() } else { AddMenuPopup.show(items) }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.shieldAccent))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(items.count == 1 && !items[0].enabled)
        .opacity(items.count == 1 && !items[0].enabled ? 0.45 : 1)
        .help(help)
        .accessibilityLabel("Add")
        .accessibilityIdentifier(identifier)
    }
}

@MainActor
private final class AddMenuPopup: NSObject {
    /// Menu items hold their target weakly; keep the open menu's target alive.
    private static var current: AddMenuPopup?
    private let actions: [() -> Void]

    private init(actions: [() -> Void]) { self.actions = actions }

    @objc private func run(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }

    static func show(_ items: [AddMenuItem]) {
        let target = AddMenuPopup(actions: items.map(\.action))
        current = target
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, item) in items.enumerated() {
            if item.dividerBefore && index > 0 { menu.addItem(.separator()) }
            let entry = NSMenuItem(title: item.title, action: #selector(run(_:)), keyEquivalent: "")
            entry.target = target
            entry.tag = index
            entry.isEnabled = item.enabled
            entry.identifier = NSUserInterfaceItemIdentifier(item.identifier)
            entry.setAccessibilityIdentifier(item.identifier)
            menu.addItem(entry)
        }
        // As a context menu of the window, under the click: a menu popped up
        // with no view never showed to accessibility, so VoiceOver
        // and the click-tests couldn't reach a single + item.
        if let event = NSApp.currentEvent, [.leftMouseUp, .leftMouseDown].contains(event.type),
           let view = event.window?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        } else if let view = NSApp.keyWindow?.contentView, let window = view.window {
            // Keyboard or VoiceOver press: still in the window, at the pointer.
            let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            menu.popUp(positioning: nil, at: point, in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

/// The blue + and, a little apart from it, the ⋯ menu.
struct AddAndMoreToolbar<More: View>: ToolbarContent {
    let add: AddMenuButton
    @ViewBuilder var more: () -> More

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) { add }
                .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) { more() }
        } else {
            ToolbarItem(placement: .primaryAction) { add }
            ToolbarItem(placement: .primaryAction) { more() }
        }
    }
}

// MARK: - Sheets: the same soft look as the pages

extension View {
    /// A sheet on the page background, with rounded (capsule) buttons.
    func shieldSheet() -> some View {
        self.background(Color.shieldPage)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .buttonBorderShape(.capsule)
            .buttonStyle(ShieldPillButtonStyle())
    }

    /// The Cancel / Save row at the bottom of a sheet: larger, rounder buttons.
    func shieldSheetFooter() -> some View {
        self.controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
    }
}

/// One choice as a small capsule with its symbol inline (New Block's kinds
/// and lengths). The big tiles made the sheet scroll.
/// Light or dark for Shield alone (Settings ▸ Appearance), or follow the Mac.
/// Saved per user; nothing else on the Mac changes.
enum ShieldAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "Shield.Appearance"
    var id: Self { self }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
    static var saved: ShieldAppearance {
        UserDefaults.standard.string(forKey: key).flatMap(ShieldAppearance.init(rawValue:)) ?? .system
    }

    @MainActor func apply() { NSApp.appearance = appearance }

    /// At launch. Screenshot and test runs set their own appearance.
    @MainActor static func applySaved() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SHIELD_VISUAL_APPEARANCE"] == nil,
              environment["XCTestConfigurationFilePath"] == nil else { return }
        saved.apply()
    }
}

/// The one empty page design (The old boxed card looked off
/// centre and dated). A soft tinted icon, a short title, at most one line,
/// and the next step as a button, centred in the space it's given.
struct ShieldEmptyState<Actions: View>: View {
    let title: String
    let symbol: String
    var message: String? = nil
    var messageIdentifier: String? = nil
    var tint: Color = .shieldAccent
    /// Fill the page and centre vertically (pages without other content).
    var fillsPage = false
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 72, height: 72)
                .background(Circle().fill(tint.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(messageIdentifier ?? "")
                }
            }
            .frame(maxWidth: 380)
            HStack(spacing: 10) { actions }
                .controlSize(.large)
                .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, fillsPage ? 24 : 44)
        .frame(maxWidth: .infinity, maxHeight: fillsPage ? .infinity : nil)
        .accessibilityElement(children: .contain)
    }
}

extension ShieldEmptyState where Actions == EmptyView {
    init(title: String, symbol: String, message: String? = nil, tint: Color = .shieldAccent, fillsPage: Bool = false) {
        self.init(title: title, symbol: symbol, message: message, tint: tint, fillsPage: fillsPage) { EmptyView() }
    }
}

struct ChoiceChip: View {
    let title: String
    var symbol: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1)
            }
            .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(selected ? AnyShapeStyle(Color.shieldAccent) : AnyShapeStyle(Color.primary.opacity(0.07)),
                        in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Lays chips out left to right, wrapping onto the next line when full.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// A rounded card of rows with thin lines between them, as in the Settings
/// draft. Each top-level view inside is one row.
struct BubbleCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows.indices, id: \.self) { index in
                    if index > 0 { Divider().opacity(0.6) }
                    rows[index]
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.shieldCard, in: ShieldBubble.shape)
        .overlay(ShieldBubble.shape.strokeBorder(Color.shieldCardBorder))
        .labeledContentStyle(BubbleLabeledContentStyle())
    }
}

/// "Label ……… value" inside a card.
struct BubbleLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label
            Spacer(minLength: 12)
            configuration.content
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - Bubble forms

/// Sheets' forms as rounded cards on the page colour, the same look as the
/// pages: each Section is a card with its heading above and note below.
struct BubbleFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(sections: configuration.content) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        if !section.header.isEmpty {
                            section.header
                                .font(.headline)
                                .padding(.horizontal, 4)
                                .accessibilityAddTraits(.isHeader)
                        }
                        if !section.content.isEmpty {
                            BubbleCard { section.content }
                        }
                        if !section.footer.isEmpty {
                            section.footer
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 4)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textFieldStyle(.roundedBorder)
    }
}

extension FormStyle where Self == BubbleFormStyle {
    static var bubble: BubbleFormStyle { BubbleFormStyle() }
}

// MARK: - Edit button

extension View {
    /// The small "Edit" capsule on schedule and block rows: a native menu
    /// button, quiet until pointed at.
    func ruleEditMenuStyle() -> some View {
        self.menuStyle(.button)
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

// MARK: - Buttons that look like buttons

/// The everyday button on Shield's pages and sheets. "Keep
/// Current Rules", "Not Now", "Check Now" read as faint blue text on the dark
/// bubbles, and you couldn't tell they were buttons. A filled pill with a
/// clear label that answers the pointer. Filled primary actions keep
/// `.borderedProminent`; rows and icons keep their own plain styles.
struct ShieldPillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration)
    }

    private struct PillBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @State private var hovering = false

        private var fill: Double {
            if configuration.isPressed { return 0.24 }
            return hovering && isEnabled ? 0.17 : 0.11
        }

        var body: some View {
            let small = controlSize == .small || controlSize == .mini
            let large = controlSize == .large || controlSize == .extraLarge
            let destructive = configuration.role == .destructive
            configuration.label
                .font(small ? .callout.weight(.medium) : .body.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                .padding(.horizontal, small ? 11 : (large ? 18 : 14))
                .padding(.vertical, small ? 4 : (large ? 7 : 5))
                .background(Capsule().fill(Color.primary.opacity(fill)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.13)))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: hovering)
        }
    }
}

// MARK: - Page notices

/// A page's own notice (Library's "couldn't download", "index needs repair"),
/// handed up to the window so it shows as a banner with the others (`ShieldBanner`).
struct PageNotice: Equatable {
    let bar: NoticeBar
    /// Changes whenever what it says or offers changes.
    var id: String { bar.id }
    static func == (a: PageNotice, b: PageNotice) -> Bool { a.id == b.id }
}

struct PageNoticeKey: PreferenceKey {
    static let defaultValue: [PageNotice] = []
    static func reduce(value: inout [PageNotice], nextValue: () -> [PageNotice]) { value += nextValue() }
}
