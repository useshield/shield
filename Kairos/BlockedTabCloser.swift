import AppKit
import Foundation
import os

// Close tabs on newly blocked sites. A browser that
// was already open keeps showing a page, playing a video or using an open
// connection after its site becomes blocked. With this on, when a block
// starts Shield closes ONLY the tabs whose site just became blocked.
//
// Safety limits (see docs/seamless/TAB_CLOSING_SAFETY.md):
//   - off until the user turns it on in Settings;
//   - only tabs whose address is exactly a site that JUST became blocked
//     (hosts blocking is exact, so a subdomain tab may still load and stays);
//     never other tabs, never windows (a window that would be left empty gets
//     a new blank tab first), never the browser itself;
//   - only browsers already running (a browser is never launched to check it);
//   - every closed tab's address is kept in Settings for a day;
//   - macOS asks once before Shield may control each browser, and "Don't
//     Allow" simply leaves tabs open (the Reopen notice still shows).

enum BlockedTabCloser {
    /// Browsers whose tabs can be listed and closed with Apple Events.
    /// Firefox has no such interface; the Reopen notice covers it.
    static let scriptableBrowsers: [String: String] = [
        "com.google.Chrome": "Google Chrome", "com.google.Chrome.beta": "Google Chrome Beta",
        "com.google.Chrome.dev": "Google Chrome Dev", "com.google.Chrome.canary": "Google Chrome Canary",
        "org.chromium.Chromium": "Chromium", "com.brave.Browser": "Brave Browser",
        "com.brave.Browser.beta": "Brave Browser Beta", "com.brave.Browser.nightly": "Brave Browser Nightly",
        "com.microsoft.edgemac": "Microsoft Edge", "com.microsoft.edgemac.Beta": "Microsoft Edge Beta",
        "com.microsoft.edgemac.Dev": "Microsoft Edge Dev", "com.microsoft.edgemac.Canary": "Microsoft Edge Canary",
        "com.vivaldi.Vivaldi": "Vivaldi", "com.apple.Safari": "Safari",
    ]

    struct Tab: Equatable, Hashable {
        var windowID: String
        var url: String
    }

    struct ClosedTab: Codable, Equatable, Hashable {
        var url: String
        var browser: String
        var closedAt: Date
    }

    enum Failure: Error, Equatable {
        /// macOS hasn't allowed Shield to control this browser.
        case notAllowed
        case failed
    }

    // MARK: Pure

