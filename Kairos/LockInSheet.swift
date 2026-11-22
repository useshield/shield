import SwiftUI
import UniformTypeIdentifiers

/// Lock In: websites and apps locked for a set time. Each one is either
/// blocked all day or allowed only at certain hours, and the whole lock ends
/// at one moment. Lives on the Protection page only. Place rules are made on
/// the Places page or with a category's New Block, not here: a lock "Only at Home" next to per-site hours read as a
/// contradiction. Every choice maps onto an existing service rule (see
/// `LockInPlan.plans`), submitted as one atomic request.
struct LockInSheet: View {
    let model: ShieldViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var items: [LockInItem] = []
    @State private var newSite = ""
    @State private var siteProblem: String?
    @State private var pickingApp = false
    @State private var length: LengthChoice = .quick(0)
    @State private var endDate = Date.now.addingTimeInterval(7 * 86_400)
    /// Ticked for what's on screen now; any change clears it.
    @State private var understandsForever = false
    @State private var awaiting: UUID?
    @State private var problem: String?
    @FocusState private var siteFocused: Bool

    enum LengthChoice: Hashable {
        case quick(Int)       // index into LockInPlan.quickLengths
        case untilDate
        case forever
    }

    static let maximumItems = 20

    init(model: ShieldViewModel) {
        self.model = model
    }

    #if DEBUG
    /// Snapshot tests only: open with websites and apps already added.
    init(model: ShieldViewModel, initialItems: [LockInItem]) {
        self.model = model
        _items = State(initialValue: initialItems)
    }
    #endif

    // MARK: Derived

    /// Websites typed but not yet added with Add or Return: nil when the text
    /// isn't a website, empty when there's nothing new. They count as added,
    /// so typing a site and pressing Lock In never drops it.
    private var draftItems: [LockInItem]? {
        if newSite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        guard let parsed = WebsiteListParser.domains(newSite) else { return nil }
        // Typed "www.x.com" is the same site as "x.com": one row per site.
        let known = Set(items.flatMap { item -> [String] in
            if case .website(let domain) = item.target { return Array(WebsiteListParser.withWWW([domain])) }
            return []
        })
        return WebsiteListParser.roots(WebsiteListParser.withWWW(parsed)).sorted()
            .filter { !known.contains($0) }
            .map { LockInItem(target: .website($0)) }
    }

    private var allItems: [LockInItem] { items + (draftItems ?? []) }

    private var hasDailyHours: Bool { allItems.contains { if case .dailyHours = $0.access { true } else { false } } }

    private var planLength: LockInPlan.Length {
        switch length {
        case .quick(let index): LockInPlan.quickLengths[index].length
        case .untilDate: .until(endDate)
        case .forever: .forever
        }
    }

    private var plans: [LockInPlan] { LockInPlan.plans(for: allItems, length: planLength) }

    /// Durations the engine can hold: allowed hours end through a release the
    /// service accepts only a day out, and can't be forever.
    private var lengthChoices: [LengthChoice] {
        let quick = LockInPlan.quickLengths.indices.filter { index in
            guard hasDailyHours, case .lasting(let seconds) = LockInPlan.quickLengths[index].length else { return true }
            return seconds >= 86_400
        }.map(LengthChoice.quick)
        return quick + [.untilDate] + (hasDailyHours ? [] : [.forever])
    }

    private func label(_ choice: LengthChoice) -> String {
        switch choice {
        case .quick(let index): LockInPlan.quickLengths[index].label
        case .untilDate: "Pick a date…"
        case .forever: "Forever"
        }
    }

    private var problemText: String? {
        // Not while typing: "reddit" on the way to "reddit.com" isn't a mistake yet.
        if draftItems == nil && !siteFocused { return "“\(newSite.trimmingCharacters(in: .whitespaces))” isn't a website. Type one like example.com." }
        if allItems.count > Self.maximumItems { return "Up to \(Self.maximumItems) websites and apps in one Lock In." }
        guard !allItems.isEmpty else { return nil }
        return plans.lazy.compactMap { $0.problem(now: .now) }.first
    }

    /// A lock longer than a day that can't be ended early asks first, like Forever.
    /// "1 day" with allowed hours ends 24 h 5 min out (the service's release
    /// minimum), and still counts as a day.
    private var needsAcknowledgement: Bool {
        if length == .forever { return true }
        guard let end = plans.compactMap({ $0.endDate(now: .now) }).max() else { return false }
        return end.timeIntervalSinceNow > max(86_400, LockInPlan.releaseHeadroom) + 60
    }

    private var canLockIn: Bool {
        !allItems.isEmpty && draftItems != nil && problemText == nil && awaiting == nil && model.canSubmitPolicy &&
            (!needsAcknowledgement || understandsForever)
    }

    private var formLocked: Bool {
        guard let awaiting else { return false }
        return model.submissionState != .unconfirmed(awaiting)
    }

