import CryptoKit
import Foundation
import Testing
@testable import Shield

// Fixes from an independent audit of place blocks.
struct LocationAuditFixTests {
    private let library = RulePlace(id: "library", name: "Library", latitude: 40.7532, longitude: -73.9822,
                                    radiusMeters: 200, wifiTags: ["lib-1"])
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func evidence(fixAge: TimeInterval, slept: Bool = false) -> PresenceEvidence {
        PresenceEvidence(observedAt: now,
                         fix: .init(latitude: 40.7812, longitude: -73.9665, horizontalAccuracy: 20,
                                    observedAt: now.addingTimeInterval(-fixAge), isSimulated: false, fullAccuracy: true),
                         connectedWiFiTag: nil, visibleWiFiTags: [], sleptSinceLastEvidence: slept)
    }

    @Test func aRecordAgesFromItsFixNotFromWhenItArrived() {
        let record = PresenceSnapshot.capture(evidence: evidence(fixAge: 100), places: [library],
                                              tracker: PresenceTracker(), studyMinutesToday: nil, now: now)
        #expect(record.locationKnown)
        #expect(record.capturedAt == now.addingTimeInterval(-100))
        #expect(record.locationUsable(at: now.addingTimeInterval(15)))
        #expect(!record.locationUsable(at: now.addingTimeInterval(25)), "Unknown once the fix is over 120 s old")
    }

    @Test func theFirstReportAfterSleepIsNeverKnown() {
        let record = PresenceSnapshot.capture(evidence: evidence(fixAge: 1, slept: true), places: [library],
                                              tracker: PresenceTracker(), studyMinutesToday: nil, now: now)
        #expect(!record.locationKnown, "It may describe where the Mac fell asleep")
        #expect(!record.locationUsable(at: now))
    }

    @Test func onlyAPreciseRecentFixCanSaveAPlace() {
        func fix(accuracy: Double, age: TimeInterval = 0, simulated: Bool = false) -> LocationFix {
            LocationFix(latitude: 40.7812, longitude: -73.9665, horizontalAccuracy: accuracy,
                        observedAt: now.addingTimeInterval(-age), isSimulated: simulated)
        }
        #expect(fix(accuracy: 20).goodForEnrollment(now: now))
        #expect(fix(accuracy: 100).goodForEnrollment(now: now))
        #expect(!fix(accuracy: 101).goodForEnrollment(now: now), "Too coarse: the centre could be far off")
        #expect(!fix(accuracy: 1_400).goodForEnrollment(now: now))
        #expect(!fix(accuracy: -1).goodForEnrollment(now: now), "Negative accuracy means invalid")
        #expect(!fix(accuracy: 20, age: 31).goodForEnrollment(now: now))
        #expect(!fix(accuracy: 20, age: -30).goodForEnrollment(now: now), "Not from the future")
        #expect(!fix(accuracy: 20, simulated: true).goodForEnrollment(now: now))
    }

    @Test func anExistingWiFiKeyIsNeverReplaced() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldKeyKeep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("location-tag.key")
        let damaged = Data("short".utf8)
        try damaged.write(to: url)
        #expect(throws: (any Error).self) { try WiFiTagger.loadOrCreate(at: url) }
        #expect(try Data(contentsOf: url) == damaged, "Left as found, so saved places' Wi-Fi isn't orphaned")
    }
}