    /// The site of a web address, lowercased; nil for anything but http(s).
    static func host(of address: String) -> String? {
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// The tabs to close: those showing exactly a site that just became
    /// blocked. The hosts file blocks exact sites (www twins are listed
    /// separately), so docs.example.com may still load when example.com is
    /// blocked, and its tab stays open.
    static func tabsToClose(_ tabs: [Tab], newlyBlocked: Set<String>) -> [Tab] {
        guard !newlyBlocked.isEmpty else { return [] }
        return tabs.filter { tab in host(of: tab.url).map(newlyBlocked.contains) ?? false }
    }

    /// "window-id<TAB>address" lines from the listing script.
    static func parseListing(_ output: String) -> [Tab] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, !parts[0].isEmpty, parts[0].allSatisfy(\.isNumber), !parts[1].isEmpty else { return nil }
            return Tab(windowID: String(parts[0]), url: String(parts[1]))
        }
    }

    /// An AppleScript string literal.
    static func literal(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Lists every tab as "window-id<TAB>address". Never launches the browser.
    /// (Inside the tell block `tab` means the browser's tab, so the separators
    /// are made before it.)
    static func listingScript(bundleID: String) -> String {
        """
        if application id \(literal(bundleID)) is not running then return ""
        set sep to character id 9
        set nl to character id 10
        set out to ""
        tell application id \(literal(bundleID))
            repeat with w in windows
                try
                    set wid to (id of w) as text
                    -- One request per window: asking tab by tab took over the
                    -- 15 s limit in a browser with many tabs (Nov 15, 6 PM).
                    set urls to URL of every tab of w
                    repeat with u in urls
                        try
                            set out to out & wid & sep & (u as text) & nl
                        end try
                    end repeat
                end try
            end repeat
        end tell
        return out
        """
    }

    /// Closes exactly these tabs: in each listed window (found by its ID, so
    /// closing in one never shifts another), the tabs whose full address
    /// matches, last to first. A window whose every tab would close gets a new
    /// blank tab first, so no window closes. Returns "window-id<TAB>address"
    /// for each tab it closed.
    static func closingScript(bundleID: String, tabs: [Tab]) -> String {
        let byWindow = Dictionary(grouping: tabs.filter { !$0.windowID.isEmpty && $0.windowID.allSatisfy(\.isASCII)
                                                            && $0.windowID.allSatisfy(\.isNumber) }, by: \.windowID)
        let blocks = byWindow.keys.sorted().map { windowID in
            let targets = Array(Set(byWindow[windowID]!.map(\.url))).sorted().map(literal).joined(separator: ", ")
            return """
                try
                    set w to window id \(windowID)
                    set targets to {\(targets)}
                    set urls to URL of every tab of w
                    set total to count of urls
                    set hits to 0
                    repeat with u in urls
                        try
                            if targets contains (u as text) then set hits to hits + 1
                        end try
                    end repeat
                    if hits > 0 and hits = total then make new tab at end of tabs of w
                    -- Last to first, so closing never shifts a tab still to check;
                    -- each one is re-read just before it closes.
                    repeat with i from total to 1 by -1
                        try
                            if targets contains ((item i of urls) as text) then
                                set taburl to URL of tab i of w
                                if targets contains taburl then
                                    close tab i of w
                                    set out to out & "\(windowID)" & sep & taburl & nl
                                end if
                            end if
                        end try
                    end repeat
                end try
            """
        }
        return """
        if application id \(literal(bundleID)) is not running then return ""
        set sep to character id 9
        set nl to character id 10
        set out to ""
        tell application id \(literal(bundleID))
        \(blocks.joined(separator: "\n"))
        end tell
        return out
        """
    }

    // MARK: Running

    /// The scriptable browsers running now, as (bundle ID, name).
    @MainActor
    static func runningBrowsers() -> [(bundleID: String, name: String)] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard !app.isTerminated, let id = app.bundleIdentifier, let name = scriptableBrowsers[id] else { return nil }
            return (id, app.localizedName ?? name)
        }
    }

    /// Lists, picks and closes one browser's tabs. Off the main thread.
    /// Returns the tabs actually closed, even when closing stopped part way
    /// (then also the failure).
    /// Outcomes only (counts and error kinds, never addresses), readable
    /// later with `log show --predicate 'subsystem == "com.kairos.Shield"'`.
    static let log = Logger(subsystem: "com.kairos.Shield", category: "tabs")

    static func closeTabs(bundleID: String, newlyBlocked: Set<String>) async -> (closed: [Tab], failure: Failure?) {
        let listing = await runScript(listingScript(bundleID: bundleID))
        guard case .success(let output) = listing else {
            let failure: Failure = if case .failure(let failure) = listing { failure } else { .failed }
            log.error("\(bundleID, privacy: .public): listing tabs failed: \(String(describing: failure), privacy: .public)")
            return ([], failure)
        }
        let before = parseListing(output)
        let doomed = tabsToClose(before, newlyBlocked: newlyBlocked)
        log.notice("\(bundleID, privacy: .public): \(before.count) tabs, \(doomed.count) on \(newlyBlocked.count) newly blocked sites")
        guard !doomed.isEmpty else { return ([], nil) }
        switch await runScript(closingScript(bundleID: bundleID, tabs: doomed)) {
        case .success(let closed):
            let tabs = parseListing(closed)
            log.notice("\(bundleID, privacy: .public): closed \(tabs.count) tabs")
            return (tabs, nil)
        case .failure(let failure):
            log.error("\(bundleID, privacy: .public): closing stopped: \(String(describing: failure), privacy: .public)")
            // Stopped part way (a "Leave site?" sheet, a timeout): list again,
            // and count as closed the chosen tabs that are gone now.
            guard case .success(let after) = await runScript(listingScript(bundleID: bundleID)) else {
                return ([], failure)
            }
            return (closedTabs(chosen: doomed, before: before, after: parseListing(after)), failure)
        }
    }

    /// The chosen tabs no longer present: per window and address, as many as
    /// the count dropped (two tabs may show the same address).
    static func closedTabs(chosen: [Tab], before: [Tab], after: [Tab]) -> [Tab] {
        func counts(_ tabs: [Tab]) -> [Tab: Int] { tabs.reduce(into: [:]) { $0[$1, default: 0] += 1 } }
        let was = counts(before), now = counts(after)
        var remaining = Dictionary(uniqueKeysWithValues: Set(chosen).map { tab in
            (tab, max(0, (was[tab] ?? 0) - (now[tab] ?? 0)))
        })
        return chosen.filter { tab in
            guard let left = remaining[tab], left > 0 else { return false }
            remaining[tab] = left - 1
            return true
        }
    }

    /// Runs AppleScript with a 15-second limit. Output is read while the
    /// script runs, so a long tab list can't stall it.
    static func runScript(_ source: String) async -> Result<String, Failure> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", source]
                let output = Pipe(), errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                let text = DataBox(), problem = DataBox()
                let reading = DispatchGroup()
                reading.enter()
                DispatchQueue.global(qos: .utility).async {
                    text.set(output.fileHandleForReading.readDataToEndOfFile()); reading.leave()
                }
                reading.enter()
                DispatchQueue.global(qos: .utility).async {
                    problem.set(errors.fileHandleForReading.readDataToEndOfFile()); reading.leave()
                }
                let done = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in done.signal() }
                guard (try? process.run()) != nil else {
                    try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
                    continuation.resume(returning: .failure(.failed))
                    return
                }
                guard done.wait(timeout: .now() + 15) == .success else {
                    log.error("A browser script ran past 15 s and was stopped")
                    process.terminate()
                    continuation.resume(returning: .failure(.failed))
                    return
                }
                _ = reading.wait(timeout: .now() + 2)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: .success(String(decoding: text.get(), as: UTF8.self)))
                } else {
                    // -1743: macOS hasn't allowed Shield to control that app.
                    let message = String(decoding: problem.get(), as: UTF8.self)
                    let code = message.range(of: #"\(-?\d+\)"#, options: .regularExpression).map { String(message[$0]) } ?? "?"
                    log.error("A browser script failed with error \(code, privacy: .public)")
                    continuation.resume(returning: .failure(message.contains("-1743") || message.contains("-1744")
                                                            ? .notAllowed : .failed))
                }
            }
        }
    }
}

/// Bytes read on another thread.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.withLock { data = value } }
    func get() -> Data { lock.withLock { data } }
}
