import SwiftUI
import UniformTypeIdentifiers

// First-run setup for a new user (public-release prep): welcome, what
// Shield does, the first block through the existing New Block / New Daily
// Schedule editors, and the optional Video Library add-on. Shown once
// (UserDefaults flag) and again from Settings → Help → Welcome tour.
// Presentation only: every block goes through the same editors, service
// request and 24-hour rule as anywhere else in the app.

enum FirstRunSetup {
    static let seenKey = "Shield.FirstRunSeen"

    enum Step: Int, CaseIterable, Identifiable {
        case welcome, howItWorks, firstBlock, library, done

        var id: Int { rawValue }
        var next: Step? { Step(rawValue: rawValue + 1) }
        var previous: Step? { Step(rawValue: rawValue - 1) }
        var isFirst: Bool { previous == nil }
        var isLast: Bool { next == nil }

        /// For snapshot file names and accessibility identifiers.
        var name: String {
            switch self {
            case .welcome: "welcome"
            case .howItWorks: "how-it-works"
            case .firstBlock: "first-block"
            case .library: "video-library"
            case .done: "done"
            }
        }
    }

    /// Blocks, schedules and waiting changes the user already has.
    static func ruleCount(_ snapshot: BackendSnapshot?) -> Int {
        guard let snapshot else { return 0 }
        return snapshot.committedRestrictions.count + snapshot.committedSchedules.count
    }

    /// Only the shipped app shows the tour by itself. Development, UI Review,
    /// test runs and anything launched with Shield test settings never do, so
    /// tests and previews see the app as before. Settings opens it anywhere.
    static func showsAutomatically(isDevelopment: Bool = ShieldRuntime.isDevelopment,
                                   isUIReview: Bool = ShieldRuntime.isUIReview,
                                   environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if isUIReview || isDevelopment { return false }
        let testKeys = ["XCTestConfigurationFilePath", "XCTestSessionIdentifier", "XCTestBundlePath"]
        if testKeys.contains(where: { environment[$0] != nil }) { return false }
        return !environment.keys.contains { $0.hasPrefix("SHIELD_") }
    }

    /// Called once Shield first hears from its service. True means show the
    /// tour now; the flag is set at the same moment, so it shows only once.
    /// Someone who already has blocks (an upgrade) isn't new: the flag is set
    /// quietly and nothing is shown.
    static func takeAutomaticShow(defaults: UserDefaults = .standard, ruleCount: Int,
                                  automatic: Bool = showsAutomatically()) -> Bool {
        guard automatic, !defaults.bool(forKey: seenKey) else { return false }
        defaults.set(true, forKey: seenKey)
        return ruleCount == 0
    }
}

struct FirstRunSetupView: View {
    let model: ShieldViewModel
    @State private var step: FirstRunSetup.Step
    @State private var addingBlock = false
    @State private var addingSchedule = false
    @State private var addingVideoLibrary = false
    @Environment(\.dismiss) private var dismiss

    init(model: ShieldViewModel, initialStep: FirstRunSetup.Step = .welcome) {
        self.model = model
        _step = State(initialValue: initialStep)
    }

