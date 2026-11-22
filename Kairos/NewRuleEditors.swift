import SwiftUI

// Inside every category (its Add or Edit menu): add websites or apps, blocked
// until you turn them off, or with daily allowed hours.
// Restored from release 242: Lock In is a separate,
// time-boxed commitment and does not replace these. www. twins are always added.

// MARK: - New block

struct BlockEditor: View {
    /// How a new block works (Nov 13: was always "until turned off").
    enum Kind: Hashable, CaseIterable {
        case untilTurnedOff, forSetTime, permanent, atPlace, allowedHours

        var label: String {
            switch self {
            case .untilTurnedOff: "Until turned off"
            case .forSetTime: "For a set time"
            case .permanent: "Permanent"
            case .atPlace: "At a place"
            case .allowedHours: "Allowed hours"
            }
        }

        /// The same symbols as the rows these blocks become.
        var symbol: String {
            switch self {
            case .untilTurnedOff: "nosign"
            case .forSetTime: "hourglass"
            case .permanent: "lock.fill"
            case .atPlace: "mappin.and.ellipse"
            case .allowedHours: "clock.fill"
            }
        }
    }

    /// Lengths for "For a set time": Lock In's timed rule, which can't end early.
    enum Length: Hashable, CaseIterable {
        case oneHour, threeHours, eightHours, oneDay, oneWeek, untilDate

        var label: String {
            switch self {
            case .oneHour: "1 hour"
            case .threeHours: "3 hours"
            case .eightHours: "8 hours"
            case .oneDay: "1 day"
            case .oneWeek: "1 week"
            case .untilDate: "Until a date…"
            }
        }

        var seconds: TimeInterval? {
            switch self {
            case .oneHour: 3_600
            case .threeHours: 10_800
            case .eightHours: 28_800
            case .oneDay: 86_400
            case .oneWeek: 604_800
            case .untilDate: nil
            }
        }
    }

    let model: ShieldViewModel
    @State private var kind = Kind.untilTurnedOff
    @State private var length = Length.oneHour
    @State private var endDate = Date.now.addingTimeInterval(86_400)
    @State private var understandsForever = false
    @State private var start = 14 * 60
    @State private var end = 20 * 60
    @Environment(\.dismiss) private var dismiss
    @State private var categoryID: String
    @State private var creatingCategory = false
    @State private var awaiting: UUID?
    @State private var problem: String?
    @State private var websites = ""
    @State private var apps: [AppTarget] = []
    @State private var placeID: String?
    /// Opened from a place page or Location blocks: it's a block at a place,
    /// so the other kinds aren't offered here (they're on Protection's +).
    private let atPlaceOnly: Bool
    @FocusState private var websitesFocused: Bool

    init(model: ShieldViewModel, categoryID: String? = nil, placeID: String? = nil) {
        self.model = model
        // Opened from Location blocks or a place page: start at that place.
        let fromLocation = categoryID == ShieldCategoryLayout.locationID
        _categoryID = State(initialValue: fromLocation ? ShieldCategoryLayout.otherID
                            : categoryID ?? ShieldCategoryLayout.otherID)
        let place = placeID ?? (fromLocation ? model.availablePlaces.first?.id : nil)
        _placeID = State(initialValue: place)
        _kind = State(initialValue: place == nil ? .untilTurnedOff : .atPlace)
        atPlaceOnly = place != nil
    }

    private var offersPlaces: Bool { model.supportsLocationRules && !model.availablePlaces.isEmpty }

    /// "For a set time" as Lock In's plan, so the service sees exactly a Lock In.
    private var timedPlan: LockInPlan? {
        guard let chosen = domains else { return nil }
        let planLength: LockInPlan.Length = length.seconds.map { .lasting($0) } ?? .until(endDate)
        return LockInPlan(title: groupTitle, domains: chosen, apps: Set(apps), access: .never, length: planLength)
    }

    /// Longer than a day and can't end early: asked once, like Lock In.
    private var needsAcknowledgement: Bool {
        switch kind {
        case .permanent: true
        case .forSetTime: (length.seconds ?? endDate.timeIntervalSinceNow) > 86_400
        default: false
        }
    }

