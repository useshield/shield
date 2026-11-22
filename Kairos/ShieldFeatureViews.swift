import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Protection

struct ProtectionView: View {
    let model: ShieldViewModel
    @State private var lockingIn = false
    @State private var addingCategory = false
    @State private var addingBlock = false
    @State private var addingSchedule = false
    @State private var importingList = false
    @State private var goingThere = false
    private var presentation: ShieldRulePresentation { ShieldRulePresentation(model: model) }

    /// The next real change: a schedule opening or closing, a block starting
    /// or ending, or a pending change landing. The service's own next tick can
    /// be a clock change or a location refresh, which changes nothing.
    private var nextChange: Date? {
        guard let snapshot = model.backendSnapshot else { return nil }
        let now = Date.now
        let calendar = model.scheduleCalendar
        // Wall-clock times, so the night the clocks change still lands on 2 PM.
        let boundaries = snapshot.committedSchedules.filter(\.isRequested)
            .compactMap { AllowedAccessWindow(blockedSchedule: $0) }
            .flatMap { [$0.startMinutes, $0.endMinutes] }
            .compactMap { target in
                calendar.nextDate(after: now, matching: DateComponents(hour: target / 60 % 24, minute: target % 60),
                                  matchingPolicy: .nextTime)
            }
        let others = snapshot.committedRestrictions.flatMap { [$0.startsAt, $0.endsAt] }.compactMap { $0 } +
            snapshot.pendingReleases.map(\.effectiveAt)
        return (boundaries + others).filter { $0 > now }.min()
    }

    /// Names what the next change does: "X / Reddit blocks at 8 PM".
    private var nextChangeText: String? {
        guard let next = nextChange, let snapshot = model.backendSnapshot else { return nil }
        let calendar = model.scheduleCalendar
        let parts = calendar.dateComponents([.hour, .minute], from: next)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        var opens: [String] = [], blocks: [String] = []
        for schedule in snapshot.committedSchedules where schedule.isRequested {
            guard let window = AllowedAccessWindow(blockedSchedule: schedule) else { continue }
            if window.startMinutes == minute { opens.append(model.displayName(for: schedule.id, title: schedule.title)) }
            if window.endMinutes == minute { blocks.append(model.displayName(for: schedule.id, title: schedule.title)) }
        }
        // A far-off change (a 4-week lock ending) names its day, not "tomorrow".
        let when = calendar.isDateInToday(next) ? ScheduleText.time(minute)
            : calendar.isDateInTomorrow(next) ? ScheduleText.time(minute) + " tomorrow"
            : PlaceDates.short(next, calendar: calendar)
        func names(_ list: [String]) -> String {
            list.count <= 2 ? list.joined(separator: " and ") : "\(list[0]), \(list[1]) and \(list.count - 2) more"
        }
        if !blocks.isEmpty && opens.isEmpty { return "\(names(blocks)) block\(blocks.count == 1 ? "s" : "") at \(when)" }
        if !opens.isEmpty && blocks.isEmpty { return "\(names(opens)) open\(opens.count == 1 ? "s" : "") at \(when)" }
        return "Next change at \(when)"
    }

    private func pendingName(_ id: String) -> String {
        if let schedule = model.backendSnapshot?.committedSchedules.first(where: { $0.id == id }) {
            return model.displayName(for: schedule.id, title: schedule.title)
        }
        if let rule = model.backendSnapshot?.committedRestrictions.first(where: { $0.policyID == id }) {
            return model.displayName(for: rule.policyID, title: rule.title)
        }
        return "Rule"
    }

    private func takeCommand() {
        guard model.command == .newCategory else { return }
        model.command = nil
        // ⌘N: a new category. Blocks and schedules are added inside a category.
        addingCategory = true
    }

    var body: some View {
        // Re-render each minute so the now line and "opens at" text stay current
        // even when the service reports nothing new.
        TimelineView(.everyMinute) { _ in page }
    }

