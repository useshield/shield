import AppKit
import MapKit
import SwiftUI

// Places: a map of the user's places, a readable list, and one page per
// place with what's blocked there. A place is used by New Block Here on
// its page, or Where in a category's New Block. States come from the service's snapshot, never the sensor's guess.

enum LocationPresentation {
    enum Problem: Equatable { case needsPrecise, off, reportFailed, notRunning }

    /// The one location warning Places shows, or none. Nothing blocked at a
    /// place means where the Mac is doesn't matter: no warning at all.
    static func problem(access: LocationSensor.Access?, tracked: Bool, reportFailed: Bool,
                        sensorRunning: Bool, locationUsable: Bool) -> Problem? {
        guard tracked else { return nil }
        if access == .approximateOnly { return .needsPrecise }
        if access == .denied || access == .restricted { return .off }
        if reportFailed { return .reportFailed }
        if !sensorRunning && !locationUsable { return .notRunning }
        return nil
    }

    enum Whereabouts: Equatable { case here, notHere, unknown }

    static func whereabouts(_ place: RulePlace, presence: PresenceSnapshot?, now: Date) -> Whereabouts {
        guard let presence, presence.locationUsable(at: now), let state = presence.places[place.id] else { return .unknown }
        return state.indicated || state.qualified ? .here : .notHere
    }

    /// The line at the top of the Places page, from the service's record only.
    /// `tracked`: the service records where this Mac is only while a block or
    /// rule uses a place; with none, "unknown" isn't a problem worth a headline.
    static func headline(access: LocationSensor.Access?, places: [RulePlace], presence: PresenceSnapshot?,
                         tracked: Bool = true, now: Date) -> String {
        // A plain fact, kept from 279; the orange warning (problem(...)) is what
        // stays quiet when nothing uses a place.
        if access == .denied || access == .restricted { return "Location is off for Shield" }
        guard !places.isEmpty else { return "No places yet" }
        guard let presence, presence.locationUsable(at: now) else { return tracked ? "Location unknown" : "Your places" }
        let here = places.filter { whereabouts($0, presence: presence, now: now) == .here }
        return here.first.map { "At \($0.name)" } ?? "Not at any of your places"
    }

    /// A place page's "Right now" line. Unknown says why: nothing uses a place
    /// yet (so the service isn't checking), Location is off, or no fresh reading.
    static func rightNow(_ place: RulePlace, presence: PresenceSnapshot?, tracked: Bool, locationOn: Bool,
                         now: Date) -> String {
        switch whereabouts(place, presence: presence, now: now) {
        case .here: return "You're here"
        case .notHere: return "You're somewhere else"
        case .unknown:
            // Short: it sits on the map. Unknown still means blocks here stay on.
            if !tracked { return "Not checked" }
            if !locationOn { return "Location off" }
            return "Location unknown"
        }
    }

    /// A place row's short status.
    static func rowStatus(_ whereabouts: Whereabouts, tracked: Bool) -> String {
        switch whereabouts {
        case .here: "Here now"
        case .notHere: "Not here"
        case .unknown: tracked ? "Location unknown" : "Not checked"
        }
    }
}

enum PlaceDates {
    /// "3:27 PM" today, "tomorrow 3:27 PM", otherwise "Nov 2, 3:27 PM".
    static func short(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        // In the schedule's time zone, the same one that decides "tomorrow".
        var timeStyle = Date.FormatStyle(date: .omitted, time: .shortened)
        timeStyle.timeZone = calendar.timeZone
        let time = date.formatted(timeStyle)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow \(time)"
        }
        var dayStyle = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        dayStyle.timeZone = calendar.timeZone
        return date.formatted(dayStyle)
    }
}

struct PlacesView: View {
    let model: ShieldViewModel
    @State private var adding = false
    @State private var editingPlace: RulePlace?
    @State private var goingThere = false

