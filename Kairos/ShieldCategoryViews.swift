import SwiftUI

// Editors for owner categories and for the websites and schedules inside them.
// Category edits are presentation only. Website and schedule edits are sent to
// the service: more blocking applies at once, less blocking waits 24 hours.

/// Parses "a.com, www.a.com" (commas or new lines) into exact domains.
enum WebsiteListParser {
    static func domains(_ text: String, limit: Int = 20) -> Set<String>? {
        let parts = text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
            .map { part -> String in
                var value = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                // Accept a pasted address: keep only the host.
                if let url = URL(string: value), let host = url.host(), value.contains("://") { value = host }
                return value
            }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty, parts.count <= limit, parts.allSatisfy(PolicyValidation.validDomain) else { return nil }
        return Set(parts)
    }

    /// Country endings that work like .com (bbc.co.uk is a whole site, like
    /// bbc.com), so their sites get a www. twin too.
    static let secondLevelEndings: Set<String> = [
        "co.uk", "org.uk", "me.uk", "ac.uk", "gov.uk", "ltd.uk", "plc.uk", "net.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "co.nz", "net.nz", "org.nz",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "co.kr", "or.kr", "com.cn", "net.cn", "org.cn",
        "com.hk", "com.tw", "com.sg", "com.my", "co.id", "com.ph", "com.vn", "co.in", "net.in", "org.in",
        "com.pk", "co.il", "com.tr", "com.sa", "com.eg", "co.za", "org.za", "com.ng", "co.ke",
        "com.br", "net.br", "org.br", "com.mx", "org.mx", "com.ar", "com.co", "com.pe", "com.ua", "com.pl",
    ]

    /// A whole website (example.com, bbc.co.uk), not a part of one (i.redd.it).
    static func isSiteRoot(_ domain: String) -> Bool {
        let labels = domain.split(separator: ".")
        if labels.count == 2 { return true }
        return labels.count == 3 && secondLevelEndings.contains(labels.suffix(2).joined(separator: "."))
    }

    /// Pairs whole websites with their www. twin (example.com ↔ www.example.com,
    /// bbc.co.uk ↔ www.bbc.co.uk), the same way the prepared plan expands its lists.
    static func withWWW(_ domains: Set<String>) -> Set<String> {
        // www. aliases only for whole websites; never www.i.redd.it and the like.
        domains.reduce(into: Set<String>()) { result, domain in
            result.insert(domain)
            if isSiteRoot(domain) { result.insert("www." + domain) }
            // A pasted www.example.com also blocks example.com (blocking is exact-host).
            if domain.hasPrefix("www."), isSiteRoot(String(domain.dropFirst(4))) { result.insert(String(domain.dropFirst(4))) }
        }
    }

    /// The websites as the user typed them: a www. twin isn't counted twice.
    static func roots(_ domains: Set<String>) -> [String] {
        domains.filter { !$0.hasPrefix("www.") || !domains.contains(String($0.dropFirst(4))) }.sorted()
    }

    /// "3 websites", counting each www. twin with its root.
    static func count(_ domains: Set<String>) -> String {
        // Counted without building or sorting the list.
        let count = domains.reduce(0) { total, domain in
            total + (!domain.hasPrefix("www.") || !domains.contains(String(domain.dropFirst(4))) ? 1 : 0)
        }
        return "\(count) website\(count == 1 ? "" : "s")"
    }

    /// "tumblr.com" or "tumblr.com + 2 more": names a block by what it blocks.
    static func title(for domains: Set<String>) -> String {
        let roots = roots(domains)
        guard let first = roots.first else { return "Block" }
        return roots.count == 1 ? first : "\(first) + \(roots.count - 1) more"
    }
}

