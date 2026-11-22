import MapKit
import SwiftUI

/// The one way to add a place: search or click the map, size the circle,
/// name it. "Use My Location" drops the pin where this Mac is and, when the
/// reading is precise, saves the Wi-Fi seen here, so Shield can later tell
/// the user is really at the place rather than merely near the pin.
///
/// Both outcomes are existing service commands: `addPlaceHere` (with Wi-Fi)
/// or `addMapPlace` (pin only). The sheet only chooses which, and says so.
struct PlaceEditor: View {
    let model: ShieldViewModel
    /// Off where "here" can't be used (Go There needs a place you aren't at yet).
    var offersHere = true
    var onAdded: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var pin: CLLocationCoordinate2D?
    /// The pin came from this Mac's own reading, not a search or a click.
    @State private var pinIsHere = false
    @State private var radius: Double = 200
    @State private var camera: MapCameraPosition = .automatic
    /// What the map shows now; searches look here, not around this Mac's own fix.
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var awaiting: UUID?
    @State private var addedID: String?
    @State private var problem: String?
    @State private var openedAt = Date.now
    /// Use My Location was pressed before this Mac had a reading: drop the pin when it arrives.
    @State private var wantsMyLocation = false

    private var sensor: LocationSensor? { model.locationSensor }
    /// Fresh and precise enough to enroll right now (the service's own bar).
    private var hasPreciseFix: Bool { sensor?.latestFix?.goodForEnrollment() ?? false }
    /// Precise, however old: a stale reading gets refreshed, not downgraded.
    private var readingIsPrecise: Bool {
        guard let fix = sensor?.latestFix else { return false }
        return !fix.isSimulated && fix.horizontalAccuracy > 0 && fix.horizontalAccuracy <= 100
    }
    private var wifiReady: Bool {
        sensor.map { $0.hasTagKey && ($0.wifiCheckedAt.map { $0 >= openedAt } ?? false) } ?? false
    }
    private var wifiTags: Set<String> {
        guard let sensor else { return [] }
        return PresenceReportBuilder.enrollmentTags(connected: sensor.connectedTag, visible: sensor.visibleTags)
    }
    /// The user asked for this spot, and it can be checked in person (precise, with Wi-Fi keys).
    private var wantsHere: Bool {
        pinIsHere && sensor?.access == .allowed && readingIsPrecise && sensor?.hasTagKey == true
    }
    /// Saved with this spot's Wi-Fi: only the Mac's own precise reading, with Wi-Fi actually seen.
    private var checksOnSite: Bool { wantsHere && wifiReady && !wifiTags.isEmpty }
    /// Unlocked again once Shield stops waiting, so Check and Try Again work.
    private var formLocked: Bool {
        guard let awaiting else { return false }
        return model.submissionState != .unconfirmed(awaiting)
    }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 0) {
            EditorSheetHeader(symbol: "mappin.and.ellipse", tint: model.locationCategory.color.color, title: "Add a Place",
                              subtitle: "")
            VStack(alignment: .leading, spacing: 10) {
                searchBar
                if !results.isEmpty { resultList }
                map
                HStack(spacing: 10) {
                    Text("Size")
                    // A checked place is at least 200 m: the reading itself may be 100 m off.
                    Slider(value: $radius, in: (pinIsHere ? 200 : GoDayGate.radiusRange.lowerBound)...GoDayGate.radiusRange.upperBound,
                           step: 50)
                        .accessibilityIdentifier("placeSize")
                        .accessibilityValue(radiusText)
                    Text(radiusText).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
                }
                TextField("Name", text: $name, prompt: Text("Name, like Library"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mapPlaceName")
                assurance
                if let problem {
                    Text(problem).foregroundStyle(.orange).font(.callout).accessibilityIdentifier("placeProblem")
                }
                if let id = awaiting, model.submissionState == .unconfirmed(id) {
                    HStack {
                        Text("Shield didn't hear back.").foregroundStyle(.secondary)
                        Button("Check") { model.refresh() }
                        Button("Try Again") { model.retryPendingSubmission() }.disabled(!model.canRetryPendingSubmission)
                    }
                    .font(.callout)
                }
            }
            .padding(.horizontal, 20).padding(.top, 6)
            .disabled(formLocked)

            HStack {
                if model.isSubmittingPolicy && awaiting != nil { ProgressView().controlSize(.small) }
                Spacer()
                Button(awaiting == nil ? "Cancel" : "Close") { dismiss() }.keyboardShortcut(.cancelAction)
                // Not the default button: Return in the search field searches, never adds.
                Button("Add Place") { add() }
                    .buttonStyle(.prominentWhenEnabled)
                    .disabled(pin == nil || trimmedName.isEmpty || awaiting != nil || !model.canSubmitPolicy ||
                              (wantsHere && !wifiReady))
                    .accessibilityIdentifier("confirmMapPlace")
            }
            .shieldSheetFooter()
        }
        .frame(width: 580)
        .shieldSheet()
        .frame(minHeight: 520, idealHeight: 640)
        .onAppear {
            openedAt = .now
            // Open where you are; without a reading, at your first saved place
            // (often home); only then wherever the map defaults.
            if sensor?.latestFix != nil {
                centerOnThisMac(zoom: 6_000)
            } else if let place = model.locationPolicy.places.first {
                camera = .region(MKCoordinateRegion(center: .init(latitude: place.latitude, longitude: place.longitude),
                                                    latitudinalMeters: 6_000, longitudinalMeters: 6_000))
            }
        }
        .task {
            // While the pin is this Mac's reading, keep the fix and Wi-Fi fresh.
            while !Task.isCancelled {
                if pinIsHere {
                    sensor?.keepFixFresh(olderThan: 20)
                    if !wifiReady || sensor?.wifiCheckedAt.map({ Date.now.timeIntervalSince($0) > 45 }) == true {
                        sensor?.scanWiFi()
                    }
                }
                try? await Task.sleep(for: .seconds(8))
            }
        }
        // The pin is this Mac: it follows newer readings, so what's saved is what's shown.
        .onChange(of: sensor?.latestFix) { old, fix in
            if wantsMyLocation, fix != nil { useMyLocation(); return }
            // The first reading after opening: move there unless a spot was already chosen.
            if old == nil, fix != nil, pin == nil, results.isEmpty { centerOnThisMac(zoom: 6_000) }
            guard pinIsHere, let fix else { return }
            pin = .init(latitude: fix.latitude, longitude: fix.longitude)
        }
        .onChange(of: pinIsHere) { _, here in if here { radius = max(radius, 200) } }
        .onChange(of: model.submissionState) { _, state in
            guard let awaiting else { return }
            if state == .confirmed(awaiting) {
                if let addedID { onAdded(addedID) }
                dismiss()
            } else if state == .failed(awaiting) {
                problem = model.backendActionMessage
                self.awaiting = nil
            }
        }
    }

    // MARK: Pieces

    private var radiusText: String {
        Measurement(value: radius, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

    private var searchBar: some View {
        HStack {
            TextField("Search", text: $query, prompt: Text("Search for a library, a café, an address…"))
                .textFieldStyle(.roundedBorder)
                .onSubmit { search() }
                .accessibilityIdentifier("mapSearch")
            if searching { ProgressView().controlSize(.small) }
            if offersHere {
                Button { useMyLocation() } label: { Label("Use My Location", systemImage: "location") }
                    .help("Put the pin where this Mac is now")
                    .disabled(!model.supportsLocationRules)
                    .accessibilityIdentifier("placeUseMyLocation")
            }
        }
    }

    private var resultList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(results, id: \.self) { item in
                    Button { choose(item) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name ?? "Place")
                            if let address = item.placemark.title {
                                Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4).padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 120)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("mapResults")
    }

    private var map: some View {
        // Read here, not inside Map { }, so changes redraw at once (the same
        // fix as the Places map pins).
        let tint = model.locationCategory.color.color
        let saved = model.locationPolicy.places
        return MapReader { proxy in
            Map(position: $camera) {
                if let pin {
                    Marker(trimmedName.isEmpty ? "New place" : trimmedName, coordinate: pin)
                        .tint(tint)
                    MapCircle(center: pin, radius: radius)
                        .foregroundStyle(tint.opacity(0.18))
                        .stroke(tint, lineWidth: 1.5)
                }
                ForEach(saved) { place in
                    MapCircle(center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                              radius: place.radiusMeters)
                        .foregroundStyle(Color.secondary.opacity(0.12))
                        .stroke(Color.secondary.opacity(0.6), lineWidth: 1)
                }
                // Only once Location is allowed (Use My Location asks), so opening the sheet never prompts.
                if sensor?.access == .allowed { UserAnnotation() }
            }
            .mapControls { MapZoomStepper(); MapCompass() }
            // On the map itself, not the frame: the "Click to drop the pin" hint keeps its own identity.
            .accessibilityIdentifier("placeMap")
            .onMapCameraChange(frequency: .onEnd) { context in visibleRegion = context.region }
            .onTapGesture { point in
                if let coordinate = proxy.convert(point, from: .local) {
                    pin = coordinate
                    pinIsHere = false; wantsMyLocation = false
                }
            }
        }
        .frame(minHeight: 200, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .topLeading) {
            if pin == nil {
                Text("Click to drop the pin")
                    .font(.callout).padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }

    /// What this place will be good for, in one line, before it's added.
    @ViewBuilder private var assurance: some View {
        if pin != nil {
            if wantsHere && !wifiReady {
                Label("Checking nearby Wi-Fi…", systemImage: "wifi")
                    .accessibilityIdentifier("placeAssurance")
            } else if checksOnSite {
                Label("Checked here: Shield saves this spot's Wi-Fi, so it can tell you're really here.",
                      systemImage: "checkmark.seal")
                    .accessibilityIdentifier("placeAssurance")
            } else {
                if pinIsHere {
                    Text(!readingIsPrecise ? "This reading isn't precise, so the place is saved as a map place."
                         : "No Wi-Fi was seen here, so the place is saved as a map place.")
                        .foregroundStyle(.orange).font(.callout)
                }
                Label("Map place: works for blocking here and for Go There.",
                      systemImage: "map")
                    .accessibilityIdentifier("placeAssurance")
            }
        }
    }

    // MARK: Actions

    private func centerOnThisMac(zoom meters: Double) {
        if let fix = sensor?.latestFix {
            camera = .region(MKCoordinateRegion(center: .init(latitude: fix.latitude, longitude: fix.longitude),
                                                latitudinalMeters: meters, longitudinalMeters: meters))
        }
    }

    private func useMyLocation() {
        model.turnOnLocation()
        problem = nil
        guard let fix = sensor?.latestFix else {
            let denied = sensor?.access == .denied || sensor?.access == .restricted
            wantsMyLocation = !denied
            problem = denied ? "Turn on Location for Shield in System Settings." : "Finding where this Mac is…"
            return
        }
        wantsMyLocation = false
        pin = .init(latitude: fix.latitude, longitude: fix.longitude)
        pinIsHere = true
        openedAt = .now
        sensor?.scanWiFi()
        camera = .region(MKCoordinateRegion(center: .init(latitude: fix.latitude, longitude: fix.longitude),
                                            latitudinalMeters: 1_200, longitudinalMeters: 1_200))
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        // Bias results to the part of the map on screen; Apple's search never
        // receives this Mac's own location reading.
        if let visibleRegion { request.region = visibleRegion }
        searching = true
        // Only the latest search may show its results.
        searchTask?.cancel()
        searchTask = Task {
            let response = try? await MKLocalSearch(request: request).start()
            guard !Task.isCancelled else { return }
            searching = false
            results = Array((response?.mapItems ?? []).prefix(6))
            problem = results.isEmpty ? "Nothing found. Try another name, or click the map." : nil
        }
    }

    private func choose(_ item: MKMapItem) {
        let coordinate = item.placemark.coordinate
        pin = coordinate
        pinIsHere = false; wantsMyLocation = false
        if name.isEmpty { name = String((item.name ?? "").prefix(40)) }
        camera = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 1_200, longitudinalMeters: 1_200))
        results = []
    }

    private func add() {
        guard let pin else { return }
        problem = nil
        if checksOnSite {
            // Never quietly downgrade a checked place: refresh a stale reading and ask again.
            guard hasPreciseFix else {
                sensor?.keepFixFresh(olderThan: 0)
                problem = "Getting a fresh reading of where this Mac is… click Add Place again in a moment."
                return
            }
            let result = model.addPlaceHere(name: trimmedName, radiusMeters: radius, isHome: false)
            addedID = result?.placeID
            awaiting = result?.request
        } else {
            let result = model.addMapPlace(name: trimmedName, latitude: pin.latitude, longitude: pin.longitude,
                                           radiusMeters: radius)
            addedID = result?.placeID
            awaiting = result?.request
        }
        if awaiting == nil { problem = model.backendActionMessage }
    }
}
