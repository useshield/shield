import SwiftUI

#if DEBUG
/// Product-website screenshots only: renders the app as a customer
/// sees it once installed. Protection shows as on, the development footer is
/// hidden, and Go There Today is ready to start. Set only by the marketing
/// snapshot tests; Release builds don't contain it.
enum MarketingRender {
    /// Set and cleared on the main thread by the marketing snapshot tests only.
    nonisolated(unsafe) static var isActive = false

    /// Generic allowed hours for the website (blocked complement, as stored):
    /// social 5–9 PM, YouTube 7–9 PM, Netflix 8–10 PM. No one's real setup.
    static let hours: [String: (start: Int, end: Int)] = [
        "social-afternoon": (1260, 1020), "instagram-afternoon": (1260, 1020), "tiktok-afternoon": (1260, 1020),
        "youtube-evening": (1260, 1140), "netflix-evening": (1320, 1200),
    ]
}
#endif

/// Offscreen marketing captures skip the window server's vibrancy pass, so
/// sidebar text came out dark on the dark sidebar. Marketing renders draw it
/// in a plain, non-vibrant label color instead; the app itself is unchanged.
struct MarketingSidebarText: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        #if DEBUG
        if MarketingRender.isActive {
            content.foregroundStyle(scheme == .dark ? Color(white: 0.92) : Color(white: 0.11))
        } else {
            content
        }
        #else
        content
        #endif
    }
}