/// Dismisses an editor once the service confirms its request, and reports a failure.
private struct ConfirmationDismissal: ViewModifier {
    let model: ShieldViewModel
    @Binding var awaiting: UUID?
    @Binding var problem: String?
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.onChange(of: model.submissionState) { _, state in
            guard let id = awaiting else { return }
            if state == .confirmed(id) { dismiss() }
            else if state == .failed(id) {
                problem = model.backendActionMessage
                awaiting = nil
            }
        }
    }
}

extension View {
    func dismissOnConfirmation(_ model: ShieldViewModel, awaiting: Binding<UUID?>,
                                           problem: Binding<String?>) -> some View {
        modifier(ConfirmationDismissal(model: model, awaiting: awaiting, problem: problem))
    }
}

/// Header shared by the editor sheets.
struct EditorSheetHeader: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String
    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(symbol: symbol, tint: tint, size: ShieldMetrics.sheetIcon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                if !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 4)
    }
}

/// Request progress and problems inside an editor form.
struct EditorSubmissionStatus: View {
    let model: ShieldViewModel
    let awaiting: UUID?
    let problem: String?
    var body: some View {
        if let id = awaiting, model.submissionState == .unconfirmed(id) {
            Section {
                Text("Shield didn't hear back. Check before trying again.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Check") { model.refresh() }
                    Button("Try Again") { model.retryPendingSubmission() }.disabled(!model.canRetryPendingSubmission)
                }
                .disabled(model.isSubmittingPolicy)
            }
        } else if model.isSubmittingPolicy && awaiting != nil {
            Section { ProgressView("Waiting for confirmation…").controlSize(.small) }
        }
        if let problem {
            Section { Text(problem).foregroundStyle(.red) }
        }
    }
}

// MARK: - Category editor

/// The colour choices shared by every editor with an icon (categories, places).
struct ColorSwatches: View {
    @Binding var selection: ShieldCategoryColor
    let identifierPrefix: String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(ShieldCategoryColor.allCases, id: \.self) { option in
                Button { selection = option } label: {
                    Circle().fill(option.color.gradient)
                        .frame(width: 22, height: 22)
                        .overlay {
                            if option == selection {
                                Circle().strokeBorder(.white, lineWidth: 2).padding(2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.rawValue.capitalized)
                .accessibilityAddTraits(option == selection ? .isSelected : [])
                .accessibilityIdentifier("\(identifierPrefix)-\(option.rawValue)")
            }
        }
        .padding(.vertical, 2)
    }
}

/// The icon choices shared by every editor with an icon.
struct SymbolGrid: View {
    let symbols: [String]
    @Binding var selection: String
    let tint: Color

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 10), spacing: 8) {
            ForEach(symbols, id: \.self) { option in
                Button { selection = option } label: {
                    Image(systemName: option)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(option == selection ? .white : .primary)
                        .background(option == selection ? AnyShapeStyle(tint.gradient)
                                                        : AnyShapeStyle(Color.primary.opacity(0.07)),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ShieldCategory.spokenName(option))
                .accessibilityAddTraits(option == selection ? .isSelected : [])
                .accessibilityIdentifier("symbol-\(option)")
            }
        }
        .padding(.vertical, 4)
    }
}

struct CategoryEditor: View {
    let model: ShieldViewModel
    /// nil creates a new category.
    let existing: ShieldCategory?
    var onDelete: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbol: String
    @State private var color: ShieldCategoryColor
    @State private var confirmingDelete = false
    @State private var awaiting: UUID?
    @State private var problem: String?

