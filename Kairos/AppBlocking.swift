import Foundation

// App blocking (docs/app-blocking-design.md): the pure decisions. Which apps
// match a target, which can never be blocked, which rule changes are
// stronger, and what to do about running apps. `AppEnforcer` carries them out.

// MARK: Identity

/// An app's identity as its code signature states it.
struct AppIdentity: Codable, Hashable, Sendable {
    var bundleID: String
    var teamID: String?      // nil: Apple platform, ad-hoc or unsigned
    var signingID: String?   // the signature's identifier
    var isPlatform = false
    // Its Info.plist says it opens http/https links: a web browser, even one
    // that isn't on the known list. Only a Go day blocks by this.
    var opensWebLinks = false
}

/// What a rule blocks: one app and its helpers, chosen from a real .app.
struct AppTarget: Codable, Hashable, Sendable, Identifiable {
    let displayName: String
    let bundleID: String
    let teamID: String?      // nil for Apple's own apps

    var id: String { "\(teamID ?? "platform"):\(bundleID)" }

    /// Every web browser at once. Only a Go day may carry it (browsers are
    /// otherwise held: AppBlockSafety.browsers).
    static let webBrowsers = AppTarget(displayName: "Web browsers", bundleID: "family.web-browsers", teamID: nil)
}

enum AppMatcher {
    /// The app itself, or a helper whose identifier extends the app's
    /// (Chrome's "com.google.Chrome.helper", Electron renderers, login items).
    static func sameOrHelper(_ identifier: String?, of bundleID: String) -> Bool {
        guard let identifier else { return false }
        return identifier == bundleID || identifier.hasPrefix(bundleID + ".")
    }

    /// Signed by the target's team with a matching identifier, or carrying the
    /// target's bundle ID at all. The second clause catches a renamed or
    /// re-signed copy (re-signing strips the team); matching too much is the
    /// safe direction for a block.
    static func matches(_ target: AppTarget, _ app: AppIdentity) -> Bool {
        if target == .webBrowsers { return AppBlockSafety.isWebBrowser(app) }
        // Known browsers stay held for every other rule, whatever it names.
        // (An app is never un-blocked just for also opening web links.)
        if AppBlockSafety.refusal(for: app.bundleID) == .browser { return false }
        if sameOrHelper(app.bundleID, of: target.bundleID) { return true }
        guard let team = target.teamID, app.teamID == team else { return false }
        return sameOrHelper(app.signingID, of: target.bundleID)
    }
}

// MARK: Apps that can't be blocked

enum AppBlockSafety {
    // Blocking these would leave the Mac unusable, or lock the user out of
    // recovery (Terminal) or out of Shield itself.
    static let essential: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
        "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.WindowManager",
        "com.apple.Terminal", "com.apple.systempreferences", "com.apple.SecurityAgent",
    ]
    // Blocking whole browsers is part of separate hardening work; site
    // blocking already covers websites in them.
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.google.Chrome.canary", "org.mozilla.firefox",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi", "org.chromium.Chromium",
    ]

    // Joining a library's Wi-Fi needs its login window, even during a Go day.
    static let captiveLogin = "com.apple.CaptiveNetworkAssistant"

    enum Refusal: Equatable { case essential, browser, shield }

    /// Never closed by anything, Go days included.
    static func neverBlockable(_ bundleID: String) -> Bool {
        bundleID.hasPrefix("com.kairos.") || bundleID == captiveLogin ||
            essential.contains(where: { AppMatcher.sameOrHelper(bundleID, of: $0) })
    }

    static func isWebBrowser(_ app: AppIdentity) -> Bool {
        !neverBlockable(app.bundleID) &&
            (app.opensWebLinks || browsers.contains(where: { AppMatcher.sameOrHelper(app.bundleID, of: $0) }))
    }

    static func refusal(for bundleID: String) -> Refusal? {
        if bundleID.hasPrefix("com.kairos.") { return .shield }
        if essential.contains(where: { AppMatcher.sameOrHelper(bundleID, of: $0) }) { return .essential }
        if browsers.contains(where: { AppMatcher.sameOrHelper(bundleID, of: $0) }) { return .browser }
        return nil
    }
}

