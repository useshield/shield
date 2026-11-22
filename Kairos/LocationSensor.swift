import AppKit
import CoreLocation
import CoreWLAN
import CryptoKit
import Darwin
import Foundation

// The app is Shield's only location sensor (docs/conditional-rules-blueprint.md
// §6): the root service can't hold the Location privilege. The sensor sends
// evidence only. The service judges it, keeps verdicts (never coordinates),
// and decides every block. Raw Wi-Fi identifiers never leave this file: only
// keyed HMAC tags do. Nothing here starts until the user adds a place or
// asks to turn location on, so no permission prompt appears unasked.

// MARK: Pure pieces (unit-tested)

/// Keyed tags for Wi-Fi access points, so stored places never hold a raw BSSID.
struct WiFiTagger: Sendable {
    let key: SymmetricKey

    func tag(_ bssid: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(bssid.lowercased().utf8), using: key)
        return Data(code.prefix(16)).base64EncodedString()
    }

    /// The per-install key: 32 random bytes in a file only this user can read.
    /// An existing key is never replaced, even when it can't be read right
    /// now: a new key would orphan every saved place's Wi-Fi, one of the
    /// signals that keeps a place block on. Then this throws (no Wi-Fi tags).
    static func loadOrCreate(at url: URL) throws -> WiFiTagger {
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard data.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
            return WiFiTagger(key: SymmetricKey(data: data))
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(bytes)
        guard FileManager.default.createFile(atPath: url.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return WiFiTagger(key: SymmetricKey(data: data))
    }
}

/// One location fix, as the sensor saw it.
struct LocationFix: Sendable, Equatable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let observedAt: Date
    let isSimulated: Bool
}

extension LocationFix {
    /// Good enough to save a place from: real, precise and recent. A coarse
    /// first fix could put the saved centre far from the real place, and a
    /// later precise fix there would then read as "elsewhere".
    func goodForEnrollment(now: Date = .now) -> Bool {
        // 100 m keeps the true spot well inside the 200 m place, and is what a
        // Mac's Wi-Fi positioning usually reports indoors.
        !isSimulated && horizontalAccuracy > 0 && horizontalAccuracy <= 100 &&
            now.timeIntervalSince(observedAt) <= 30 && observedAt <= now.addingTimeInterval(5)
    }
}

enum PresenceReportBuilder {
    static let maximumVisibleTags = 40

    static func record(fix: LocationFix?, fullAccuracy: Bool, connectedTag: String?, visibleTags: [String],
                       sleptSinceLastReport: Bool, now: Date) -> PresenceEvidenceRecord {
        // A fix that isn't usable is not sent at all: the service then treats
        // location as unknown for "allow" rules, which is the strict reading.
        let usable = fix.flatMap { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy.isFinite ? $0 : nil }
        var visible: [String] = []
        for tag in visibleTags where !visible.contains(tag) && tag != connectedTag {
            visible.append(tag)
            if visible.count == maximumVisibleTags { break }
        }
        return PresenceEvidenceRecord(latitude: usable?.latitude, longitude: usable?.longitude,
                                      horizontalAccuracy: usable?.horizontalAccuracy,
                                      fixObservedAt: usable?.observedAt, isSimulated: usable?.isSimulated ?? false,
                                      fullAccuracy: fullAccuracy, observedAt: now, connectedWiFiTag: connectedTag,
                                      visibleWiFiTags: visible, sleptSinceLastEvidence: sleptSinceLastReport)
    }

    /// The service refuses a report unless its sequence rises within this boot,
    /// so it comes from a clock that never goes back, even across app restarts.
    static func report(_ record: PresenceEvidenceRecord) -> PresenceReport {
        PresenceReport(sequence: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW),
                       bootSessionID: PresenceSession.currentBootSessionID(),
                       uptimeNanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW), evidence: record)
    }

    /// Wi-Fi tags to enroll at a place: the connected network first, then the
    /// strongest visible ones.
    static func enrollmentTags(connected: String?, visible: [String]) -> Set<String> {
        var tags = Set(connected.map { [$0] } ?? [])
        for tag in visible where tags.count < 24 { tags.insert(tag) }
        return tags
    }
}

// MARK: The sensor

@MainActor
@Observable
final class LocationSensor: NSObject, CLLocationManagerDelegate {
    enum Access: Equatable {
        case notAsked, allowed, approximateOnly, denied, restricted
    }

    private(set) var access: Access = .notAsked
    private(set) var latestFix: LocationFix?
    private(set) var connectedTag: String?
    private(set) var visibleTags: [String] = []
    /// When the last finished Wi-Fi scan started. Cleared on sleep and wake:
    /// tags seen before describe where the Mac fell asleep.
    private(set) var wifiCheckedAt: Date?
    @ObservationIgnored private var rescanRequested = false
    private(set) var isRunning = false
    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private let tagger: WiFiTagger?
    @ObservationIgnored private var sleptSinceLastReport = false
    @ObservationIgnored private var scanInFlight = false
    @ObservationIgnored private var sleepObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var lastRestart: Date?