    init(model: ShieldViewModel, existing: ShieldCategory?, onDelete: @escaping () -> Void = {}) {
        self.model = model
        self.existing = existing
        self.onDelete = onDelete
        _name = State(initialValue: existing?.name ?? "")
        _symbol = State(initialValue: existing?.symbol ?? "square.stack.fill")
        _color = State(initialValue: existing?.color ?? .blue)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameValid: Bool { !trimmedName.isEmpty && trimmedName.count <= ShieldCategory.maximumNameLength }
    private var canDelete: Bool {
        existing.map { $0.id != ShieldCategoryLayout.otherID && $0.id != ShieldCategoryLayout.locationID } ?? false
    }
    private var group: ShieldRuleGroup? {
        existing.flatMap { category in ShieldRulePresentation(model: model).groups.first { $0.id == category.id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorSheetHeader(symbol: symbol, tint: color.color,
                              title: existing == nil ? "New Category" : "Edit Category",
                              subtitle: "")
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. Games"))
                        .accessibilityIdentifier("categoryName")
                } footer: {
                    if trimmedName.count > ShieldCategory.maximumNameLength {
                        Text("Use \(ShieldCategory.maximumNameLength) characters or fewer.").foregroundStyle(.red)
                    }
                }
                Section("Color") {
                    ColorSwatches(selection: $color, identifierPrefix: "categoryColor")
                }
                Section("Icon") {
                    SymbolGrid(symbols: ShieldCategory.symbols, selection: $symbol, tint: color.color)
                }
                if canDelete {
                    Section {
                        Button("Delete Category…", role: .destructive) { confirmingDelete = true }
                            .accessibilityIdentifier("deleteCategory")
                    }
                }
                EditorSubmissionStatus(model: model, awaiting: awaiting, problem: problem)
            }
            .formStyle(.bubble)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancelCategoryEditor")
                Button(existing == nil ? "Create Category" : "Save") {
                    let category = existing.map {
                        ShieldCategory(id: $0.id, name: trimmedName, symbol: symbol, color: color, members: $0.members)
                    } ?? .new(name: trimmedName, symbol: symbol, color: color)
                    model.saveCategory(category)
                    dismiss()
                }
                // Not the default button: like every commit, Return while typing never saves.
                .buttonStyle(.prominentWhenEnabled)
                .disabled(!nameValid || awaiting != nil)
                .accessibilityIdentifier("saveCategory")
            }
            .shieldSheetFooter()
        }
        .frame(minWidth: 480, idealWidth: 520, maxWidth: 640, minHeight: 420, idealHeight: 470, maxHeight: 720)
        .shieldSheet()
        .dismissOnConfirmation(model, awaiting: $awaiting, problem: $problem)
        .onChange(of: model.submissionState) { _, state in
            // The model removes the category on confirmation; leave its page.
            if let id = awaiting, state == .confirmed(id) { onDelete() }
        }
        .shieldConfirmation(isPresented: $confirmingDelete) {
            var alternative: ShieldConfirmation.Alternative?
            if let existing, model.canReleaseRules(inCategory: existing.id), model.canSubmitPolicy {
                alternative = .init(title: "Delete and Remove Its Rules", destructive: true,
                                    identifier: "confirmDeleteCategoryAndRules") {
                    problem = nil
                    awaiting = model.releaseRules(inCategory: existing.id)
                    if awaiting == nil { problem = model.backendActionMessage }
                }
            }
            return ShieldConfirmation(
                symbol: "trash.fill", tint: existing?.color.color ?? .red, title: "Delete “\(existing?.name ?? "")”?",
                message: (group?.count ?? 0) == 0 ? "This category has no rules."
                    : "Its rules move back to their usual category.",
                confirmTitle: "Delete Category Only", destructive: true,
                confirmIdentifier: "confirmDeleteCategory", alternative: alternative) {
                    guard let existing else { return }
                    model.deleteCategory(existing.id)
                    onDelete()
                    dismiss()
                }
        }
    }
}

// MARK: - Remove websites from a block

struct RemoveSitesSheet: View {
    let model: ShieldViewModel
    let restriction: DomainRestriction
    @Environment(\.dismiss) private var dismiss
    @State private var removing: Set<String> = []
    @State private var awaiting: UUID?
    @State private var problem: String?