    private var unavailableReason: String {
        if ShieldRuntime.isUIReview { return "Preview: nothing is locked from UI Review" }
        if model.backendSnapshot == nil { return "Shield's service isn't connected. See Settings." }
        if model.isSubmittingPolicy || model.pendingSubmission != nil { return "Another change is still being confirmed." }
        return "Locks can't be made right now. See Settings."
    }

    /// What the acknowledgement covers; a change to any of it asks again.
    private var acknowledgedShape: [String] {
        allItems.map { "\($0.name)|\($0.access)" } + ["\(length)", "\(endDate.timeIntervalSince1970)"]
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            EditorSheetHeader(symbol: "hourglass", tint: .cyan, title: "Lock In", subtitle: "")
            ScrollViewReader { scroller in
                Form {
                    itemsSection
                    durationSection
                    EditorSubmissionStatus(model: model, awaiting: awaiting, problem: problem)
                }
                .formStyle(.bubble)
                .scrollContentBackground(.hidden)
                .disabled(formLocked)
                .accessibilityIdentifier("blockEditorScroll")
                .onChange(of: needsAcknowledgement) { _, needed in
                    guard needed else { return }
                    DispatchQueue.main.async {
                        withAnimation { scroller.scrollTo("confirmPermanentBlock", anchor: .center) }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                summary
                HStack {
                    if !model.canSubmitPolicy && awaiting == nil {
                        Label(unavailableReason, systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(awaiting == nil ? "Cancel" : "Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("cancelBlockEditor")
                    // Deliberately not the default button: Return adds a website, never commits.
                    Button("Lock In") { submit() }
                        .buttonStyle(.prominentWhenEnabled)
                        .disabled(!canLockIn)
                        .accessibilityIdentifier("commitFixtureFocus")
                }
            }
            .shieldSheetFooter()
        }
        .frame(width: 560)
        .shieldSheet()
        .frame(minHeight: 400, idealHeight: 500 + CGFloat(min(items.count, 6)) * 40, maxHeight: 780)
        .environment(\.timeZone, model.scheduleCalendar.timeZone)
        .dismissOnConfirmation(model, awaiting: $awaiting, problem: $problem)
        .onAppear { siteFocused = true }
        .onChange(of: lengthChoices) { _, choices in
            guard !choices.contains(length), let first = choices.first else { return }
            // Allowed hours need a day: "1 hour" becomes "1 day", Forever a picked date.
            length = length == .forever ? .untilDate
                : choices.first { if case .quick = $0 { return true } else { return false } } ?? first
        }
        .onChange(of: siteFocused) { _, focused in
            // Leaving the field keeps what was typed as a site.
            if !focused && draftItems?.isEmpty == false { addSite() }
        }
        .onChange(of: acknowledgedShape) { _, _ in
            understandsForever = false
            if awaiting == nil { problem = nil }  // an old refusal no longer describes what's on screen
        }
        .fileImporter(isPresented: $pickingApp, allowedContentTypes: [.applicationBundle],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { addApps(urls) }
        }
    }

    // MARK: Sections

    private var itemsSection: some View {
        Section {
            ForEach($items) { $item in
                LockInItemRow(model: model, item: $item) {
                    items.removeAll { $0.id == item.id }
                }
            }
            HStack {
                TextField("Add a website", text: $newSite, prompt: Text("Type a website, like reddit.com"))
                    .focused($siteFocused)
                    .onSubmit(addSiteAndKeepTyping)
                    .accessibilityLabel("Website to add")
                    .accessibilityIdentifier("focusDomains")
                Button("Add", action: addSiteAndKeepTyping)
                    .disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("lockInAddSite")
            }
            Button("Add App…") { pickingApp = true }
                .accessibilityIdentifier("blockAddApp")
        } header: {
            Text("Websites and apps")
        } footer: {
            if let siteProblem {
                Text(siteProblem).foregroundStyle(.orange)
                    .accessibilityIdentifier("lockInSiteProblem")
            }
        }
    }

    private var durationSection: some View {
        Section {
            Picker("Lock for", selection: $length) {
                ForEach(lengthChoices, id: \.self) { Text(label($0)).tag($0) }
            }
            .accessibilityIdentifier("focusDuration")
            if length == .untilDate {
                // A little past each minimum, so the earliest pick is still valid at submit.
                DatePicker("Until", selection: $endDate,
                           in: Date.now.addingTimeInterval(hasDailyHours ? LockInPlan.releaseHeadroom + 300 : 900)...Date.now
                               .addingTimeInterval(LockInPlan.maximumLength),
                           displayedComponents: [.date, .hourAndMinute])
                    .accessibilityIdentifier("lockInEndDate")
            }
            if needsAcknowledgement {
                Toggle(length == .forever ? model.permanentAcknowledgement
                                          : "I understand this can't be ended early",
                       isOn: $understandsForever)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier(length == .forever ? "confirmPermanentBlock" : "confirmLongLock")
                    .id("confirmPermanentBlock")
            }
        }
    }

    /// Above the buttons: what's wrong, or exactly what will happen and when it ends.
    @ViewBuilder private var summary: some View {
        if let problemText {
            Label(problemText, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).font(.callout)
                .accessibilityIdentifier("lockInProblem")
        } else if draftItems == nil {
            // Still typing: a quiet hint, not a warning, for why Lock In is off.
            Text("Finish typing a website, like example.com.")
                .font(.callout).foregroundStyle(.secondary)
                .accessibilityIdentifier("lockInTypingHint")
        } else if !allItems.isEmpty {
            // Re-read every second so the end shown is the end submitted.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(LockInPlan.summary(for: allItems, plans: plans, now: context.date,
                                        calendar: model.scheduleCalendar,
                                        removalWait: model.permanentRemoval?.currentWait(at: context.date)) ?? "")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("lockInReview")
        }
    }

    // MARK: Actions

    /// Return or Add: the new row lands above the field, which took the
    /// focus away (Nov 15 click-test), so the next site typed went nowhere.
    private func addSiteAndKeepTyping() {
        addSite()
        DispatchQueue.main.async { siteFocused = true }
    }

    private func addSite() {
        siteProblem = nil
        guard let draft = draftItems else {
            siteProblem = "Type a website address like example.com."
            return
        }
        // Refused whole, text kept: nothing typed is ever silently dropped.
        guard items.count + draft.count <= Self.maximumItems else {
            siteProblem = "Up to \(Self.maximumItems) websites and apps in one Lock In. Remove some first."
            return
        }
        items.append(contentsOf: draft)
        newSite = ""
    }

    private func addApps(_ urls: [URL]) {
        siteProblem = nil
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            switch AppTarget.chosen(at: url) {
            case .success(let app):
                guard !items.contains(where: { $0.target == .app(app) }) else { continue }
                guard items.count < Self.maximumItems else {
                    siteProblem = "Up to \(Self.maximumItems) websites and apps in one Lock In. Remove some first."
                    return
                }
                items.append(LockInItem(target: .app(app)))
            case .failure(let reason):
                siteProblem = reason.message
            }
        }
    }

    private func submit() {
        // A typed site counts, even without pressing Add.
        if draftItems?.isEmpty == false { addSite() }
        guard canLockIn else {
            // Never a silent no-op: say why (e.g. a picked date that's now too soon).
            problem = problemText ?? siteProblem ?? "Check the websites and how long to lock them."
            return
        }
        problem = nil
        awaiting = model.lockIn(plans: plans)
        if awaiting == nil { problem = model.backendActionMessage }
    }
}

/// One website or app: its name, what happens to it, and remove.
private struct LockInItemRow: View {
    let model: ShieldViewModel
    @Binding var item: LockInItem
    let onRemove: () -> Void

