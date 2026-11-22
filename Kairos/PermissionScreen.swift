import SwiftUI

/// The plain screen before a macOS permission prompt ("a plain
/// screen before each permission"). One sentence on why, then macOS asks.
enum PermissionScreen {
    static func confirmation(for ask: ShieldViewModel.PermissionAsk,
                             proceed: @escaping () -> Void) -> ShieldConfirmation {
        switch ask {
        case .location:
            return ShieldConfirmation(
                symbol: "location.fill", tint: ShieldGroupKind.location.tint,
                title: "Shield needs your location",
                message: "Only to tell when you're at a place you added. Where you go stays on this Mac. macOS asks next.",
                confirmTitle: "Continue", confirmIdentifier: "permissionContinue", action: proceed)
        case .closingTabs:
            return ShieldConfirmation(
                symbol: "xmark.rectangle.fill", tint: .orange,
                title: "Close blocked tabs?",
                message: "Your browsers will ask once if Shield may close tabs. Shield only closes tabs of sites that just became blocked.",
                confirmTitle: "Continue", confirmIdentifier: "permissionContinue", action: proceed)
        }
    }
}