    private var removal: ShieldViewModel.SiteRemoval { model.siteRemoval(for: restriction) }
    private var sites: [String] { WebsiteListParser.roots(restriction.domains) }
    private func twins(_ domain: String) -> Set<String> {
        restriction.domains.contains("www." + domain) ? [domain, "www." + domain] : [domain]
    }
    private var explanation: String {
        switch removal {
        case .afterDelay:
            return "Removed websites stay blocked for 24 hours. The rest stay blocked."
        case .correction:
            return "Removed websites stay blocked for 24 hours. Kept websites stay permanent."
        case .afterPermanentWait(let wait):
            return "Removed websites stay blocked for \(PermanentRemovalPolicy.describe(wait)). Kept websites stay permanent."
        case .unavailable(let reason):
            return reason
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorSheetHeader(symbol: "minus", tint: .orange, title: "Remove Websites",
                              subtitle: model.displayName(for: restriction.policyID, title: restriction.title))
            Form {
                Section {
                    // A website and its www. twin are one choice.
                    ForEach(sites, id: \.self) { domain in
                        Toggle(domain, isOn: Binding(
                            get: { removing.contains(domain) },
                            set: { checked in
                                let pair = twins(domain)
                                if checked { removing.formUnion(pair) } else { removing.subtract(pair) }
                            }))
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("removeSite-\(domain)")
                    }
                } header: {
                    HStack {
                        Text("Select websites to remove")
                        Spacer()
                        Button(removing.count == restriction.domains.count ? "Select None" : "Select All") {
                            removing = removing.count == restriction.domains.count ? [] : restriction.domains
                        }
                        .controlSize(.small)
                        .buttonStyle(ShieldPillButtonStyle())
                    }
                } footer: {
                    Text(explanation)
                }
                .disabled(awaiting != nil)
                EditorSubmissionStatus(model: model, awaiting: awaiting, problem: problem)
            }
            .formStyle(.bubble)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button(awaiting == nil ? "Cancel" : "Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(removing.count == restriction.domains.count ? "Remove Block" : "Remove \(sites.filter(removing.contains).count) Website\(sites.filter(removing.contains).count == 1 ? "" : "s")") {
                    problem = nil
                    awaiting = model.removeSites(removing, from: restriction)
                    if awaiting == nil { problem = model.backendActionMessage }
                }
                .buttonStyle(.prominentWhenEnabled)
                .disabled(removing.isEmpty || awaiting != nil || !model.canSubmitPolicy ||
                          { if case .unavailable = removal { return true } else { return false } }())
                .accessibilityIdentifier("confirmRemoveSites")
            }
            .shieldSheetFooter()
        }
        .frame(minWidth: 440, idealWidth: 500, maxWidth: 620, minHeight: 320, idealHeight: 360, maxHeight: 720)
        .shieldSheet()
        .dismissOnConfirmation(model, awaiting: $awaiting, problem: $problem)
    }
}

// MARK: - Schedules

struct ScheduleSitesEditor: View {
    let model: ShieldViewModel
    let schedule: DailySchedule
    @Environment(\.dismiss) private var dismiss
    @State private var websites: String
    @State private var awaiting: UUID?
    @State private var problem: String?

    init(model: ShieldViewModel, schedule: DailySchedule) {
        self.model = model
        self.schedule = schedule
        // Shown without www. twins; they are kept or added automatically.
        _websites = State(initialValue: WebsiteListParser.roots(schedule.domains).joined(separator: ", "))
    }