    private var usesHours: Binding<Bool> {
        Binding(get: { if case .dailyHours = item.access { true } else { false } },
                set: { item.access = $0 ? .dailyHours(AllowedAccessWindow(startMinutes: 18 * 60, endMinutes: 20 * 60)!) : .never })
    }

    private func minutes(_ start: Bool) -> Binding<Int> {
        Binding(get: {
            if case .dailyHours(let window) = item.access { return start ? window.startMinutes : window.endMinutes }
            return start ? 18 * 60 : 20 * 60
        }, set: { value in
            guard case .dailyHours(let window) = item.access else { return }
            let from = start ? value : window.startMinutes, until = start ? window.endMinutes : value
            // A start equal to the end isn't a window; the picker keeps the last valid one.
            if let window = AllowedAccessWindow(startMinutes: from, endMinutes: until) { item.access = .dailyHours(window) }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                switch item.target {
                case .website: Label(item.name, systemImage: "globe")
                case .app(let app): Label { Text(app.displayName) } icon: { AppIcon(bundleID: app.bundleID) }
                }
                Spacer()
                Picker("What happens to \(item.name)", selection: usesHours) {
                    Text("Blocked all day").tag(false)
                    Text("Allowed only at certain hours").tag(true)
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("lockInAccess-\(item.name)")
                Button(action: onRemove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(item.name)")
            }
            if case .dailyHours(let window) = item.access {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 16) {
                        HoursPicker(model: model, title: "Allowed from", minutes: minutes(true))
                            .accessibilityIdentifier("lockInFrom-\(item.name)")
                        HoursPicker(model: model, title: "to", minutes: minutes(false))
                            .accessibilityIdentifier("lockInTo-\(item.name)")
                    }
                    Text("Allowed \(ScheduleText.time(window.startMinutes)) to \(ScheduleText.time(window.endMinutes)) each day. Blocked the rest of the day.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("lockInHours-\(item.name)")
                }
                .font(.callout)
                .padding(.leading, 28)
            }
        }
        // A container, so its menu and hours keep their own identifiers.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("lockInItem-\(item.name)")
    }
}
