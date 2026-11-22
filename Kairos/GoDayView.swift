import SwiftUI
import UniformTypeIdentifiers

// "Go there today" (docs/conditional-rules-blueprint.md §8). One morning button: web
// browsers (and any apps you add) stay closed until this Mac gets to a place
// you picked, then open for the rest of the day. The service decides arriving;
// the app only senses, asks and shows.

// MARK: - Starting a day

struct GoDayStartSheet: View {
    let model: ShieldViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []
    @State private var until = GoDayStartSheet.defaultEnd()
    @State private var apps: [AppTarget] = []
    /// Browsers are a choice (on to start with), not built in.
    @State private var browsers = true
    /// Websites as typed or picked, without www. (added when the day is made).
    @State private var sites: Set<String> = []
    @State private var addingOnMap = false
    @State private var awaiting: UUID?
    @State private var problem: String?
    @State private var confirming = false
    @State private var pickingApps = false
    @State private var addingSites = false
    @State private var appProblem: String?

    private var places: [RulePlace] { model.locationPolicy.places.filter { !$0.isHome }.sorted { $0.name < $1.name } }
    private var chosenPlaces: [RulePlace] { places.filter { chosen.contains($0.id) } }
    private var blocksSomething: Bool { browsers || !apps.isEmpty || !sites.isEmpty }

