import Foundation
import Testing
@testable import Shield

/// First-run setup (public-release prep): shown once to a new user,
/// never by itself in development, UI Review or test runs, never to someone
/// who already has blocks, and always reachable again from Settings.
@MainActor
@Suite(.serialized)
struct FirstRunSetupTests {
    private func freshDefaults() -> (UserDefaults, String) {
        let name = "ShieldFirstRunTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func aNewUserSeesTheTourExactlyOnce() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!defaults.bool(forKey: FirstRunSetup.seenKey))
        #expect(FirstRunSetup.takeAutomaticShow(defaults: defaults, ruleCount: 0, automatic: true))
        #expect(defaults.bool(forKey: FirstRunSetup.seenKey))
        // Next launch, and every launch after: not again.
        #expect(!FirstRunSetup.takeAutomaticShow(defaults: defaults, ruleCount: 0, automatic: true))
        #expect(!FirstRunSetup.takeAutomaticShow(defaults: defaults, ruleCount: 0, automatic: true))
    }

    @Test func someoneWhoAlreadyHasBlocksIsNotShownTheTour() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        // An upgrade from a release without the tour: blocks exist, so the
        // flag is set quietly and nothing appears, now or later.
        #expect(!FirstRunSetup.takeAutomaticShow(defaults: defaults, ruleCount: 8, automatic: true))
        #expect(defaults.bool(forKey: FirstRunSetup.seenKey))
        #expect(!FirstRunSetup.takeAutomaticShow(defaults: defaults, ruleCount: 0, automatic: true))
    }

    @Test func buildsThatDontShowItAutomaticallyLeaveTheFlagAlone() {
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!FirstRunSetup.takeAutomaticShow(defaults: defaults, ruleCount: 0, automatic: false))
        #expect(!defaults.bool(forKey: FirstRunSetup.seenKey))
    }

    @Test func onlyTheShippedAppShowsItByItself() {
        let release: [String: String] = ["HOME": "/Users/someone", "PATH": "/usr/bin"]
        #expect(FirstRunSetup.showsAutomatically(isDevelopment: false, isUIReview: false, environment: release))
        #expect(!FirstRunSetup.showsAutomatically(isDevelopment: true, isUIReview: false, environment: release))
        #expect(!FirstRunSetup.showsAutomatically(isDevelopment: true, isUIReview: true, environment: release))
        #expect(!FirstRunSetup.showsAutomatically(isDevelopment: false, isUIReview: true, environment: release))
        for key in ["XCTestConfigurationFilePath", "XCTestSessionIdentifier", "XCTestBundlePath",
                    "SHIELD_VISUAL_FIXTURE", "SHIELD_UI_POLISH_FIXTURE", "SHIELD_SNAPSHOT_DIR"] {
            var environment = release
            environment[key] = "1"
            #expect(!FirstRunSetup.showsAutomatically(isDevelopment: false, isUIReview: false, environment: environment),
                    "\(key) must keep the tour from covering tests and previews")
        }
        // This test host is a Debug build: the defaults must say no.
        #expect(!FirstRunSetup.showsAutomatically())
    }

    @Test func stepsRunInOrderFromWelcomeToDone() {
        let steps = FirstRunSetup.Step.allCases
        #expect(steps == [.welcome, .howItWorks, .firstBlock, .library, .done])
        #expect(steps.first?.isFirst == true && steps.first?.previous == nil)
        #expect(steps.last?.isLast == true && steps.last?.next == nil)
        for (index, step) in steps.enumerated() {
            if index > 0 { #expect(step.previous == steps[index - 1]) }
            if index < steps.count - 1 { #expect(step.next == steps[index + 1]) }
        }
        #expect(Set(steps.map(\.name)).count == steps.count)
    }

    @Test func ruleCountComesFromWhatTheServiceReports() async throws {
        #expect(FirstRunSetup.ruleCount(nil) == 0)
        let model = makeFixturePreviewModel(preparedPlan: true)
        model.start()
        defer { model.stop() }
        for _ in 0..<200 where model.backendSnapshot == nil { try await Task.sleep(for: .milliseconds(25)) }
        let snapshot = try #require(model.backendSnapshot)
        let expected = snapshot.committedRestrictions.count + snapshot.committedSchedules.count
        #expect(expected > 0)
        #expect(FirstRunSetup.ruleCount(snapshot) == expected)
        // The fixture's blocks mean an upgrading user wouldn't see the tour.
        let (defaults, name) = freshDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!FirstRunSetup.takeAutomaticShow(defaults: defaults, ruleCount: FirstRunSetup.ruleCount(snapshot),
                                                 automatic: true))
    }
}