    static let size = CGSize(width: 560, height: 660)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { page }
                    .padding(.horizontal, 28)
                    .padding(.top, 28)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(step)
            }
            .scrollIndicators(.never)
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color.shieldPage)
        .buttonBorderShape(.capsule)
        .accessibilityIdentifier("firstRunSetup")
        .sheet(isPresented: $addingBlock) { BlockEditor(model: model) }
        .sheet(isPresented: $addingSchedule) { NewScheduleEditor(model: model, categoryID: nil) }
        .sheet(isPresented: $addingVideoLibrary) { VideoLibraryAddOnSheet(model: model) }
    }

    // MARK: Pages

    @ViewBuilder private var page: some View {
        switch step {
        case .welcome: welcome
        case .howItWorks: howItWorks
        case .firstBlock: firstBlock
        case .library: library
        case .done: done
        }
    }

    /// The welcome and last pages get the large title; the others a smaller one
    /// so their rows fit without scrolling.
    private func heading(_ symbol: String, tint: Color, title: String, subtitle: String) -> some View {
        let large = step == .welcome || step == .done
        return VStack(alignment: .leading, spacing: large ? 12 : 10) {
            CategoryIcon(symbol: symbol, tint: tint, size: large ? 56 : ShieldMetrics.headerIcon).accessibilityHidden(true)
            Text(title).font(large ? .largeTitle.weight(.semibold) : .title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("firstRunTitle")
            Text(subtitle).font(.title3).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 6)
    }

    /// A rounded row: icon, name, one or two lines.
    private func row(_ symbol: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: ShieldMetrics.rowSpacing) {
            RuleKindTile(symbol: symbol, tint: tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
        }
        .shieldBubble(padding: 12)
    }

    /// A coloured symbol with plain text: coloured text fails contrast.
    private func status(_ text: String, symbol: String, tint: Color, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("shield.lefthalf.filled", tint: .shieldAccent, title: "Welcome to Shield",
                    subtitle: "Shield blocks the websites and apps that pull you away, on the schedule you choose.")
            row("hand.raised.fill", tint: .orange, title: "Built to hold",
                detail: "Blocks are meant to be hard to undo on impulse. Making a block stronger works right away; making one weaker waits.")
            row("lock.shield.fill", tint: .green, title: "Private",
                detail: "No account. Your blocks and schedules stay on this Mac.")
        }
    }

    private var howItWorks: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("questionmark.circle.fill", tint: .indigo, title: "How Shield works",
                    subtitle: "A few things to know before your first block.")
            row(BlockEditor.Kind.untilTurnedOff.symbol, tint: .red, title: "Block websites and apps",
                detail: "Type sites like reddit.com, or pick apps. Shield blocks them on this Mac.")
            row(BlockEditor.Kind.allowedHours.symbol, tint: .blue, title: "Allowed hours",
                detail: "Let a site open only during the hours you choose each day. It's blocked the rest of the time.")
            row(BlockEditor.Kind.forSetTime.symbol, tint: .purple, title: "Set times and permanent blocks",
                detail: "Lock a site for an hour, a week, or for good. Timed ones can't end early. Removing a permanent one waits 3 days, and you can make that longer.")
            row("clock.arrow.circlepath", tint: .orange, title: "Weaker changes wait 24 hours",
                detail: "Removing a site or adding allowed time takes effect after 24 hours, so a weak moment can't undo a block.")
            row("checkmark.shield.fill", tint: .green, title: "Always on",
                detail: "Shield's background service keeps your blocks on, even when this window is closed.")
        }
    }

    private var firstBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("plus", tint: .shieldAccent, title: "Your first block",
                    subtitle: "Start with one site or app. You can add more anytime with + on Protection.")
            Button { addingBlock = true } label: {
                row("nosign", tint: .red, title: "New Block…",
                    detail: "Block websites or apps until you turn them off, for a set time, or permanently.")
            }
            .buttonStyle(BubbleLinkStyle())
            .disabled(model.backendSnapshot == nil)
            .opacity(model.backendSnapshot == nil ? 0.5 : 1)
            .accessibilityIdentifier("firstRunNewBlock")
            Button { addingSchedule = true } label: {
                row("clock.fill", tint: .blue, title: "New Daily Schedule…",
                    detail: "Allow websites only during set hours each day.")
            }
            .buttonStyle(BubbleLinkStyle())
            .disabled(model.backendSnapshot == nil)
            .opacity(model.backendSnapshot == nil ? 0.5 : 1)
            .accessibilityIdentifier("firstRunNewSchedule")
            firstBlockStatus.padding(.horizontal, 4).padding(.top, 4)
        }
    }

    @ViewBuilder private var firstBlockStatus: some View {
        let count = FirstRunSetup.ruleCount(model.backendSnapshot)
        if model.backendSnapshot == nil {
            status("Shield's background service isn't connected yet, so blocks can't be added here. Your Mac is unchanged.",
                   symbol: "exclamationmark.triangle.fill", tint: .orange, identifier: "firstRunServiceMissing")
        } else if count > 0 {
            status("You have \(count) block\(count == 1 ? "" : "s"). Add more anytime from Protection.",
                   symbol: "checkmark.circle.fill", tint: .green, identifier: "firstRunHasBlocks")
        } else {
            Text("Not ready yet? Skip this step and add a block later.")
                .foregroundStyle(.secondary)
        }
    }

    /// The Video Library is an add-on: offered here, off unless added.
    private var library: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("play.rectangle.on.rectangle.fill", tint: .red, title: "Video Library",
                    subtitle: "Optional. Save videos from links and watch them in Shield, even while the site is blocked.")
            if model.videoLibraryEnabled {
                status("Video Library is on. It's in the sidebar.", symbol: "checkmark.circle.fill", tint: .green,
                       identifier: "firstRunVideoLibraryOn")
                    .padding(.horizontal, 4)
            } else {
                Button { addingVideoLibrary = true } label: {
                    row("plus", tint: .red, title: "Add Video Library…",
                        detail: "Uses free tools you install yourself. Only for videos you're allowed to download.")
                }
                .buttonStyle(BubbleLinkStyle())
                .accessibilityIdentifier("firstRunAddVideoLibrary")
                Text("Not now? Add it anytime in Settings → Add-ons.")
                    .foregroundStyle(.secondary).padding(.horizontal, 4)
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading("checkmark.seal.fill", tint: .green, title: "You're all set",
                    subtitle: "Shield is ready. Protection shows what's blocked and when it next changes.")
            row("gearshape.fill", tint: .gray, title: "See this again",
                detail: "Settings → Help → Welcome tour.")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if step.isFirst {
                Button("Skip") { dismiss() }
                    .accessibilityIdentifier("firstRunSkip")
            } else {
                Button("Back") { withAnimation(.snappy(duration: 0.2)) { step = step.previous ?? step } }
                    .accessibilityIdentifier("firstRunBack")
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(FirstRunSetup.Step.allCases) { dot in
                    Circle()
                        .fill(dot == step ? Color.shieldAccent : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(FirstRunSetup.Step.allCases.count)")
            Spacer()
            Button(step.isLast ? "Start Using Shield" : (step == .firstBlock || step == .library ? "Continue" : "Next")) {
                if let next = step.next {
                    withAnimation(.snappy(duration: 0.2)) { step = next }
                } else {
                    model.selectedSection = .protection
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("firstRunNext")
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