    /// The websites to block with their www. twins: none when empty, nil when invalid.
    private var domains: Set<String>? {
        if websites.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        guard let base = WebsiteListParser.domains(websites) else { return nil }
        let all = WebsiteListParser.withWWW(base)
        return all.count <= 20 ? all : nil
    }

    private var hasTargets: Bool {
        guard let domains else { return false }
        return !domains.isEmpty || !apps.isEmpty
    }

    private var placeName: String? { model.availablePlaces.first { $0.id == placeID }?.name }
    private var window: AllowedAccessWindow? { AllowedAccessWindow(startMinutes: start, endMinutes: end) }

    private var commitTitle: String {
        guard hasTargets, let sites = domains.map({ WebsiteListParser.roots($0).count }) else { return "Block" }
        let parts = (sites > 0 ? ["\(sites) Website\(sites == 1 ? "" : "s")"] : []) +
            (apps.isEmpty ? [] : ["\(apps.count) App\(apps.count == 1 ? "" : "s")"])
        return "Block " + parts.joined(separator: " and ")
    }

    private var groupTitle: String {
        if let sites = domains, !sites.isEmpty { return WebsiteListParser.title(for: sites) }
        let names = apps.map(\.displayName)
        return names.count > 1 ? "\(names[0]) + \(names.count - 1) more" : names.first ?? "Custom block"
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorSheetHeader(symbol: "plus", tint: .shieldAccent,
                              title: atPlaceOnly ? "New Block at \(placeName ?? "a Place")" : "New Block", subtitle: "")
            Form {
                Section {
                    TextField("Websites", text: $websites, prompt: Text("reddit.com, youtube.com"), axis: .vertical)
                        .lineLimit(1...5)
                        .labelsHidden()
                        .focused($websitesFocused)
                        .accessibilityLabel("Websites to block")
                        .accessibilityIdentifier("newBlockDomains")
                } header: {
                    Text("Websites")
                } footer: {
                    if !websites.isEmpty && domains == nil {
                        Text("Type website addresses like example.com, up to 10 sites at a time.").foregroundStyle(.orange)
                    }
                }

                AppsSection(apps: $apps)

                Section {
                    if !atPlaceOnly {
                        ChipFlow {
                            ForEach(Kind.allCases.filter { $0 != .atPlace || offersPlaces }, id: \.self) { choice in
                                ChoiceChip(title: choice.label, symbol: choice.symbol, selected: kind == choice) {
                                    withAnimation(.snappy(duration: 0.2)) { kind = choice }
                                }
                                .accessibilityIdentifier("newBlockKind-\(choice)")
                            }
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Block")
                        .accessibilityIdentifier("newBlockKind")
                    }
                    if kind == .forSetTime {
                        ChipFlow {
                            ForEach(Length.allCases, id: \.self) { choice in
                                ChoiceChip(title: choice.label, selected: length == choice) { length = choice }
                                    .accessibilityIdentifier("newBlockLength-\(choice)")
                            }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("For")
                        .accessibilityIdentifier("newBlockLength")
                        if length == .untilDate {
                            DatePicker("Until", selection: $endDate,
                                       in: Date.now.addingTimeInterval(900)...Date.now.addingTimeInterval(LockInPlan.maximumLength),
                                       displayedComponents: [.date, .hourAndMinute])
                                .accessibilityIdentifier("newBlockEndDate")
                        }
                    }
                    if kind == .atPlace {
                        Picker("Where", selection: $placeID) {
                            ForEach(model.availablePlaces) { place in
                                Text(place.name).tag(Optional(place.id))
                            }
                        }
                        .accessibilityIdentifier("blockWhere")
                    }
                    if needsAcknowledgement {
                        Toggle(kind == .permanent ? model.permanentAcknowledgement : "I understand this can't be ended early",
                               isOn: $understandsForever)
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("newBlockConfirmPermanent")
                    }
                    if kind == .allowedHours {
                        HoursPicker(model: model, title: "Allow from", minutes: $start)
                        HoursPicker(model: model, title: "Allow until", minutes: $end)
                        if let window {
                            AllowedHoursBar(window: window, height: 10).padding(.vertical, 4)
                        } else {
                            Text("Start and end must differ.").foregroundStyle(.orange)
                        }
                    }
                } header: {
                    if !atPlaceOnly { Text("How it's blocked") }
                } footer: {
                    if kind == .forSetTime, let plan = timedPlan, let problem = plan.problem(now: .now) {
                        Text(problem).foregroundStyle(.orange)
                    } else if kind == .allowedHours,
                              model.scheduleCalendar.timeZone.identifier != TimeZone.current.identifier {
                        Text("Times are \(model.scheduleTimeZoneDescription).")
                    }
                }

                Section {
                    if kind != .atPlace {
                        HStack {
                            CategoryPicker(model: model, selection: $categoryID)
                            Button("New…") { creatingCategory = true }
                                .accessibilityIdentifier("blockNewCategory")
                        }
                    }
                }
                EditorSubmissionStatus(model: model, awaiting: awaiting, problem: problem)
            }
            .formStyle(.bubble)
            .scrollContentBackground(.hidden)
            .disabled(awaiting != nil && model.submissionState != .unconfirmed(awaiting!))
            .accessibilityIdentifier("newBlockScroll")

            HStack {
                if !model.canSubmitPolicy && awaiting == nil {
                    Label("Blocks can't be created right now", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isSubmittingPolicy { ProgressView().controlSize(.small) }
                Button(awaiting == nil ? "Cancel" : "Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancelNewBlock")
                // Not the default button: Return while typing must never commit.
                Button(commitTitle) { submit() }
                    .buttonStyle(.prominentWhenEnabled)
                    .disabled(!canSubmit)
                    .accessibilityIdentifier("commitNewBlock")
            }
            .shieldSheetFooter()
        }
        .frame(width: 460)
        .shieldSheet()
        .frame(minHeight: 340, idealHeight: (atPlaceOnly ? 360 : 440) + CGFloat(min(apps.count, 4)) * 28, maxHeight: 700)
        .dismissOnConfirmation(model, awaiting: $awaiting, problem: $problem)
        .onAppear { websitesFocused = true }
        .onChange(of: kind) {
            understandsForever = false
            if kind == .atPlace && placeID == nil { placeID = model.availablePlaces.first?.id }
        }
        .onChange(of: length) { understandsForever = false }
        .sheet(isPresented: $creatingCategory) { CategoryEditor(model: model, existing: nil) }
        .onChange(of: model.categoryLayout.categories.count) { old, new in
            // A category created from this sheet becomes the selection.
            if new > old, let created = model.categoryLayout.categories.last(where: { !$0.isBuiltIn }) {
                categoryID = created.id
            }
        }
    }

    private var canSubmit: Bool {
        hasTargets && awaiting == nil && model.canSubmitPolicy &&
            model.categoryLayout.category(categoryID) != nil &&
            (!needsAcknowledgement || understandsForever) && (kind != .allowedHours || window != nil) &&
            (kind != .atPlace || placeID != nil) &&
            (kind != .forSetTime || timedPlan.map { $0.problem(now: .now) == nil } == true)
    }

    private func submit() {
        guard canSubmit, let chosen = domains else { return }
        problem = nil
        switch kind {
        case .untilTurnedOff:
            awaiting = model.commitBlock(domains: chosen, duration: .untilReleased, groupName: groupTitle,
                                         categoryID: categoryID, apps: Set(apps))
        case .atPlace:
            guard let placeID else { return }
            awaiting = model.commitBlock(domains: chosen, duration: .untilReleased, groupName: groupTitle,
                                         apps: Set(apps), placeID: placeID)
        case .forSetTime:
            guard let timedPlan else { return }
            awaiting = model.commitTimedBlock(timedPlan, categoryID: categoryID)
        case .permanent:
            awaiting = model.commitBlock(domains: chosen, duration: .untilReleased, groupName: groupTitle,
                                         categoryID: categoryID, apps: Set(apps), permanent: true)
        case .allowedHours:
            guard let window else { return }
            awaiting = model.addSchedule(name: groupTitle, domains: chosen, allowed: window,
                                         categoryID: categoryID, apps: Set(apps))
        }
        if awaiting == nil { problem = model.backendActionMessage }
    }
}

// MARK: - New daily schedule

struct NewScheduleEditor: View {
    let model: ShieldViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var categoryID: String
    @State private var name = ""
    @State private var websites = ""
    @State private var start = 14 * 60
    @State private var end = 20 * 60
    @State private var apps: [AppTarget] = []
    @State private var awaiting: UUID?
    @State private var problem: String?

    init(model: ShieldViewModel, categoryID: String?) {
        self.model = model
        _categoryID = State(initialValue: categoryID.flatMap { $0 == ShieldCategoryLayout.locationID ? nil : $0 }
                            ?? ShieldCategoryLayout.otherID)
    }

    /// Websites to block with their www. twins: none when the field is empty, nil when invalid.
    private var domains: Set<String>? {
        if websites.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
        guard let base = WebsiteListParser.domains(websites) else { return nil }
        let all = WebsiteListParser.withWWW(base)
        return all.count <= 20 ? all : nil
    }
    private var window: AllowedAccessWindow? { AllowedAccessWindow(startMinutes: start, endMinutes: end) }
    private var nameValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 64
    }
    private var canCreate: Bool {
        domains != nil && !(domains?.isEmpty == true && apps.isEmpty) && window != nil && nameValid &&
            awaiting == nil && model.canSubmitPolicy
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorSheetHeader(symbol: "clock.fill", tint: .teal, title: "New Daily Schedule", subtitle: "")
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Tumblr"))
                        .accessibilityIdentifier("scheduleName")
                }
                Section {
                    TextField("Websites", text: $websites, prompt: Text("tumblr.com"), axis: .vertical)
                        .lineLimit(1...5)
                        .labelsHidden()
                        .accessibilityLabel("Websites")
                        .accessibilityIdentifier("scheduleWebsites")
                } header: {
                    Text("Websites")
                } footer: {
                    if !websites.isEmpty && domains == nil {
                        Text("Type website addresses like example.com, up to 10 sites at a time.").foregroundStyle(.orange)
                    }
                }
                AppsSection(apps: $apps)
                Section {
                    HoursPicker(model: model, title: "Allow from", minutes: $start)
                    HoursPicker(model: model, title: "Allow until", minutes: $end)
                    if let window {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Allowed " + ScheduleText.short(window)).font(.headline)
                            AllowedHoursBar(window: window, height: 10)
                            HourAxisLabels()
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text("Start and end must differ.").foregroundStyle(.orange)
                    }
                } header: {
                    Text("Allowed hours")
                } footer: {
                    if model.scheduleCalendar.timeZone.identifier != TimeZone.current.identifier {
                        Text("Times are \(model.scheduleTimeZoneDescription).")
                    }
                }
                Section { CategoryPicker(model: model, selection: $categoryID) }
                EditorSubmissionStatus(model: model, awaiting: awaiting, problem: problem)
            }
            .formStyle(.bubble)
            .scrollContentBackground(.hidden)
            .disabled(awaiting != nil && model.submissionState != .unconfirmed(awaiting!))

            HStack {
                Spacer()
                Button(awaiting == nil ? "Cancel" : "Close") { dismiss() }.keyboardShortcut(.cancelAction)
                // Not the default button: Return while typing must never commit.
                Button("Create Schedule") {
                    guard canCreate, let domains, let window else { return }
                    problem = nil
                    awaiting = model.addSchedule(name: name, domains: domains, allowed: window, categoryID: categoryID,
                                                 apps: Set(apps))
                    if awaiting == nil { problem = model.backendActionMessage }
                }
                .buttonStyle(.prominentWhenEnabled)
                .disabled(!canCreate)
                .accessibilityIdentifier("confirmAddSchedule")
            }
            .shieldSheetFooter()
        }
        .frame(width: 460)
        .shieldSheet()
        .frame(minHeight: 420, idealHeight: 640 + CGFloat(min(apps.count, 4)) * 28, maxHeight: 760)
        .environment(\.timeZone, model.scheduleCalendar.timeZone)
        .dismissOnConfirmation(model, awaiting: $awaiting, problem: $problem)
    }
}