    private var places: [RulePlace] { model.locationPolicy.places.sorted { $0.name < $1.name } }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in page }
    }

    private var page: some View {
        ShieldBubblePage(maxWidth: 760) {
            // Same recovery as Protection: an unconfirmed place change can be checked here.
            if PolicyActionNotice(model: model).isVisible ||
                model.submissionRecordError != nil ||
                (model.pendingSubmission != nil && !model.isSubmittingPolicy) {
                VStack(alignment: .leading, spacing: 10) {
                    PolicyActionNotice(model: model)
                    PolicySubmissionRecoveryView(model: model)
                }
                .shieldBubble()
            }
            if !model.supportsLocationRules {
                ShieldEmptyState(title: "Places aren't available", symbol: "mappin.slash",
                                 message: "This version of Shield can't use location.", tint: .secondary)
            } else if places.isEmpty {
                ShieldEmptyState(title: "No places yet", symbol: "mappin.and.ellipse",
                                 message: "Add home, school or work to block things there.",
                                 tint: model.locationCategory.color.color) {
                    Button("Add a Place…") { adding = true }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("addFirstPlace")
                }
            } else {
                PlacesOverviewMap(places: places, presence: model.locationPolicy.presence,
                                  showsYou: model.locationSensor?.access == .allowed,
                                  looks: model.placeLooks)
                    .frame(height: 260)
                    .clipShape(ShieldBubble.shape)
                    .overlay(ShieldBubble.shape.strokeBorder(Color.shieldCardBorder))
                    .accessibilityIdentifier("placesMap")
                // Each row says "Here now"; the heading speaks only when location is unknown or off.
                let headline = LocationPresentation.headline(access: model.locationSensor?.access, places: places,
                                                             presence: model.locationPolicy.presence,
                                                             tracked: model.checksWhereabouts, now: .now)
                BubbleSection(title: headline == "Location unknown" || headline == "Location is off for Shield" ? headline : "Your places",
                              spacing: 8) {
                    ForEach(places) { place in
                        NavigationLink(value: "place:" + place.id) {
                            HStack(spacing: 10) {
                                PlaceRow(model: model, place: place)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary).accessibilityHidden(true)
                            }
                            .shieldBubble(padding: 12)
                        }
                        .buttonStyle(BubbleLinkStyle())
                        .contextMenu {
                            Button("Edit Place…") { editingPlace = place }
                                .accessibilityIdentifier("editPlaceFromList")
                        }
                        .accessibilityIdentifier("place-\(place.id)")
                    }
                }
                LocationProblemSection(model: model)
            }
        }
        .navigationTitle("Places")
        .toolbar {
            // Opens even when changes aren't possible; its Add button says no.
            AddAndMoreToolbar(add: AddMenuButton(items: [
                AddMenuItem(title: "Add a Place…", identifier: "addPlaceItem", enabled: model.supportsLocationRules) {
                    adding = true
                },
            ], help: "Add a place from the map", identifier: "addPlaceOnMap")) {
                Menu {
                    if model.supportsGoDays {
                        Button { model.requestLocation { goingThere = true } } label: {
                            Label("Go There Today…", systemImage: "figure.walk")
                        }
                        .disabled(!model.canSubmitPolicy)
                        .help("Keep browsers closed until you get to a place you pick")
                        .accessibilityIdentifier("goThereTodayFromPlaces")
                    }
                    Button("Location Settings…") { LocationProblemSection.openLocationSettings() }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
                .help("More")
                .accessibilityLabel("More")
                .accessibilityIdentifier("placesMoreMenu")
            }
        }
        .sheet(isPresented: $adding) { PlaceEditor(model: model) }
        .sheet(item: $editingPlace) { place in EditPlaceSheet(model: model, place: place) }
        .sheet(isPresented: $goingThere) { GoDayStartSheet(model: model) }
    }
}

/// One saved place: name, where you are relative to it, and what it's used for.
struct PlaceRow: View {
    let model: ShieldViewModel
    let place: RulePlace

