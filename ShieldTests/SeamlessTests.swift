import Foundation
import Testing
@testable import Shield

// Operation Seamless: location warnings only when a block uses a
// place, failures stay visible, Reopen says what went wrong.
struct SeamlessTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func noPlaceBlockMeansNoLocationWarning() {
        for access: LocationSensor.Access? in [nil, .notAsked, .denied, .restricted, .approximateOnly] {
            #expect(LocationPresentation.problem(access: access, tracked: false, reportFailed: true,
                                                 sensorRunning: false, locationUsable: false) == nil)
        }
    }

    @Test func aPlaceBlockSaysTheOneThingThatMatters() {
        func problem(_ access: LocationSensor.Access?, failed: Bool = false, running: Bool = true, usable: Bool = true)
            -> LocationPresentation.Problem? {
            LocationPresentation.problem(access: access, tracked: true, reportFailed: failed,
                                         sensorRunning: running, locationUsable: usable)
        }
        #expect(problem(.approximateOnly) == .needsPrecise)
        #expect(problem(.denied, failed: true) == .off)
        #expect(problem(.restricted) == .off)
        #expect(problem(.allowed, failed: true) == .reportFailed)
        #expect(problem(.allowed, running: false, usable: false) == .notRunning)
        #expect(problem(.allowed) == nil)
    }

    @Test func placesHeadlineIsQuietWhenNothingUsesAPlace() {
        let place = RulePlace(id: "library", name: "Library", latitude: 40.75, longitude: -73.98, radiusMeters: 150, wifiTags: [])
        #expect(LocationPresentation.headline(access: .allowed, places: [place], presence: nil, tracked: false, now: now)
                == "Your places")
        #expect(LocationPresentation.headline(access: .denied, places: [place], presence: nil, tracked: true, now: now)
                == "Location is off for Shield")
        #expect(LocationPresentation.headline(access: nil, places: [], presence: nil, tracked: true, now: now)
                == "No places yet")
    }

    @Test func failuresStayLongerThanOutcomes() {
        #expect(ShieldViewModel.actionMessageLifetime("Shield didn't accept this change. Nothing changed.") == 60)
        #expect(ShieldViewModel.actionMessageLifetime("No reply from Shield yet.") == 60)
        #expect(ShieldViewModel.actionMessageLifetime("Saved. YouTube is blocked at Home.") == 10)
    }

    @Test func reopenSaysWhatWentWrong() {
        #expect(PolicyBrowsers.ReopenResult().message == nil)
        #expect(PolicyBrowsers.ReopenResult(stuck: ["Google Chrome"]).message ==
                "Google Chrome didn't close. Close any open dialogs there, then try again.")
        #expect(PolicyBrowsers.ReopenResult(notReopened: ["Brave Browser"]).message ==
                "Brave Browser closed but didn't open again. Open it from the Dock.")
    }
}
