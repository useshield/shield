import Foundation
import Testing
@testable import Shield

struct AppBlockingTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: hour, minute: minute))!
    }

    private let game = AppTarget(displayName: "Example Game", bundleID: "com.example.game", teamID: "TEAM000001")
    private func identity(_ bundleID: String, team: String? = "TEAM000001", signing: String? = nil) -> AppIdentity {
        AppIdentity(bundleID: bundleID, teamID: team, signingID: signing ?? bundleID)
    }
    // Blocked except 6–8 PM: stored as the blocked complement, 8 PM to 6 PM.
    private var eveningOnly: DailySchedule {
        DailySchedule(id: "game", title: "Game", domains: [], startMinutes: 20 * 60, endMinutes: 18 * 60, isRequested: true)
    }

    @Test func matchesTheAppItsHelpersAndRenamedCopiesButNotOtherApps() {
        #expect(AppMatcher.matches(game, identity("com.example.game")))
        #expect(AppMatcher.matches(game, identity("com.example.game.helper.renderer")))
        // Re-signed copy: no team any more, same bundle ID.
        #expect(AppMatcher.matches(game, identity("com.example.game", team: nil)))
        // Bundle ID edited, but still signed by the vendor as this app.
        #expect(AppMatcher.matches(game, identity("com.example.renamed", signing: "com.example.game")))
        // Same vendor, different app.
        #expect(!AppMatcher.matches(game, identity("com.example.editor")))
        // A lookalike prefix is not a helper.
        #expect(!AppMatcher.matches(game, identity("com.example.gameboard")))
        // Another team signing with this identifier is matched only by bundle ID.
        #expect(!AppMatcher.matches(game, identity("com.other.thing", team: "TEAM000002", signing: "com.example.game")))
    }

    @Test func essentialAppsBrowsersAndShieldCanNeverBeBlocked() {
        #expect(AppBlockSafety.refusal(for: "com.apple.finder") == .essential)
        #expect(AppBlockSafety.refusal(for: "com.apple.Terminal") == .essential)
        #expect(AppBlockSafety.refusal(for: "com.google.Chrome") == .browser)
        #expect(AppBlockSafety.refusal(for: "com.google.Chrome.helper") == .browser)
        #expect(AppBlockSafety.refusal(for: "com.kairos.ShieldRC") == .shield)
        #expect(AppBlockSafety.refusal(for: "com.example.game") == nil)
        let rule = AppBlockRule(id: "r", title: "", targets: [
            AppTarget(displayName: "Finder", bundleID: "com.apple.finder", teamID: nil), game], schedule: nil)
        #expect(AppBlockEngine.blockedTargets([rule], at: at(12), calendar: calendar, stateVerified: true) == [game])
    }

    @Test func schedulesUseTheBlockedComplementAndFailClosed() {
        let rule = AppBlockRule(id: "r", title: "", targets: [game], schedule: eveningOnly)
        #expect(AppBlockEngine.blockedTargets([rule], at: at(17, 59), calendar: calendar, stateVerified: true) == [game])
        #expect(AppBlockEngine.blockedTargets([rule], at: at(19), calendar: calendar, stateVerified: true).isEmpty)
        #expect(AppBlockEngine.blockedTargets([rule], at: at(20), calendar: calendar, stateVerified: true) == [game])
        // Unverified state blocks every committed app, even in allowed hours.
        #expect(AppBlockEngine.blockedTargets([rule], at: at(19), calendar: calendar, stateVerified: false) == [game])
    }

    @Test func strongerChangesApplyNowAndWeakerOnesWait() {
        let rule = AppBlockRule(id: "r", title: "", targets: [game], schedule: eveningOnly)
        let other = AppTarget(displayName: "Other", bundleID: "com.example.other", teamID: "TEAM000001")
        var more = rule; more.targets.append(other)
        var always = rule; always.schedule = nil
        var longerAllowed = rule
        longerAllowed.schedule = DailySchedule(id: "game", title: "Game", domains: [],
                                               startMinutes: 21 * 60, endMinutes: 18 * 60, isRequested: true)
        #expect(AppRuleChangeClassifier.classify(old: nil, new: rule) == .immediate)
        #expect(AppRuleChangeClassifier.classify(old: rule, new: more) == .immediate)
        #expect(AppRuleChangeClassifier.classify(old: rule, new: always) == .immediate)
        #expect(AppRuleChangeClassifier.classify(old: rule, new: nil) == .delayed)
        #expect(AppRuleChangeClassifier.classify(old: more, new: rule) == .delayed)
        #expect(AppRuleChangeClassifier.classify(old: always, new: rule) == .delayed)
        #expect(AppRuleChangeClassifier.classify(old: rule, new: longerAllowed) == .delayed)
    }

    @Test func openAppsAreAskedFirstAndAppsOpenedDuringABlockCloseAtOnce() {
        var sweep = AppSweep()
        let start = at(20)
        let earlier = RunningApp(pid: 100, identity: identity("com.example.game"), launchedAt: at(19, 30))
        let finder = RunningApp(pid: 50, identity: identity("com.apple.finder", team: nil), launchedAt: at(8))
        #expect(sweep.decide(running: [finder, earlier], blocked: [game], now: start, ownPID: 999)
                == [.askToQuit(pid: 100, targetID: game.id)])
        // Still open within the grace period: nothing new.
        #expect(sweep.decide(running: [earlier], blocked: [game], now: start.addingTimeInterval(30), ownPID: 999).isEmpty)
        #expect(sweep.decide(running: [earlier], blocked: [game], now: start.addingTimeInterval(61), ownPID: 999)
                == [.forceQuit(pid: 100, targetID: game.id)])
        let relaunched = RunningApp(pid: 101, identity: identity("com.example.game"), launchedAt: start.addingTimeInterval(90))
        #expect(sweep.decide(running: [relaunched], blocked: [game], now: start.addingTimeInterval(91), ownPID: 999)
                == [.forceQuit(pid: 101, targetID: game.id)])
        // Allowed hours: nothing is closed.
        #expect(sweep.decide(running: [relaunched], blocked: [], now: at(18, 30), ownPID: 999).isEmpty)
    }
}
