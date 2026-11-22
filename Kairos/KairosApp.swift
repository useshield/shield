import SwiftUI

@main
struct KairosApp: App {
    @NSApplicationDelegateAdaptor(ShieldAppDelegate.self) private var appDelegate
    init() {
        #if SHIELD_RC
        precondition(Bundle.main.bundleIdentifier == "com.kairos.ShieldRC",
                     "The release candidate must keep its separate application identity.")
        #elseif UI_REVIEW
        precondition(Bundle.main.bundleIdentifier == "com.kairos.ShieldUIReview",
                     "UI review must keep its separate sandboxed identity.")
        #elseif DEBUG
        precondition(Bundle.main.bundleIdentifier == "com.kairos.ShieldDevelopment",
                     "A development binary must keep its separate application identity.")
        #endif
    }
    private var fixtureSize: CGSize {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SHIELD_VISUAL_FIXTURE"] == "1" {
            return ProcessInfo.processInfo.environment["SHIELD_VISUAL_SIZE"] == "compact"
                ? CGSize(width: 860, height: 560) : CGSize(width: 1000, height: 625)
        }
        #endif
        return CGSize(width: 1000, height: 720)
    }

    var body: some Scene {
        // One window: two windows would each run their own model and could
        // write the same library and send policy requests at the same time.
        Window("Shield", id: "main") {
            ContentView()
                // No scroll bars anywhere, even with "always show".
                .scrollIndicators(.never)
                // One blue everywhere, the sidebar's.
                .tint(.shieldAccent)
        }
        .defaultSize(width: fixtureSize.width, height: fixtureSize.height)
        .commands { ShieldNavigationCommands() }
    }
}