    init(keyURL: URL) {
        tagger = try? WiFiTagger.loadOrCreate(at: keyURL)
        super.init()
    }

    /// Starts sensing. The first call is what shows macOS's Location prompt.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        self.manager = manager
        updateAccess(manager)
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sleptSinceLastReport = true
                    self?.latestFix = nil  // where the Mac fell asleep says nothing about where it wakes
                    // Wi-Fi seen before sleep says nothing about where the Mac wakes.
                    self?.connectedTag = nil
                    self?.visibleTags = []
                    self?.wifiCheckedAt = nil
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.latestFix = nil  // a fix from before sleep proves nothing now
                    self?.connectedTag = nil
                    self?.visibleTags = []
                    self?.wifiCheckedAt = nil
                    self?.scanWiFi()
                    self?.keepFixFresh()
                }
            },
        ]
        scanWiFi()
    }

    func stop() {
        manager?.stopUpdatingLocation()
        manager = nil
        isRunning = false
        sleepObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        sleepObservers = []
    }

    var hasTagKey: Bool { tagger != nil }

    /// macOS stops sending fixes while the Mac sits still, and the service
    /// treats a fix older than two minutes as unknown (place blocks hold). Ask
    /// for a new one well before that.
    func keepFixFresh(now: Date = .now, olderThan age: TimeInterval = 30) {
        guard let manager, access == .allowed,
              latestFix.map({ now.timeIntervalSince($0.observedAt) > age }) ?? true,
              lastRestart.map({ now.timeIntervalSince($0) > 30 || now < $0 }) ?? true else { return }
        lastRestart = now
        manager.stopUpdatingLocation()
        manager.startUpdatingLocation()
    }

    /// Whether the user has already answered macOS's Location prompt for this
    /// app. Asking this never shows the prompt.
    static var wasAnswered: Bool { CLLocationManager().authorizationStatus != .notDetermined }

    /// Evidence for one report. Reading it clears the "slept" flag, so exactly
    /// the first report after a wake says so (and restarts dwell, strict).
    func takeEvidence(now: Date = .now) -> PresenceEvidenceRecord {
        defer { sleptSinceLastReport = false }
        return PresenceReportBuilder.record(fix: latestFix, fullAccuracy: manager?.accuracyAuthorization == .fullAccuracy,
                                            connectedTag: connectedTag, visibleTags: visibleTags,
                                            sleptSinceLastReport: sleptSinceLastReport, now: now)
    }

    /// Re-reads nearby Wi-Fi off the main thread (a scan takes a few seconds).
    func scanWiFi() {
        guard let tagger else { return }
        guard !scanInFlight else {
            rescanRequested = true  // the running scan may predate what the caller needs
            return
        }
        scanInFlight = true
        let startedAt = Date.now
        Task.detached(priority: .utility) { [weak self] in
            let interface = CWWiFiClient.shared().interface()
            let connected = interface?.bssid().map(tagger.tag)
            let networks = (try? interface?.scanForNetworks(withSSID: nil)) ?? []
            let visible = networks.sorted { $0.rssiValue > $1.rssiValue }.compactMap { $0.bssid.map(tagger.tag) }
            await self?.finishScan(connected: connected, visible: visible, startedAt: startedAt)
        }
    }

    private func finishScan(connected: String?, visible: [String], startedAt: Date) {
        scanInFlight = false
        let changed = connected != connectedTag || visible != visibleTags
        connectedTag = connected
        visibleTags = visible
        wifiCheckedAt = startedAt
        if changed { onChange?() }
        if rescanRequested {
            rescanRequested = false
            scanWiFi()
        }
    }

    private func updateAccess(_ manager: CLLocationManager) {
        access = switch manager.authorizationStatus {
        case .notDetermined: .notAsked
        case .denied: .denied
        case .restricted: .restricted
        default: manager.accuracyAuthorization == .fullAccuracy ? .allowed : .approximateOnly
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            updateAccess(manager)
            // Turned off: the last fix stops counting at once (it would otherwise
            // keep the Mac "known" for up to 2 minutes). Unknown keeps place blocks on.
            if access == .denied || access == .restricted || access == .approximateOnly { latestFix = nil }
            // Allowed again in System Settings: start fixes now, not at next launch.
            if access == .allowed || access == .approximateOnly { manager.startUpdatingLocation() }
            scanWiFi()
            onChange?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let fix = LocationFix(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                              horizontalAccuracy: location.horizontalAccuracy, observedAt: location.timestamp,
                              isSimulated: location.sourceInformation?.isSimulatedBySoftware ?? false)
        MainActor.assumeIsolated {
            latestFix = fix
            onChange?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            // No fix means unknown, which keeps place rules strict.
            if (error as? CLError)?.code == .denied { latestFix = nil }
            updateAccess(manager)
            onChange?()
        }
    }
}