    private var page: some View {
        ShieldBubblePage(maxWidth: 760) {
            ProtectionHero(model: model, presentation: presentation, detail: nextChangeText)

            if PolicyActionNotice(model: model).isVisible ||
                model.submissionRecordError != nil ||
                (model.pendingSubmission != nil && !model.isSubmittingPolicy) {
                VStack(alignment: .leading, spacing: 10) {
                    PolicyActionNotice(model: model)
                    PolicySubmissionRecoveryView(model: model)
                }
                .shieldBubble()
            }

            // Each category's page shows its allowed hours; the rows here say
            // when each one opens.
            if !presentation.pending.isEmpty {
                BubbleSection(title: "Pending changes") {
                    ForEach(presentation.pending) { change in
                        HStack(alignment: .top, spacing: ShieldMetrics.rowSpacing) {
                            RuleKindTile(symbol: "clock.arrow.circlepath", tint: .orange)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(pendingName(change.policyID)).fontWeight(.medium)
                                PendingRuleChangeView(change: change, calendar: model.scheduleCalendar, model: model,
                                                      current: model.backendSnapshot?.committedSchedules
                                                        .first { $0.id == change.policyID })
                            }
                        }
                        .shieldBubble(padding: 14)
                    }
                }
            }

            if !presentation.groups.isEmpty {
                BubbleSection(title: "Categories", footer: model.categoryMessage, footerTint: .orange) {
                    VStack(spacing: 8) {
                        ForEach(presentation.groups) { group in
                            NavigationLink(value: group.id) {
                                CategoryBubble(group: group)
                            }
                            .buttonStyle(BubbleLinkStyle())
                            .accessibilityIdentifier("group-\(group.id)")
                        }
                    }
                }
            } else if model.backendSnapshot != nil {
                ShieldEmptyState(title: "Nothing blocked yet", symbol: "shield.lefthalf.filled",
                                 message: "Pick sites or apps to block, and when.", tint: .green) {
                    Button("New Block…") { addingBlock = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("newBlockFromProtection")
                    Button("New Category…") { addingCategory = true }
                        .accessibilityIdentifier("newCategoryFromProtection")
                    Button("Lock In…") { lockingIn = true }
                }
            }
        }
        .navigationTitle("Protection")
        .toolbar {
            // One blue + for everything you can add; ⋯ for Lock In and Go There.
            AddAndMoreToolbar(add: AddMenuButton(items: [
                AddMenuItem(title: "New Block…", identifier: "newBlockFromToolbar") { addingBlock = true },
                AddMenuItem(title: "New Daily Schedule…", identifier: "newScheduleFromMenu") { addingSchedule = true },
                AddMenuItem(title: "Import Website List…", identifier: "importListFromMenu") { importingList = true },
                AddMenuItem(title: "New Category…", identifier: "addCategory", dividerBefore: true) { addingCategory = true },
            ], help: "Add a block, daily schedule, imported list or category (⌘N for a category)", identifier: "addMenu")) {
                Menu {
                    // Lock In: a time-boxed commitment that can't end early.
                    Button { lockingIn = true } label: { Label("Lock In…", systemImage: "lock") }
                        .accessibilityIdentifier("lockInButton")
                    if model.supportsGoDays {
                        Button { model.requestLocation { goingThere = true } } label: {
                            Label("Go There Today…", systemImage: "figure.walk")
                        }
                        .disabled(!model.canSubmitPolicy)
                        .accessibilityIdentifier("goThereToday")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
                .help("Lock In" + (model.supportsGoDays ? " or Go There Today" : ""))
                .accessibilityLabel("More")
                .accessibilityIdentifier("moreMenu")
            }
        }
        .sheet(isPresented: $lockingIn) { LockInSheet(model: model) }
        .sheet(isPresented: $addingCategory) { CategoryEditor(model: model, existing: nil) }
        .sheet(isPresented: $addingBlock) { BlockEditor(model: model) }
        .sheet(isPresented: $addingSchedule) { NewScheduleEditor(model: model, categoryID: nil) }
        .sheet(isPresented: $importingList) { ImportListEditor(model: model, categoryID: nil) }
        .sheet(isPresented: $goingThere) { GoDayStartSheet(model: model) }
        .onAppear { takeCommand() }
        .onChange(of: model.command) { _, _ in takeCommand() }
    }
}

// MARK: - Settings

struct DiagnosticsView: View {
    let model: ShieldViewModel
    @State private var copyResult: String?
    @State private var showingTechnicalDetails = false
    @State private var showingNetworkVerification = false
    @State private var showingInterruptions = false

    // Green only for the installed service really blocking; previews stay grey.
    private var statusColor: Color {
        if ShieldRuntime.isUIReview { return .secondary }
        if model.isServiceMode, let snapshot = model.backendSnapshot {
            if case .mismatch = model.health.enforcement { return .orange }
            return snapshot.enforcementSource == .installedSystemHosts ? .green : .secondary
        }
        return model.isFixtureMode ? .secondary : .red
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private var serviceSummary: String {
        if ShieldRuntime.isUIReview { return "Sandboxed preview" }
        if model.isServiceMode { return model.backendSnapshot == nil ? "Unavailable" : "Connected" }
        return model.isFixtureMode ? "Local fixture" : "Not connected"
    }

    @AppStorage(ShieldAppearance.key) private var appearance: ShieldAppearance = .system
    @AppStorage(YTDLPRestrictedFetcher.qualityKey) private var downloadQuality = YTDLPRestrictedFetcher.defaultQuality
    private static let interruptionsInfo = "Times Shield's protection stopped while this Mac was awake."
    @State private var choosingSignIn = false
    @State private var confirmingSignInRemoval = false
    @State private var showingClosedTabs = false
    @State private var showingFirstRun = false

    private var downloadsSummary: String {
        if model.containedDownloadsAvailable { return "On" }
        if model.experimentalDownloadsEnabled { return "Experimental · this session" }
        return model.canEnableExperimentalDownloads ? "Off" : "Not in this build"
    }

    static func qualityName(_ height: Int) -> String {
        switch height {
        case 1080: "1080p (Full HD)"
        case 720: "720p (HD)"
        default: "\(height)p"
        }
    }

    var body: some View {
        // It has to read as a settings page. A
        // standard Mac grouped form, like System Settings: three groups, each
        // row a name and its control on the right. Nothing else. no ⓘ
        // where the name says it all; a few names open their explanation
        // when clicked, like a block's websites.
        Form {
            if model.submissionRecordError != nil || (model.pendingSubmission != nil && !model.isSubmittingPolicy) {
                Section { PolicySubmissionRecoveryView(model: model) }
            }

            Section { statusRows }

            Section("General") {
                LabeledContent {
                    Picker("Appearance", selection: Binding(
                        get: { appearance },
                        set: { appearance = $0; $0.apply() })) {
                        ForEach(ShieldAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("appearancePicker")
                } label: {
                    // Plain enough without an ⓘ.
                    Text("Appearance")
                }
                if model.backendSnapshot?.supportsBrowserPolicy == true && !ShieldRuntime.isUIReview {
                    Toggle(isOn: Binding(get: { model.closesBlockedTabs },
                                         set: { $0 ? model.requestClosesBlockedTabs() : model.setClosesBlockedTabs(false) })) {
                        SettingTitle("Close blocked tabs",
                                     info: "When a site becomes blocked, Shield closes its open tabs. Other tabs are left alone.")
                    }
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("closeBlockedTabsToggle")
                    tabsExtras
                }
                if ShieldRuntime.isUIReview {
                    LabeledContent("Preview", value: "Changes and downloads off")
                }
            }

            PermanentWaitSection(model: model)
            ScheduleZoneSection(model: model)
            ShieldUpdateSection()
            if !ShieldRuntime.isUIReview { ShieldChangesSection(model: model) }
            RemoveShieldSection(model: model)

            // The main Shield is a blocker; the Video Library
            // (with downloads) is added here. Its settings show once it's on.
            if !ShieldRuntime.isUIReview {
                Section("Add-ons") {
                    VideoLibraryAddOnRow(model: model)
                    if model.videoLibraryEnabled && downloadsSummary != "Not in this build" {
                        downloadRows
                        LabeledContent {
                            Picker("Video quality", selection: $downloadQuality) {
                                ForEach(YTDLPRestrictedFetcher.qualities, id: \.self) { height in
                                    Text(Self.qualityName(height)).tag(height)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .accessibilityIdentifier("downloadQualityPicker")
                        } label: {
                            Text("Video quality")
                        }
                    }
                }
            }

            Section("Help") {
                LabeledContent {
                    Button("Show") { showingFirstRun = true }
                        .accessibilityIdentifier("showFirstRunSetup")
                } label: {
                    SettingTitle("Welcome tour",
                                 info: "What Shield does, your first block, and the Video Library add-on. Shown when Shield is first opened.")
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        if let copyResult {
                            Text(copyResult).foregroundStyle(.secondary)
                                .accessibilityIdentifier("copyResult")
                        }
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            copyResult = NSPasteboard.general.setString(model.diagnosticReport, forType: .string)
                                ? "Copied" : "Couldn't copy"
                        }
                        .accessibilityIdentifier("copyDiagnosticReport")
                    }
                } label: {
                    ExplainedSettingTitle("Diagnostic report", identifier: "aboutDiagnosticReport",
                                          info: "Copies Shield's status to share for help. Site names, paths and video titles are left out.")
                }
                DisclosureRow(title: "Network check", identifier: "networkVerification",
                              isExpanded: $showingNetworkVerification,
                              info: "Checks a few blocked sites to confirm they can't be reached from this Mac.") {
                    VStack(alignment: .leading, spacing: 8) { networkVerification }.padding(.top, 4)
                }
                if ShieldRuntime.isDevelopment {
                    DisclosureRow(title: "Technical details", identifier: "serviceDetails",
                                  isExpanded: $showingTechnicalDetails,
                                  info: "Development builds only: the service's raw state.") {
                        VStack(alignment: .leading, spacing: 8) { technicalDetails }.padding(.top, 4)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .buttonStyle(ShieldPillButtonStyle())
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(Color.shieldPage)
        .accessibilityIdentifier("pageScrollView")
        .navigationTitle("Settings")
        .sheet(isPresented: $showingFirstRun) { FirstRunSetupView(model: model) }
        .fileImporter(isPresented: $choosingSignIn, allowedContentTypes: [.plainText, .text, .data]) { result in
            if case .success(let url) = result { model.importSignInFile(from: url) }
        }
        .shieldConfirmation(isPresented: $confirmingSignInRemoval) {
            ShieldConfirmation(symbol: "person.crop.circle.badge.minus", tint: .red,
                               title: "Remove the YouTube sign-in?",
                               message: "Downloads may hit YouTube's bot check until you add it again.",
                               confirmTitle: "Remove", destructive: true,
                               confirmIdentifier: "confirmRemoveSignIn") { model.removeSignInFile() }
        }
    }

    /// Is Shield on, when it last checked, and anything waiting on you.
    @ViewBuilder private var statusRows: some View {
        HStack(spacing: 12) {
            RuleKindTile(symbol: statusColor == .green ? "checkmark.shield.fill" : "shield.fill",
                         tint: statusColor == .secondary ? .gray : statusColor, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(serviceSummary).font(.headline)
                        .accessibilityIdentifier("settingsServiceStatus")
                        .accessibilityValue(serviceSummary)
                    InfoHint("Shield's background service keeps your blocks on, even when this window is closed.")
                }
                if let checked = model.lastRefresh {
                    Text("Checked " + checked.formatted(date: .omitted, time: .shortened))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Check Now") { model.refresh() }
                .disabled(model.isSubmittingPolicy)
                .help("Check again (⌘R)")
                .accessibilityIdentifier("refreshEvidence")
        }
        .padding(.vertical, 2)
        if model.isServiceMode && model.backendSnapshot == nil {
            Text("Shield isn't responding. Your blocks are unchanged.").foregroundStyle(.secondary)
        }
        if let snapshot = model.backendSnapshot {
            let committedApps = snapshot.committedRestrictions.reduce(0) { $0 + $1.apps.count } +
                snapshot.committedSchedules.reduce(0) { $0 + $1.apps.count }
            if committedApps > 0 {
                // Only the service's own report says apps are being closed.
                LabeledContent {
                    Text(model.isServiceMode
                         ? snapshot.enforcement.blockedApps.map { "Closing \($0.count) app\($0.count == 1 ? "" : "s") now" }
                            ?? "Not reported"
                         : "Simulated")
                        .accessibilityIdentifier("settingsAppBlocking")
                } label: {
                    SettingTitle("App blocking", info: "Apps you've blocked are closed while their block is on.")
                }
            }
            if !snapshot.pendingReleases.isEmpty {
                LabeledContent {
                    Button("Review") { model.selectedSection = .protection }
                        .accessibilityIdentifier("reviewPendingChanges")
                } label: {
                    Text("\(snapshot.pendingReleases.count) change\(snapshot.pendingReleases.count == 1 ? "" : "s") waiting")
                }
            }
            if !ShieldRuntime.isUIReview && !snapshot.serviceGaps.isEmpty {
                DisclosureRow(title: "Interruptions (\(snapshot.serviceGaps.count))", identifier: "serviceGapToggle",
                              isExpanded: $showingInterruptions, info: Self.interruptionsInfo) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(snapshot.serviceGaps.suffix(10).reversed()) { gap in
                            Label(ServiceGapPresentation.summary(gap, calendar: model.scheduleCalendar),
                                  systemImage: "exclamationmark.shield")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                    .accessibilityIdentifier("serviceGapHistory")
                }
            }
        }
    }

    @ViewBuilder private var tabsExtras: some View {
        if let problem = model.tabClosingProblem {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(problem).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("tabClosingProblem")
                Spacer(minLength: 8)
                if model.tabClosingNeedsPermission {
                    Button("Open System Settings") { Self.openAutomationSettings() }
                        .accessibilityIdentifier("openAutomationSettings")
                }
            }
        }
        if !model.closedTabs.isEmpty {
            DisclosureRow(title: "Recently closed tabs (\(model.closedTabs.count))", identifier: "closedTabs",
                          isExpanded: $showingClosedTabs, info: "Tabs Shield closed, newest first.") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.closedTabs.map { tab in
                        tab.closedAt.formatted(date: .omitted, time: .shortened) + "  " + tab.url
                    }.joined(separator: "\n"))
                        .font(.callout.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Copy Addresses") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.closedTabs.map(\.url).joined(separator: "\n"),
                                                           forType: .string)
                        }
                        Button("Clear List") { model.clearClosedTabs() }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder private var downloadRows: some View {
        if model.canEnableExperimentalDownloads && !model.containedDownloadsAvailable {
            Toggle(isOn: Binding(get: { model.experimentalDownloadsEnabled },
                                 set: { model.setExperimentalDownloadsEnabled($0) })) {
                SettingTitle("Video downloads",
                             info: "Development builds only, until Shield closes. Use only content you're allowed to download.")
            }
            .toggleStyle(.switch)
        } else if downloadsSummary != "On" {
            LabeledContent {
                Text(downloadsSummary)
            } label: {
                SettingTitle("Video downloads", info: "Whether Shield can save the videos you add to Library.")
            }
        }
        LabeledContent {
            if model.signInFilePresent {
                Menu("Added") {
                    Button("Replace…") { choosingSignIn = true }
                        .accessibilityIdentifier("chooseSignInFile")
                    Button("Remove…", role: .destructive) { confirmingSignInRemoval = true }
                }
                .fixedSize()
            } else {
                Button("Choose File…") { choosingSignIn = true }
                    .accessibilityIdentifier("chooseSignInFile")
            }
        } label: {
            ExplainedSettingTitle("YouTube sign-in", identifier: "aboutYouTubeSignIn",
                                  info: "A cookies file from your YouTube account. Used only if YouTube asks to confirm you're not a bot.")
        }
        if let message = model.signInMessage {
            Text(message).font(.callout).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var technicalDetails: some View {
        if let error = model.fixtureReceiptError ?? model.authorityError {
            Text(error).foregroundStyle(.red)
                .accessibilityIdentifier("backendReconciliationErrorDetail")
        }
        if let message = model.backendActionMessage {
            Text(message).foregroundStyle(.secondary)
                .accessibilityIdentifier("backendActionMessage")
                .accessibilityLabel(message).accessibilityValue(message)
        }
        if let state = model.authorityState {
            LabeledContent("Schema", value: String(state.schemaVersion))
            LabeledContent("Generation", value: String(state.generation))
            LabeledContent("Reconciliation ID", value: state.reconciliationID.uuidString)
            LabeledContent("Generated", value: state.generatedAt.formatted(date: .abbreviated, time: .standard))
            LabeledContent("Last successful update", value: state.lastSuccessfulReconciliation.formatted(
                date: .abbreviated, time: .standard))
        } else {
            Text(model.authorityError ?? "Policy state is unavailable.").foregroundStyle(.red)
        }
        if let snapshot = model.backendSnapshot {
            LabeledContent("Committed owners") {
                Text(String(snapshot.committedRestrictions.count)).accessibilityIdentifier("committedOwnerCount")
            }
            LabeledContent("Recurring windows") {
                Text(String(snapshot.committedSchedules.count)).accessibilityIdentifier("recurringWindowCount")
            }
            LabeledContent("Pending releases") {
                Text(String(snapshot.pendingReleases.count)).accessibilityIdentifier("pendingReleaseCount")
            }
            if let next = snapshot.nextTransition {
                LabeledContent("Next transition", value: next.formatted(date: .abbreviated, time: .standard))
            }
        }
        if let receipt = model.fixtureReceipt {
            LabeledContent(model.isServiceMode ? "Service receipt" : "Fixture receipt") {
                Text("Generation \(receipt.payload.generation)").accessibilityIdentifier("receiptGeneration")
            }
            LabeledContent("Receipt applied", value: receipt.payload.appliedAt.formatted(
                date: .abbreviated, time: .standard))
        }
    }

    @ViewBuilder private var networkVerification: some View {
        Text("Browsers and other DNS settings can bypass this check.")
            .foregroundStyle(.secondary)
        switch model.health.enforcement {
        case .verified: EmptyView()
        case .mismatch(let detail), .unavailable(let detail):
            Text(detail).foregroundStyle(.red)
        }
        if ShieldRuntime.isDevelopment {
            LabeledContent("Authority mode", value: model.isServiceMode ? "Signed service" : "Local preview")
            LabeledContent("Observed source", value: model.backendSnapshot?.enforcementSource.rawValue ?? "Unavailable")
        }
        if let observation = model.backendSnapshot?.enforcement.resolution {
            let confirmed = observation.results.filter(\.usesBlockingAddresses).count
            LabeledContent("Blocking check", value: "\(confirmed) of \(observation.results.count) websites blocked")
            Text("A sample of \(observation.totalDomains) blocked websites, checked \(observation.observedAt.formatted(date: .omitted, time: .shortened)).")
                .foregroundStyle(.secondary)
            if let problem = observation.problem { Text(problem).foregroundStyle(.red) }
            ForEach(observation.results.filter { !$0.usesBlockingAddresses }, id: \.domain) { result in
                Text("\(result.domain): \(result.error ?? result.addresses.joined(separator: ", "))")
                    .foregroundStyle(.red)
            }
        }
        if ShieldRuntime.isDevelopment {
            LabeledContent("App storage", value: ShieldRuntime.supportDirectory.path)
            LabeledContent("Service namespace", value: ShieldRuntime.serviceName)
            LabeledContent("External tools", value: ShieldRuntime.allowsExternalTools
                           ? "Disposable fixture test only" : "Disabled")
            ForEach(model.toolVersions.keys.sorted(), id: \.self) { name in
                LabeledContent(name, value: model.toolVersions[name] ?? "Unknown")
            }
        }
        if let last = model.lastRefresh {
            LabeledContent("Last checked", value: last.formatted(date: .omitted, time: .standard))
        }
    }
}

// MARK: - Allowed hours editor

struct PreparedScheduleHoursEditor: View {
    let model: ShieldViewModel
    let schedule: DailySchedule
    @Environment(\.dismiss) private var dismiss
    @State private var start: Int
    @State private var end: Int
    @State private var awaitingRequestID: UUID?
    @State private var submissionProblem: String?
    /// The hours as they were when the editor opened. `schedule` follows the
    /// latest snapshot, so a change made elsewhere meanwhile is noticed.
    @State private var opened: DailySchedule

    init(model: ShieldViewModel, schedule: DailySchedule) {
        self.model = model
        self.schedule = schedule
        _opened = State(initialValue: schedule)
        // Stored start/end are the BLOCKED complement; the editor shows ALLOWED.
        _start = State(initialValue: schedule.endMinutes)
        _end = State(initialValue: schedule.startMinutes)
    }

    private var allowedWindow: AllowedAccessWindow? { AllowedAccessWindow(startMinutes: start, endMinutes: end) }
    private var replacement: DailySchedule? { allowedWindow?.blockedSchedule(basedOn: schedule) }
    private var changedSinceOpening: Bool {
        model.backendSnapshot?.committedSchedules.first(where: { $0.id == schedule.id }) != opened
    }
    private var hasPendingChange: Bool {
        model.backendSnapshot?.pendingReleases.contains(where: { $0.policyID == schedule.id }) == true
    }
    /// Stricter hours apply at once; looser hours wait at least 24 hours.
    private var appliesNow: Bool { replacement.map { $0.isImmediateStrengthening(of: schedule) } ?? false }
    private var outcome: String {
        guard let replacement, replacement != schedule else { return "These are the current hours." }
        if appliesNow { return "Stricter hours apply right away." }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()
        style.timeZone = model.scheduleCalendar.timeZone
        let start = Date.now.addingTimeInterval(LockInPlan.releaseHeadroom).formatted(style)
        return "New hours start \(start) at the earliest. Until then, the current hours stay."
    }
    private var pendingText: String? {
        guard let pending = model.backendSnapshot?.pendingReleases.first(where: { $0.policyID == schedule.id }) else { return nil }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
        style.timeZone = model.scheduleCalendar.timeZone
        return "A change is already pending until " + pending.effectiveAt.formatted(style) + "."
    }
    private func date(_ minutes: Int) -> Date {
        model.scheduleCalendar.date(from: DateComponents(year: 2001, month: 1, day: 15,
            hour: minutes / 60, minute: minutes % 60)) ?? .now
    }
    private func hourBinding(_ value: Binding<Int>) -> Binding<Date> {
        Binding(get: { date(value.wrappedValue) }, set: { time in
            let parts = model.scheduleCalendar.dateComponents([.hour, .minute], from: time)
            value.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorSheetHeader(symbol: "clock.fill", tint: .teal,
                              title: "\(model.displayName(for: schedule.id, title: schedule.title)) hours",
                              subtitle: "")

            Form {
                Section {
                    DatePicker("Allow from", selection: hourBinding($start), displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("allowedStart")
                    DatePicker("Allow until", selection: hourBinding($end), displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("allowedEnd")
                } footer: {
                    if model.scheduleCalendar.timeZone.identifier != TimeZone.current.identifier {
                        Text("Times are \(model.scheduleTimeZoneDescription).")
                    }
                }
                .disabled(awaitingRequestID != nil)

                Section {
                    if let window = allowedWindow {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Allowed " + ScheduleText.short(window)).font(.headline)
                                .accessibilityIdentifier("allowedHoursSummary")
                            AllowedHoursBar(window: window, height: 10)
                            HourAxisLabels()
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text("Start and end must differ.")
                            .foregroundStyle(.orange)
                    }
                } footer: {
                    Text(pendingText ?? outcome)
                }

                if (awaitingRequestID.map { model.submissionState == .unconfirmed($0) } ?? false) ||
                    model.isSubmittingPolicy || (changedSinceOpening && awaitingRequestID == nil) || submissionProblem != nil {
                    Section {
                        if let id = awaitingRequestID, model.submissionState == .unconfirmed(id) {
                            Text("Shield didn't hear back. Check before trying again.")
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Check") { model.refresh() }
                                Button("Try Again") { model.retryPendingSubmission() }.disabled(!model.canRetryPendingSubmission)
                            }
                            .disabled(model.isSubmittingPolicy)
                        }
                        if model.isSubmittingPolicy { ProgressView("Waiting for confirmation…").controlSize(.small) }
                        if changedSinceOpening && awaitingRequestID == nil {
                            Text("These hours changed while the editor was open. Close and reopen to review the latest hours.")
                                .foregroundStyle(.secondary)
                        }
                        if let submissionProblem {
                            Text(submissionProblem).foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.bubble)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("scheduleEditorScroll")
            .disabled(awaitingRequestID != nil && model.isSubmittingPolicy)

            HStack {
                if !model.canSubmitPolicy && awaitingRequestID == nil {
                    Label("Hours can't be changed right now", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(awaitingRequestID == nil ? "Cancel" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancelAllowedHours")
                Button(appliesNow ? "Apply Now" : "Schedule Change") {
                    guard let replacement else { return }
                    submissionProblem = nil
                    awaitingRequestID = model.changeConfirmedHours(scheduleID: schedule.id,
                        start: replacement.startMinutes, end: replacement.endMinutes)
                    if awaitingRequestID == nil { submissionProblem = model.backendActionMessage }
                }
                .buttonStyle(.prominentWhenEnabled)
                .disabled(replacement == nil || replacement == schedule || !model.canSubmitPolicy ||
                          hasPendingChange || changedSinceOpening || awaitingRequestID != nil)
                .accessibilityIdentifier("applyAllowedHours")
            }
            .shieldSheetFooter()
        }
        .frame(width: 440, height: 400)
        .shieldSheet()
        .environment(\.timeZone, model.scheduleCalendar.timeZone)
        .onChange(of: model.submissionState) { _, state in
            guard let id = awaitingRequestID else { return }
            if state == .confirmed(id) { dismiss() }
            else if state == .failed(id) {
                submissionProblem = model.backendActionMessage
                awaitingRequestID = nil
            }
        }
    }
}

// MARK: - Apps in a block or schedule

/// Chosen apps with their icons, Add App… (the real Open panel, reading each
/// app's signature), and why an app can't be blocked when it can't.
struct AppsSection: View {
    @Binding var apps: [AppTarget]
    @State private var picking = false
    @State private var problem: String?

    var body: some View {
        Section {
            ForEach(apps) { app in
                HStack {
                    Label { Text(app.displayName) } icon: { AppIcon(bundleID: app.bundleID) }
                    Spacer()
                    Button { apps.removeAll { $0.id == app.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Don't block \(app.displayName)")
                        .accessibilityLabel("Remove \(app.displayName)")
                }
                .accessibilityIdentifier("blockApp-\(app.bundleID)")
            }
            Button("Add App…") { picking = true }
                .disabled(apps.count >= PolicyValidation.maximumApps)
                .accessibilityIdentifier("blockAddApp")
        } header: {
            Text("Apps")
        } footer: {
            if let problem {
                Text(problem).foregroundStyle(.orange).accessibilityIdentifier("blockAppProblem")
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.applicationBundle],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { add(urls) }
        }
    }

    private func add(_ urls: [URL]) {
        (apps, problem) = Self.adding(urls, to: apps)
    }

    /// The apps after adding the ones picked in the Open panel, and why one
    /// couldn't be added (shared with Go There Today's app chips).
    static func adding(_ urls: [URL], to current: [AppTarget]) -> ([AppTarget], String?) {
        var apps = current
        var problem: String?
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            switch AppTarget.chosen(at: url) {
            case .success(let app): if !apps.contains(where: { $0.id == app.id }) { apps.append(app) }
            case .failure(let reason): problem = reason.message
            }
        }
        if apps.count > PolicyValidation.maximumApps {
            apps = Array(apps.prefix(PolicyValidation.maximumApps))
            problem = "Up to \(PolicyValidation.maximumApps) apps per rule."
        }
        return (apps, problem)
    }
}