// MARK: Rules

/// Blocks apps always, or outside allowed hours. `schedule` reuses the site
/// schedules' stored form: its minutes are when the apps are BLOCKED (the
/// complement of the allowed hours), in the service's fixed time zone.
struct AppBlockRule: Codable, Hashable, Sendable, Identifiable {
    let id: String
    var title: String
    var targets: [AppTarget]
    var schedule: DailySchedule?   // nil: blocked at all times

    func isBlocking(at now: Date, calendar: Calendar) -> Bool {
        schedule.map { $0.contains(now, calendar: calendar) } ?? true
    }
}

enum AppBlockEngine {
    /// Targets blocked now. When the service can't verify its state, every
    /// committed target is blocked regardless of schedule (fail closed).
    static func blockedTargets(_ rules: [AppBlockRule], at now: Date, calendar: Calendar,
                               stateVerified: Bool) -> [AppTarget] {
        var seen = Set<String>(), result: [AppTarget] = []
        for rule in rules.sorted(by: { $0.id < $1.id }) where !stateVerified || rule.isBlocking(at: now, calendar: calendar) {
            for target in rule.targets where AppBlockSafety.refusal(for: target.bundleID) == nil
                && seen.insert(target.id).inserted {
                result.append(target)
            }
        }
        return result
    }
}

// MARK: Changes (stronger: immediate; weaker: at least 24 h)

enum AppRuleChange: Equatable { case immediate, delayed }

enum AppRuleChangeClassifier {
    static func classify(old: AppBlockRule?, new: AppBlockRule?) -> AppRuleChange {
        switch (old, new) {
        case (nil, _): return .immediate
        case (_?, nil): return .delayed
        case (let before?, let after?):
            guard Set(after.targets).isSuperset(of: before.targets) else { return .delayed }
            switch (before.schedule, after.schedule) {
            case (_, nil): return .immediate                  // now blocked at all times
            case (nil, _?): return .delayed                   // gains allowed hours
            case (let was?, let now?): return now.isImmediateStrengthening(of: was) ? .immediate : .delayed
            }
        }
    }
}

// MARK: Closing blocked apps

struct RunningApp: Sendable, Equatable {
    let pid: Int32
    let identity: AppIdentity
    let launchedAt: Date
}

enum AppAction: Equatable, Sendable {
    case askToQuit(pid: Int32, targetID: String)   // like choosing Quit; the app may save
    case forceQuit(pid: Int32, targetID: String)
}

/// Decides what to do about running apps on each sweep. An app that was
/// already open when its block began is asked to quit, then forced after a
/// grace period; one opened during a block is closed at once.
struct AppSweep: Sendable {
    static let grace: TimeInterval = 60
    private(set) var blockedSince: [String: Date] = [:]
    private(set) var askedAt: [Int32: Date] = [:]

    mutating func decide(running: [RunningApp], blocked: [AppTarget], now: Date, ownPID: Int32) -> [AppAction] {
        let blockedIDs = Set(blocked.map(\.id))
        blockedSince = blockedSince.filter { blockedIDs.contains($0.key) }
        for target in blocked where blockedSince[target.id] == nil { blockedSince[target.id] = now }
        let runningPIDs = Set(running.map(\.pid))
        askedAt = askedAt.filter { runningPIDs.contains($0.key) }

        var actions: [AppAction] = []
        for app in running.sorted(by: { $0.pid < $1.pid }) {
            guard app.pid > 1, app.pid != ownPID, !AppBlockSafety.neverBlockable(app.identity.bundleID),
                  let target = blocked.first(where: { AppMatcher.matches($0, app.identity) }),
                  let since = blockedSince[target.id] else {
                askedAt[app.pid] = nil
                continue
            }
            if app.launchedAt >= since {
                actions.append(.forceQuit(pid: app.pid, targetID: target.id))
            } else if let asked = askedAt[app.pid] {
                if now.timeIntervalSince(asked) >= Self.grace { actions.append(.forceQuit(pid: app.pid, targetID: target.id)) }
            } else {
                askedAt[app.pid] = now
                actions.append(.askToQuit(pid: app.pid, targetID: target.id))
            }
        }
        return actions
    }
}
