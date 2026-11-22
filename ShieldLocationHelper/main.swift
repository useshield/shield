import CoreLocation
import CoreWLAN
import CryptoKit
import Foundation

// Per-user location sensor for conditional rules (docs/conditional-rules-blueprint.md §4).
// A root daemon cannot hold the Location privilege, so this small signed helper
// samples Core Location and Wi-Fi once a minute and writes evidence only: it has
// no policy authority and cannot change any block. NOT installed or launched by
// any target yet; building it requires an Info.plist with
// NSLocationUsageDescription and the user's approval to prompt for Location access.
// Output: one JSON object per line on stdout, consumed by the authority over XPC
// in a later step. Raw BSSIDs never leave this process; only HMAC tags do.

struct EvidenceRecord: Encodable {
    let schemaVersion = 1
    let observedAt: Date
    let authorization: String
    let fullAccuracy: Bool
    let latitude: Double?
    let longitude: Double?
    let horizontalAccuracy: Double?
    let fixAgeSeconds: Double?
    let isSimulated: Bool
    let connectedWiFiTag: String?
    let visibleWiFiTags: [String]
}

final class Sensor: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let salt: SymmetricKey
    private var latest: CLLocation?

    init(salt: SymmetricKey) {
        self.salt = salt
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.emit() }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        latest = locations.last
    }

    private func tag(_ bssid: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(bssid.lowercased().utf8), using: salt)
        return Data(code.prefix(16)).base64EncodedString()
    }

    private func emit() {
        let interface = CWWiFiClient.shared().interface()
        let connected = interface?.bssid().map(tag)
        let visible = ((try? interface?.scanForNetworks(withSSID: nil)) ?? [])
            .sorted { $0.rssiValue > $1.rssiValue }.prefix(40).compactMap { $0.bssid.map(tag) }
        let fix = latest
        let status: String = switch manager.authorizationStatus {
        case .authorizedAlways: "always"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "notDetermined"
        default: "other"
        }
        let record = EvidenceRecord(observedAt: Date(), authorization: status,
            fullAccuracy: manager.accuracyAuthorization == .fullAccuracy,
            latitude: fix?.coordinate.latitude, longitude: fix?.coordinate.longitude,
            horizontalAccuracy: fix?.horizontalAccuracy, fixAgeSeconds: fix.map { -$0.timestamp.timeIntervalSinceNow },
            isSimulated: fix?.sourceInformation?.isSimulatedBySoftware ?? false,
            connectedWiFiTag: connected, visibleWiFiTags: Array(visible))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(record) {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
    }
}

// The install salt is supplied by the authority in a later step; refuse to run without one.
guard let saltText = ProcessInfo.processInfo.environment["SHIELD_LOCATION_SALT"],
      let saltData = Data(base64Encoded: saltText), saltData.count >= 32 else {
    FileHandle.standardError.write(Data("location helper: missing install salt\n".utf8))
    exit(64)
}
let sensor = Sensor(salt: SymmetricKey(data: saltData))
sensor.start()
RunLoop.main.run()
