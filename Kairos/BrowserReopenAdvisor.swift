import AppKit
import Foundation

// "Reopen Chrome". Shield's service gives browsers
// its block list as admin policy. A browser reads that list when it OPENS
// (verified on a test Mac, Stage 0d): a site that becomes allowed later,
// at the start of its allowed hours or on leaving a place, stays blocked in a
// browser that was already open. This notices that and offers to reopen it.
// Nothing is ever closed without a click.
//
// Newly blocked sites too: a browser that was already
// open keeps its remembered addresses and open connections, so a site blocked
// only by hosts (a big imported list) can keep loading there until it's reopened.

/// Pure: which sites opened, or became blocked, while a browser was already running.
struct BrowserReopenAdvisor: Codable, Equatable {
    /// The blocked hosts at the last observation; nil before the first one.
    var lastBlocked: Set<String>?
    /// Each host that left the blocked list, and when it was first seen open.
    var openedAt: [String: Date] = [:]
    /// Each host that joined the blocked list, and when. Optional so state
    /// saved by release 279–290 still decodes.
    var blockedAt: [String: Date]?
    /// "Not Now": hide until something else opens or is blocked after this moment.
    var dismissedAt: Date?
    /// Release 293 only (a single moment, which also hid earlier blocks whose
    /// tabs were never checked). Still decoded, no longer used: see `markHandled`.
    var blockedHandledAt: Date?

    mutating func observe(blocked: Set<String>, now: Date) {
        var newlyBlocked = blockedAt ?? [:]
        if let lastBlocked {
            for host in lastBlocked.subtracting(blocked) where openedAt[host] == nil { openedAt[host] = now }
            for host in blocked.subtracting(lastBlocked) where newlyBlocked[host] == nil { newlyBlocked[host] = now }
        }
        for host in blocked { openedAt[host] = nil }   // blocked again: nothing to reopen for
        newlyBlocked = newlyBlocked.filter { blocked.contains($0.key) }   // open again: nothing to reopen for
        blockedAt = newlyBlocked.isEmpty ? nil : newlyBlocked
        lastBlocked = blocked
    }

    /// Hosts that opened after the browser launched (and after any "Not Now").
    func openedSince(launch: Date) -> Set<String> {
        Set(openedAt.filter { $0.value > launch && $0.value > (dismissedAt ?? .distantPast) }.keys)
    }

    /// Hosts that became blocked after the browser launched (and after any "Not Now").
    func blockedSince(launch: Date) -> Set<String> {
        let after = dismissedAt ?? .distantPast
        return Set((blockedAt ?? [:]).filter { $0.value > launch && $0.value > after }.keys)
    }

    /// Shield closed the tabs on these newly blocked sites in every open
    /// browser, so they need no reopen. Other blocks still show.
    mutating func markHandled(_ sites: Set<String>) {
        guard var blocked = blockedAt else { return }
        for site in sites { blocked[site] = nil }
        blockedAt = blocked.isEmpty ? nil : blocked
    }

    /// Forget changes that no running browser predates.
    mutating func prune(earliestLaunch: Date?) {
        guard let earliestLaunch else { openedAt = [:]; blockedAt = nil; return }
        openedAt = openedAt.filter { $0.value > earliestLaunch }
        let kept = (blockedAt ?? [:]).filter { $0.value > earliestLaunch }
        blockedAt = kept.isEmpty ? nil : kept
    }

    static let otherWebsites = "Other websites"

    /// What to call the opened sites: the categories they're in ("Social
    /// media", "Video & streaming"), in the categories' order,
    /// never the sites' own addresses ("api.twitter.com + 9 more"). A site
    /// counts for a category when it, or a domain it's under, is one of the
    /// category's websites; anything left is "Other websites".
    static func names(for hosts: Set<String>, categories: [(title: String, domains: Set<String>)]) -> [String] {
        func under(_ host: String) -> [String] {
            var labels = host.lowercased().split(separator: ".").map(String.init)
            var result: [String] = []
            while labels.count >= 2 {
                result.append(labels.joined(separator: "."))
                labels.removeFirst()
            }
            return result
        }
        var unmatched = hosts
        var names: [String] = []
        for category in categories {
            let matched = unmatched.filter { host in under(host).contains { category.domains.contains($0) } }
            guard !matched.isEmpty else { continue }
            unmatched.subtract(matched)
            if !names.contains(category.title) { names.append(category.title) }
        }
        if !unmatched.isEmpty { names.append(names.isEmpty ? "Some websites" : otherWebsites.lowercased()) }
        return names
    }

    /// "Social media is open now." / "Social media and Video & streaming are open now."
    static func headline(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        let plural = names.count > 1 || names[0].hasSuffix("websites")
        return LockInPlan.listed(names) + (plural ? " are" : " is") + " open now."
    }

    /// "Now blocked: Streaming sites." Long lists name two and count the rest.
    static func blockedHeadline(_ names: [String]) -> String {
        guard !names.isEmpty else { return "" }
        return "Now blocked: " + LockInPlan.listed(names) + "."
    }

    /// What the notice says under its headline.
    static func detail(browser: String, opened: Bool, blocked: Bool, restoresTabs: Bool) -> String {
        let action: String
        switch (opened, blocked) {
        case (true, true): action = "Reopen \(browser) so it catches up."
        case (false, true): action = "If \(browser) still opens it, reopen it."
        default: action = "If \(browser) still blocks it, reopen it."
        }
        return action + (restoresTabs ? " Your tabs come back." : "")
    }
}

/// The browsers that read Shield's policy, as they are running now.
enum PolicyBrowsers {
    /// Same browsers the service writes policy for (Chrome for Testing is a
    /// developer tool and is left out here on purpose).
    static let bundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.microsoft.edgemac.Canary", "com.vivaldi.Vivaldi", "org.mozilla.firefox",
    ]

    static func running() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier.map(bundleIDs.contains) == true && !$0.isTerminated
        }
    }

    struct ReopenResult: Equatable {
        /// Didn't quit in time (a "Leave site?" dialog, for example).
        var stuck: [String] = []
        /// Quit, but macOS didn't open it again.
        var notReopened: [String] = []

        /// What to tell the user, or nil when every browser came back.
        var message: String? {
            var parts: [String] = []
            if !stuck.isEmpty {
                parts.append("\(LockInPlan.listed(stuck)) didn't close. Close any open dialogs there, then try again.")
            }
            if !notReopened.isEmpty {
                parts.append("\(LockInPlan.listed(notReopened)) closed but didn't open again. Open it from the Dock.")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    /// Quits each browser normally (it saves its tabs), then opens it again
    /// with its last session. Nothing is forced: a browser that won't quit is
    /// left as it is and named in the result.
    @MainActor
    static func reopen(_ apps: [NSRunningApplication]) async -> ReopenResult {
        var result = ReopenResult()
        for app in apps {
            guard let url = app.bundleURL else { continue }
            let name = app.localizedName ?? "the browser"
            app.terminate()
            var waited = 0
            while !app.isTerminated && waited < 100 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            guard app.isTerminated else { result.stuck.append(name); continue }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            if app.bundleIdentifier != "org.mozilla.firefox" {
                configuration.arguments = ["--restore-last-session"]
            }
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            } catch {
                result.notReopened.append(name)
            }
        }
        return result
    }

    /// Firefox reopens with its own startup setting; Chromium browsers are
    /// asked to restore their last session.
    static func restoresTabs(_ apps: [NSRunningApplication]) -> Bool {
        !apps.contains { $0.bundleIdentifier == "org.mozilla.firefox" }
    }
}
