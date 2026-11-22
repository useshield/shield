import AppKit
import SwiftUI

// Seamless: Shield keeps working with its window closed.
// Before, closing the window stopped the model: the location sensor and the
// 5 s refresh stopped, so a place block came back within ~2 minutes while you
// were away (fail closed, but not "quietly works"), and a running download
// was cancelled. Now the one model lives for the whole app, the app stays
// open (Dock icon) after its window closes, and clicking the Dock icon brings
// the same window and state back. Quitting Shield still stops everything,
// and place blocks then hold (unknown location fails closed, unchanged).
@MainActor
final class ShieldAppHost {
    static let shared = ShieldAppHost()
    /// Release and service-mode builds keep running without a window;
    /// visual fixtures and UI review quit like before.
    static var keepsRunningWithoutWindow: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SHIELD_VISUAL_FIXTURE"] == "1" { return false }
        #endif
        return !ShieldRuntime.isUIReview
    }

    private(set) lazy var model: ShieldViewModel = ContentView.makeDefaultModel()
    private var started = false
    private var activity: NSObjectProtocol?
    private var activityTimer: Timer?

    /// The window appeared: start once per app run, not once per window.
    func windowAppeared() {
        guard !started else { return }
        started = true
        model.start()
        updateActivity()
        activityTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in ShieldAppHost.shared.updateActivity() }
        }
    }

    /// The window closed: keep going when the app stays open.
    func windowDisappeared() {
        guard !Self.keepsRunningWithoutWindow else { return }
        stop()
    }

    func stop() {
        guard started else { return }
        started = false
        activityTimer?.invalidate()
        activityTimer = nil
        model.stop()
        updateActivity(force: false)
    }

    /// While a block depends on where the Mac is, macOS must not nap Shield
    /// (a napped app reports late and place blocks would flicker back on).
    /// The Mac can still sleep.
    func updateActivity(force: Bool? = nil) {
        let needed = force ?? (started && model.checksWhereabouts)
        if needed, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Checking where the Mac is for blocks set to a place")
        } else if !needed, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }
}

final class ShieldAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { ShieldAppearance.applySaved() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !ShieldAppHost.keepsRunningWithoutWindow }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { ShieldAppHost.shared.stop() }
    }
}