    /// What is typed, plus www. twins: a newly typed website gets its twin, and a
    /// kept website keeps the twin it already had. Deleting a website removes both.
    private var domains: Set<String>? {
        guard let typed = WebsiteListParser.domains(websites, limit: PolicyValidation.maximumDomains) else { return nil }
        let shown = Set(WebsiteListParser.roots(schedule.domains))
        var result = typed.union(WebsiteListParser.withWWW(typed.subtracting(shown)))
        for domain in schedule.domains where domain.hasPrefix("www.") && typed.contains(String(domain.dropFirst(4))) {
            result.insert(domain)
        }
        return result.count <= PolicyValidation.maximumDomains ? result : nil
    }
    private var removed: Set<String> { domains.map { schedule.domains.subtracting($0) } ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            EditorSheetHeader(symbol: "globe", tint: .shieldAccent, title: "Edit Websites",
                              subtitle: model.displayName(for: schedule.id, title: schedule.title))
            Form {
                Section {
                    TextField("Websites", text: $websites, axis: .vertical)
                        .lineLimit(3...8).labelsHidden()
                        .accessibilityIdentifier("scheduleSitesField")
                } footer: {
                    if domains == nil {
                        Text("Use website addresses like example.com, separated by commas (about \(PolicyValidation.maximumDomains / 2) at most).").foregroundStyle(.orange)
                    } else if !removed.isEmpty && !(domains ?? []).isSubset(of: schedule.domains) {
                        Text("Adding and removing together waits 24 hours for everything. To block new websites now, add them without removing any.")
                    } else if !removed.isEmpty {
                        Text("Removing \(WebsiteListParser.roots(removed).joined(separator: ", ")) takes 24 hours.")
                    } else if domains != schedule.domains {
                        Text("New websites apply right away.")
                    }
                }
                EditorSubmissionStatus(model: model, awaiting: awaiting, problem: problem)
            }
            .formStyle(.bubble)
            .scrollContentBackground(.hidden)
            // Like New Block: Check / Try Again stay usable when a reply didn't come.
            .disabled(awaiting != nil && model.submissionState != .unconfirmed(awaiting!))

            HStack {
                Spacer()
                Button(awaiting == nil ? "Cancel" : "Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let domains else { return }
                    problem = nil
                    awaiting = model.changeScheduleSites(scheduleID: schedule.id, to: domains)
                    if awaiting == nil { problem = model.backendActionMessage }
                }
                .buttonStyle(.prominentWhenEnabled)
                .disabled(domains == nil || domains == schedule.domains || awaiting != nil || !model.canSubmitPolicy)
                .accessibilityIdentifier("saveScheduleSites")
            }
            .shieldSheetFooter()
        }
        .frame(width: 440, height: 320)
        .shieldSheet()
        .dismissOnConfirmation(model, awaiting: $awaiting, problem: $problem)
    }
}

// MARK: - Small controls

struct CategoryPicker: View {
    let model: ShieldViewModel
    @Binding var selection: String
    var title = "Category"
    var body: some View {
        Picker(title, selection: $selection) {
            // Location blocks fills itself from blocks set to a place.
            ForEach(model.categoryLayout.categories.filter { $0.id != ShieldCategoryLayout.locationID }) { category in
                Label(category.name, systemImage: category.symbol).tag(category.id)
            }
        }
        .accessibilityIdentifier("categoryPicker")
    }
}

struct HoursPicker: View {
    let model: ShieldViewModel
    let title: String
    @Binding var minutes: Int
    var body: some View {
        DatePicker(title, selection: Binding(
            get: {
                model.scheduleCalendar.date(from: DateComponents(year: 2001, month: 1, day: 15,
                    hour: minutes / 60, minute: minutes % 60)) ?? .now
            },
            set: { time in
                let parts = model.scheduleCalendar.dateComponents([.hour, .minute], from: time)
                minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
        // Shown in the schedule's time zone, the same one the minutes use.
        .environment(\.timeZone, model.scheduleCalendar.timeZone)
    }
}

/// "Move to" submenu listing the user's categories.
struct MoveToCategoryMenu: View {
    let model: ShieldViewModel
    let ruleID: String
    let currentCategoryID: String
    var body: some View {
        Menu("Move to Category") {
            ForEach(model.categoryLayout.categories.filter {
                $0.id != currentCategoryID && $0.id != ShieldCategoryLayout.locationID
            }) { category in
                Button { model.placeRule(ruleID, in: category.id) } label: {
                    Label(category.name, systemImage: category.symbol)
                }
            }
        }
    }
}