    /// 9 PM today, or the end of today when it's already late.
    static func defaultEnd(now: Date = .now, calendar: Calendar = .current) -> Date {
        let nine = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: now) ?? now
        return nine.timeIntervalSince(now) >= 3_600 ? nine : GoDayStartSheet.latestEnd(now: now, calendar: calendar)
    }

    static func latestEnd(now: Date = .now, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: 23, minute: 59, second: 0, of: now) ?? now
    }

    /// From 15 minutes after the undo window to 11:59 PM; never inverted late at night.
    static func endRange(now: Date = .now, calendar: Calendar) -> ClosedRange<Date> {
        let latest = latestEnd(now: now, calendar: calendar)
        let earliest = now.addingTimeInterval(GoDayGate.undoWindow + 900)
        return min(earliest, latest)...latest
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in sheet }
            .task {
                // The button that opened this sheet started the sensor. A Mac
                // sitting still gets no new fixes on its own, so keep asking.
                while !Task.isCancelled {
                    model.locationSensor?.keepFixFresh(olderThan: 20)
                    model.locationSensor?.scanWiFi()
                    try? await Task.sleep(for: .seconds(10))
                }
            }
    }

    private var tint: Color { ShieldGroupKind.location.tint }

    /// Three questions, nothing
    /// else: where you're going, what to block, and when it opens anyway.
    /// Browsers, apps and websites are each a choice.
    private var sheet: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    whereSection
                    blockSection
                    endSection
                    if hasHint { hint }
                    EditorSubmissionStatus(model: model, awaiting: awaiting, problem: nil)
                }
                .padding(.horizontal, 26)
                .padding(.top, 24)
                .padding(.bottom, 16)
            }
            // Unlocked again once Shield stops waiting, so Check and Try Again work.
            .disabled(awaiting.map { model.submissionState != .unconfirmed($0) } ?? false)

            HStack(spacing: 10) {
                // A trial run: the same check, nothing blocked.
                Button("Try Without Blocking") { startPractice() }
                    .buttonStyle(.link)
                    .disabled(chosen.isEmpty || awaiting != nil)
                    .help("Shows how close you are and when you'd be let in. Nothing gets blocked.")
                    .accessibilityIdentifier("goDayPractice")
                Spacer()
                Button(awaiting == nil ? "Cancel" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(ShieldPillButtonStyle())
                // Not the default button: Return must never start a Go day.
                Button("Start…") { confirming = true }
                    .buttonStyle(ShieldFilledButtonStyle(tint: tint))
                    .disabled(chosen.isEmpty || !blocksSomething || awaiting != nil || !model.goDayStartReady ||
                              !model.canSubmitPolicy)
                    .accessibilityIdentifier("confirmGoDay")
            }
            .controlSize(.large)
            .padding(.horizontal, 26)
            .padding(.vertical, 14)
            .overlay(alignment: .top) { Divider().opacity(0.5) }
        }
        .frame(width: 520)
        .shieldSheet()
        .frame(minHeight: 420, idealHeight: 470)
        .environment(\.timeZone, model.scheduleCalendar.timeZone)
        .dismissOnConfirmation(model, awaiting: $awaiting, problem: $problem)
        .sheet(isPresented: $addingOnMap) {
            // You can't Go There to where you already are, so no "Use My Location".
            PlaceEditor(model: model, offersHere: false) { id in chosen.insert(id) }
        }
        .shieldConfirmation(isPresented: $confirming) { startConfirmation }
        .fileImporter(isPresented: $pickingApps, allowedContentTypes: [.applicationBundle],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { (apps, appProblem) = AppsSection.adding(urls, to: apps) }
        }
        .onAppear {
            until = Self.defaultEnd(calendar: model.scheduleCalendar)
            if chosen.isEmpty, places.count == 1 { chosen = [places[0].id] }
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.walk")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            Text("Go There Today").font(.title2.weight(.bold))
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.headline)
    }

    private var whereSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Where are you going?")
                Spacer()
                Button { addingOnMap = true } label: { Label("Add a Place…", systemImage: "plus") }
                    .controlSize(.small)
                    .buttonStyle(ShieldPillButtonStyle())
                    .accessibilityIdentifier("goDayAddOnMap")
            }
            if places.isEmpty {
                Button { addingOnMap = true } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "mappin.and.ellipse").font(.system(size: 24)).foregroundStyle(tint)
                        Text("Add the place you're going to.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                          spacing: 10) {
                    ForEach(places) { placeTile($0) }
                }
            }
        }
    }

    private func placeTile(_ place: RulePlace) -> some View {
        let selected = chosen.contains(place.id)
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                if selected { chosen.remove(place.id) } else { chosen.insert(place.id) }
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "mappin")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(selected ? Color.white : tint)
                    .frame(width: 32, height: 32)
                    .background(selected ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.15)), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(place.name).font(.body.weight(.semibold)).lineLimit(1)
                    Text("Within " + Measurement(value: place.radiusMeters, unit: UnitLength.meters)
                        .formatted(.measurement(width: .abbreviated, usage: .road)))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(selected ? tint.opacity(0.13) : Color.primary.opacity(0.05)))
            .overlay(shape.strokeBorder(selected ? tint.opacity(0.9) : Color.primary.opacity(0.09),
                                        lineWidth: selected ? 1.5 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(place.name)
        .accessibilityValue(selected ? "Chosen" : "Not chosen")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("goDayPlace-\(place.id)")
    }

    /// What's blocked until you get there: browsers (a switch-like chip), the
    /// apps you add and the websites you add, each removable.
    private var blockSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Block until you get there")
            VStack(alignment: .leading, spacing: 8) {
                ChipFlow(spacing: 8) {
                    HStack(spacing: 5) {
                        browsersChip
                        // "Web browsers" alone sounds vague.
                        InfoHint("Every browser: Safari, Chrome, Firefox, Edge, Brave, Arc, and any other app that opens web pages.")
                            .accessibilityIdentifier("aboutGoDayBrowsers")
                    }
                    ForEach(apps) { app in
                        GoDayChip(label: app.displayName, identifier: "blockApp-\(app.bundleID)",
                                  help: "Don't block \(app.displayName)") {
                            AppIcon(bundleID: app.bundleID, size: 16)
                        } remove: { apps.removeAll { $0.id == app.id } }
                    }
                    ForEach(sites.sorted(), id: \.self) { site in
                        GoDayChip(label: site, identifier: "goDaySite-\(site)", help: "Don't block \(site)") {
                            Image(systemName: "globe").foregroundStyle(.secondary)
                        } remove: { sites.remove(site) }
                    }
                    Button { pickingApps = true } label: { Label("App", systemImage: "plus") }
                        .disabled(apps.count >= PolicyValidation.maximumApps)
                        .accessibilityIdentifier("blockAddApp")
                    Button { addingSites = true } label: { Label("Website", systemImage: "plus") }
                        .accessibilityIdentifier("goDayAddWebsite")
                        .popover(isPresented: $addingSites, arrowEdge: .bottom) {
                            GoDaySitePicker(model: model, sites: $sites)
                        }
                }
                .controlSize(.small)
                .buttonStyle(ShieldPillButtonStyle())
                if let appProblem {
                    Text(appProblem).font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("blockAppProblem")
                } else if !blocksSomething {
                    Text("Pick something to block.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .goDayCard()
        }
    }

    /// On: every web browser (the known ones and any app that opens web
    /// pages, Firefox included). Off: only the apps and websites added.
    private var browsersChip: some View {
        Button {
            withAnimation(.snappy(duration: 0.15)) { browsers.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: browsers ? "checkmark" : "plus").font(.caption.weight(.bold))
                Text("Web browsers")
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(browsers ? Color.white : Color.primary)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(Capsule().fill(browsers ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(Color.primary.opacity(0.06))))
            .overlay(Capsule().strokeBorder(browsers ? Color.clear : Color.primary.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Web browsers")
        .accessibilityValue(browsers ? "Blocked" : "Not blocked")
        .accessibilityAddTraits(browsers ? .isSelected : [])
        .accessibilityIdentifier("goDayBrowsers")
    }

    private var endSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("If you don't make it")
            HStack(spacing: 12) {
                Text("Everything opens at")
                Spacer()
                DatePicker("Ends at", selection: $until, in: Self.endRange(calendar: model.scheduleCalendar),
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                    .accessibilityIdentifier("goDayUntil")
            }
            .goDayCard()
        }
    }

    private var timeText: String {
        until.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: model.scheduleCalendar.timeZone))
    }

    private var startConfirmation: ShieldConfirmation {
        let names = ListFormatter.localizedString(byJoining: chosenPlaces.map(\.name))
        return ShieldConfirmation(
            symbol: "figure.walk", tint: tint, title: "Start Go There Today?",
            message: "Blocking starts in 2 minutes and can't be cancelled after that. "
                + "It ends when you get to \(names), or at \(timeText).",
            confirmTitle: "Start", confirmIdentifier: "confirmGoDayStart") { start() }
    }

    private var hasHint: Bool {
        let access = model.locationSensor?.access
        return problem != nil || access == .denied || access == .restricted || access == .approximateOnly
            || !model.goDayStartReady
    }

    @ViewBuilder private var hint: some View {
        let access = model.locationSensor?.access
        Group {
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if access == .denied || access == .restricted || access == .approximateOnly {
                Label(access == .approximateOnly ? "Turn on Precise Location for Shield in System Settings."
                                                 : "Turn on Location for Shield in System Settings.",
                      systemImage: "location.slash.fill")
                    .foregroundStyle(.orange)
            } else if !model.goDayStartReady {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Finding where you are now…").foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("goDayHint")
    }

    private func startPractice() {
        problem = nil
        if model.startGoDayPractice(placeIDs: chosen, until: until) { dismiss() } else { problem = model.backendActionMessage }
    }

    private func start() {
        problem = nil
        awaiting = model.startGoDay(placeIDs: chosen, until: until, apps: Set(apps), browsers: browsers, domains: sites)
        if awaiting == nil { problem = model.backendActionMessage }
    }
}

/// One thing a Go day blocks, with a × to take it off.
private struct GoDayChip<Icon: View>: View {
    let label: String
    let identifier: String
    let help: String
    @ViewBuilder var icon: Icon
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            icon
            Text(label).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel("Remove \(label)")
        }
        .font(.callout.weight(.medium))
        .padding(.leading, 9).padding(.trailing, 7).padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// Add websites to a Go day: type them, or take a whole category's at once.
private struct GoDaySitePicker: View {
    let model: ShieldViewModel
    @Binding var sites: Set<String>
    @State private var typed = ""
    @Environment(\.dismiss) private var dismiss

    /// Categories that have websites, in their own colors.
    private var categories: [(id: String, name: String, symbol: String, tint: Color, sites: Set<String>)] {
        ShieldRulePresentation(model: model).groups.compactMap { group in
            let roots = Set(WebsiteListParser.roots(group.domains))
            guard !roots.isEmpty, group.id != ShieldCategoryLayout.locationID else { return nil }
            return (group.id, group.title, group.category.symbol, group.category.color.color, roots)
        }
    }

    private var parsed: Set<String>? {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : WebsiteListParser.domains(typed)
    }

    private func fits(_ more: Set<String>) -> Bool {
        WebsiteListParser.withWWW(sites.union(more)).count <= PolicyValidation.maximumDomains
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                TextField("youtube.com, reddit.com", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTyped)
                    .accessibilityIdentifier("goDaySiteField")
                Button("Add", action: addTyped)
                    .buttonStyle(ShieldFilledButtonStyle())
                    .disabled(parsed.map { !fits($0) } ?? true)
                    .accessibilityIdentifier("goDayAddSite")
            }
            if !typed.isEmpty && parsed == nil {
                Text("Type websites like youtube.com.").font(.caption).foregroundStyle(.orange)
            }
            if !categories.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Or a whole category").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(categories, id: \.id) { category in
                        let added = category.sites.isSubset(of: sites)
                        Button {
                            if added { sites.subtract(category.sites) } else if fits(category.sites) { sites.formUnion(category.sites) }
                        } label: {
                            HStack(spacing: 10) {
                                CategoryIcon(symbol: category.symbol, tint: category.tint, size: 26)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(category.name).font(.callout.weight(.semibold))
                                    Text("\(category.sites.count) website\(category.sites.count == 1 ? "" : "s")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                                    .font(.system(size: 17))
                                    .foregroundStyle(added ? AnyShapeStyle(category.tint) : AnyShapeStyle(.secondary))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(added ? category.tint.opacity(0.12) : Color.primary.opacity(0.04)))
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("goDayCategory-\(category.id)")
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private func addTyped() {
        guard let parsed, fits(parsed) else { return }
        sites.formUnion(WebsiteListParser.roots(parsed))
        typed = ""
    }
}

// MARK: - All day: one banner in the window's corner

struct GoDayBar: View {
    let model: ShieldViewModel
    /// The × hides this kind of line; a different one (done, a warning) shows again.
    @State private var hiddenKind: String?

    var body: some View {
        // Ticks every second only while there's a line to show; otherwise the
        // model's own updates bring it in (no per-second redraw on every page).
        if model.goDayLine(now: .now) != nil {
            ticking
        }
    }

    private var ticking: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let line = model.goDayLine(now: context.date), hiddenKind != line.kind {
                ShieldBanner(symbol: line.symbol, tint: line.tone == .practice ? .gray : line.tint,
                             title: line.isPractice ? "Go There practice" : "Go There Today",
                             message: line.text, messageIdentifier: "goDayStatus",
                             onClose: { withAnimation(.snappy(duration: 0.2)) { hiddenKind = line.kind } }) {
                    if line.canUndo {
                        Button("Undo") { _ = model.undoGoDay() }
                            .buttonStyle(ShieldFilledButtonStyle())
                            .accessibilityIdentifier("undoGoDay")
                    }
                    if line.isPractice {
                        Button("End Practice") { model.endGoDayPractice() }
                            .accessibilityIdentifier("endGoDayPractice")
                    }
                }
                .accessibilityIdentifier("goDayBar")
            }
        }
    }
}

struct GoDayLine: Equatable {
    enum Tone { case waiting, done, warning, practice }
    var symbol: String
    var tone: Tone
    var text: String
    var canUndo = false
    var isPractice = false

    /// What the × hides: this kind of line, not each tick of its countdown.
    var kind: String { "\(tone)-\(isPractice)-\(canUndo)" }

    var tint: Color {
        switch tone {
        case .waiting: ShieldGroupKind.location.tint
        case .done: .green
        case .warning: .orange
        case .practice: .secondary
        }
    }
}

private extension View {
    /// One Go There Today card: soft fill, thin edge.
    func goDayCard() -> some View {
        self.padding(.horizontal, 14).padding(.vertical, 12)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))
    }
}