    var body: some View {
        let locks = model.blocksUsing(place: place.id)
        let removal = model.pendingLocationChange(place: place.id)
        let whereabouts = LocationPresentation.whereabouts(place, presence: model.locationPolicy.presence, now: .now)
        var detail = [LocationPresentation.rowStatus(whereabouts, tracked: model.checksWhereabouts)]
        if locks > 0 { detail.append(locks == 1 ? "1 block" : "\(locks) blocks") }
        if let removal {
            let when = PlaceDates.short(removal.effectiveAt, calendar: model.scheduleCalendar)
            detail.append((removal.replacementPlace == nil ? "Removed " : "Changes ") + when)
        }
        return HStack(spacing: ShieldMetrics.rowSpacing) {
            let style = model.placeStyle(place)
            CategoryIcon(symbol: style.symbol, tint: style.color.color, size: ShieldMetrics.rowIcon)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).fontWeight(.medium)
                Text(detail.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            PlaceKindBadge(place: place)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// "Checked here" for places saved with their Wi-Fi; nothing for map-only places.
struct PlaceKindBadge: View {
    let place: RulePlace
    var body: some View {
        // "Map place" on every row meant nothing to anyone.
        // Only the extra, Wi-Fi-checked kind gets a mark.
        if !place.wifiTags.isEmpty {
            Label("Checked here", systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Saved with this place's Wi-Fi, so Shield can tell you're really there.")
        }
    }
}

/// Every place drawn as its circle, with a pin label; here-now places tinted.
struct PlacesOverviewMap: View {
    let places: [RulePlace]
    let presence: PresenceSnapshot?
    var highlight: String? = nil
    /// Only when Location is already allowed: MapKit's own "you are here"
    /// dot would otherwise ask for Location just because Places was opened.
    var showsYou = false
    /// Each place's own icon and colour, by place ID. A plain value (not a
    /// closure) so the map redraws the moment a look changes.
    var looks: [String: PlaceStyle] = [:]
    @State private var position: MapCameraPosition = .automatic

    private struct Pin: Identifiable {
        let place: RulePlace
        let look: PlaceStyle
        let here: Bool
        // Changes whenever the look changes, so MapKit swaps the marker at once.
        var id: String { "\(place.id)|\(look.symbol)|\(look.color.rawValue)|\(here)" }
    }

    var body: some View {
        let pins = places.map { place in
            Pin(place: place,
                look: looks[place.id] ?? PlaceStyle(symbol: "mappin.and.ellipse", color: .purple),
                here: LocationPresentation.whereabouts(place, presence: presence, now: .now) == .here)
        }
        Map(position: $position) {
            ForEach(pins) { pin in
                let center = CLLocationCoordinate2D(latitude: pin.place.latitude, longitude: pin.place.longitude)
                let tint = pin.look.color.color
                // The pin always wears its colour; the circle is stronger where you are.
                let strong = pin.here || pin.place.id == highlight
                MapCircle(center: center, radius: pin.place.radiusMeters)
                    .foregroundStyle(tint.opacity(strong ? 0.22 : 0.10))
                    .stroke(tint.opacity(strong ? 1 : 0.5), lineWidth: 1.5)
                Marker(pin.place.name, systemImage: pin.look.symbol, coordinate: center).tint(tint)
            }
            if showsYou { UserAnnotation() }
        }
        .mapControls { MapZoomStepper() }
        // Reframe when places are added or removed.
        .onChange(of: places.map(\.id), initial: true) { position = .rect(Self.rect(places)) }
    }

    /// A box around all the places, with room for their circles.
    static func rect(_ places: [RulePlace]) -> MKMapRect {
        let rects = places.map { place -> MKMapRect in
            let point = MKMapPoint(CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude))
            let size = place.radiusMeters * MKMapPointsPerMeterAtLatitude(place.latitude) * 6
            return MKMapRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        }
        let union = rects.dropFirst().reduce(rects.first ?? .world) { $0.union($1) }
        guard !places.isEmpty else { return union }
        // Margin so circles and their labels at the edges aren't cut off.
        return union.insetBy(dx: -union.width * 0.25, dy: -union.height * 0.35)
    }
}

/// Location permission problems, shown under the list.
struct LocationProblemSection: View {
    let model: ShieldViewModel

    var body: some View {
        switch LocationPresentation.problem(access: model.locationSensor?.access, tracked: model.checksWhereabouts,
                                            reportFailed: model.locationReportProblem != nil,
                                            sensorRunning: model.locationSensor?.isRunning == true,
                                            locationUsable: model.locationPolicy.presence?.locationUsable(at: .now) == true) {
        case .none:
            EmptyView()
        case .needsPrecise:
            problem("Shield needs Precise Location to tell where you are.") {
                Button("Open Settings") { Self.openLocationSettings() }
            }
        case .off:
            problem("Turn on Location for Shield in System Settings. Until then, place blocks stay on.") {
                Button("Open Settings") { Self.openLocationSettings() }
            }
        case .reportFailed:
            // The service's own wording stays in the tooltip for diagnosis.
            problem("Shield couldn't check where you are just now. Place blocks stay on, and it keeps trying.") {
                EmptyView()
            }
            .help(model.locationReportProblem ?? "")
        case .notRunning:
            problem("Location isn't on, so Shield treats every place block as on.", warning: false) {
                Button("Turn On Location") { model.requestLocation() }
                    .accessibilityIdentifier("turnOnLocation")
            }
        }
    }

    private func problem<Action: View>(_ text: String, warning: Bool = true,
                                       @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            action()
        }
        .shieldBubble(padding: 14)
    }

    static func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - One place

struct PlaceDetailPage: View {
    let placeID: String
    let model: ShieldViewModel
    @State private var lockingHere = false
    /// A copy taken when Edit opens, so a refresh can't blank the sheet.
    @State private var editingPlace: RulePlace?
    @State private var removing = false
    @State private var keepingPlace: String?

    private var place: RulePlace? { model.locationPolicy.places.first { $0.id == placeID } }
    private var locks: [DomainRestriction] {
        (model.backendSnapshot?.committedRestrictions ?? []).filter { $0.placeID == placeID }
    }
    /// Locks and place rules both keep a place from being removed (the service refuses).
    private var inUse: Bool {
        !locks.isEmpty || model.locationPolicy.rules.contains { $0.placeIDs.contains(placeID) }
    }

    var body: some View {
        // "Right now" ages out after two minutes without a report: keep it current.
        TimelineView(.periodic(from: .now, by: 15)) { _ in page }
    }

    private var page: some View {
        // Calm and short. The map with where you are on it, the
        // blocks set here, and nothing else. Adding goes in the blue +, Edit
        // and Remove Place in the ⋯ menu, like every other page.
        ShieldBubblePage(maxWidth: 760) {
            if PolicyActionNotice(model: model).isVisible {
                PolicyActionNotice(model: model).shieldBubble()
            }
            if let place {
                PlacesOverviewMap(places: [place], presence: model.locationPolicy.presence, highlight: place.id,
                                  showsYou: model.locationSensor?.access == .allowed,
                                  looks: model.placeLooks)
                    .frame(height: 200)
                    .clipShape(ShieldBubble.shape)
                    .overlay(ShieldBubble.shape.strokeBorder(Color.shieldCardBorder))
                    .overlay(alignment: .topLeading) {
                        Text(whereText(place))
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                            .padding(10)
                            .accessibilityIdentifier("placeWhereabouts")
                    }
                if let removal = model.pendingLocationChange(place: place.id) {
                    HStack(spacing: 10) {
                        Text((removal.replacementPlace == nil ? "Removed " : "Changes ")
                             + PlaceDates.short(removal.effectiveAt, calendar: model.scheduleCalendar))
                            .fontWeight(.medium)
                        Spacer()
                        Button("Keep Place…") { keepingPlace = removal.policyID }
                            .disabled(!model.canSubmitPolicy)
                    }
                    .shieldBubble(padding: 14)
                }
                BubbleSection(title: "Blocked here") {
                    if locks.isEmpty {
                        Text("Nothing blocked here").foregroundStyle(.secondary)
                            .shieldBubble(padding: 14)
                    }
                    // The same rows as a category page: click shows websites, Edit holds the rest.
                    ForEach(locks) { lock in
                        RestrictionRuleRow(rules: [lock], model: model)
                            .shieldBubble(padding: 14)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("placeLock-\(lock.policyID)")
                    }
                }
            } else {
                ShieldEmptyState(title: "Place removed", symbol: "mappin.slash", tint: .secondary)
            }
        }
        .navigationTitle(place?.name ?? "Place")
        .toolbar {
            if let place {
                AddAndMoreToolbar(add: AddMenuButton(items: [
                    AddMenuItem(title: "New Block Here…", identifier: "placeLockHere",
                                enabled: model.pendingLocationChange(place: place.id) == nil) { lockingHere = true },
                ], help: "Block websites or apps while you're at \(place.name)", identifier: "placeAddMenu")) {
                    Menu {
                        Button("Edit Place…") { editingPlace = place }
                            .accessibilityIdentifier("editPlace")
                        Divider()
                        Button("Remove Place…", role: .destructive) { removing = true }
                            .disabled(!model.canSubmitPolicy || inUse || model.pendingLocationChange(place: place.id) != nil)
                            .help(inUse ? "Remove the blocks set here first" : "Removing takes 24 hours")
                            .accessibilityIdentifier("removePlace")
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .help("Edit or remove this place")
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("placeMoreMenu")
                }
            }
        }
        .sheet(isPresented: $lockingHere) { BlockEditor(model: model, placeID: placeID) }
        .sheet(item: $editingPlace) { place in EditPlaceSheet(model: model, place: place) }
        .shieldConfirmation(isPresented: $removing) {
            ShieldConfirmation(symbol: "mappin.slash", tint: ShieldGroupKind.location.tint,
                               title: "Remove \(place?.name ?? "this place")?",
                               message: "It stays for 24 hours, then it's removed.",
                               confirmTitle: "Remove After 24 Hours", destructive: true,
                               confirmIdentifier: "confirmRemovePlace") { _ = model.removePlace(placeID) }
        }
        .shieldConfirmation(isPresented: Binding(get: { keepingPlace != nil }, set: { if !$0 { keepingPlace = nil } })) {
            let policyID = keepingPlace ?? ""
            return ShieldConfirmation(symbol: "mappin.circle.fill", tint: ShieldGroupKind.location.tint,
                                      title: "Keep \(place?.name ?? "this place")?",
                                      message: "It won't be removed. Removing it later means waiting 24 hours again.",
                                      confirmTitle: "Keep Place",
                                      confirmIdentifier: "confirmKeepPlace") { _ = model.cancelPendingChange(policyID) }
        }
    }

    private func whereText(_ place: RulePlace) -> String {
        let sensor = model.locationSensor
        return LocationPresentation.rightNow(place, presence: model.locationPolicy.presence,
                                             tracked: model.checksWhereabouts,
                                             locationOn: sensor?.isRunning == true && sensor?.access == .allowed, now: .now)
    }
}

/// A place's own icon and colour. Shown on Places rows and map pins; it changes
/// nothing about blocking, so it saves at once with no service round trip.
struct PlaceStyle: Codable, Equatable, Sendable {
    var symbol: String
    var color: ShieldCategoryColor

    static let key = "Shield.PlaceStyles"
    static let symbols = [
        "house.fill", "building.2.fill", "building.columns.fill", "books.vertical.fill", "graduationcap.fill",
        "briefcase.fill", "cup.and.saucer.fill", "fork.knife", "cart.fill", "dumbbell.fill",
        "bed.double.fill", "car.fill", "tram.fill", "airplane", "tree.fill",
        "sun.max.fill", "heart.fill", "star.fill", "person.2.fill", "mappin.and.ellipse",
    ]

    static func loadAll(_ defaults: UserDefaults = .standard) -> [String: PlaceStyle] {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode([String: PlaceStyle].self, from: data) else { return [:] }
        return saved.filter { symbols.contains($0.value.symbol) }
    }

    static func saveAll(_ styles: [String: PlaceStyle], to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(styles) { defaults.set(data, forKey: key) }
    }
}

/// One sheet for everything about how a place looks: name, colour and icon
/// They belong together, not as separate menu items.
/// The look saves locally at once; a new name goes to the service like before.
struct EditPlaceSheet: View {
    let model: ShieldViewModel
    let place: RulePlace
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbol: String
    @State private var color: ShieldCategoryColor
    @State private var problem: String?

    init(model: ShieldViewModel, place: RulePlace) {
        self.model = model
        self.place = place
        let current = model.placeStyle(place)
        _name = State(initialValue: place.name)
        _symbol = State(initialValue: current.symbol)
        _color = State(initialValue: current.color)
    }

    /// Renaming waits while the place has a change on its way, or the service is busy.
    private var canRename: Bool {
        model.canSubmitPolicy && model.pendingLocationChange(place: place.id) == nil
    }

    private var cleaned: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            EditorSheetHeader(symbol: symbol, tint: color.color,
                              title: cleaned.isEmpty ? place.name : cleaned, subtitle: "")
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text(place.name))
                        .disabled(!canRename)
                        .onSubmit(save)
                        .onChange(of: name) { _, new in
                            // The service keeps 40 characters; don't let more be typed.
                            if new.count > 40 { name = String(new.prefix(40)) }
                            problem = nil
                        }
                        .accessibilityIdentifier("placeEditorName")
                } footer: {
                    if let problem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                            .accessibilityIdentifier("placeEditorProblem")
                    } else if !canRename {
                        Text("The name can be changed once this place's pending change finishes.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Color") { ColorSwatches(selection: $color, identifierPrefix: "placeColor") }
                Section("Icon") { SymbolGrid(symbols: PlaceStyle.symbols, selection: $symbol, tint: color.color) }
            }
            .formStyle(.bubble)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancelPlaceEditor")
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleaned.isEmpty)
                    .accessibilityIdentifier("savePlaceEditor")
            }
            .shieldSheetFooter()
        }
        .frame(minWidth: 480, idealWidth: 520, maxWidth: 640, minHeight: 440, idealHeight: 500, maxHeight: 700)
        .shieldSheet()
    }

    private func save() {
        guard !cleaned.isEmpty else { return }
        model.setPlaceStyle(PlaceStyle(symbol: symbol, color: color), for: place.id)
        if canRename, cleaned != place.name, model.renamePlace(place.id, to: cleaned) == nil {
            // Stay open and say why (name taken, service busy) instead of
            // closing as if it worked. The look is already saved.
            problem = model.backendActionMessage ?? "That name couldn't be saved."
            return
        }
        dismiss()
    }
}
