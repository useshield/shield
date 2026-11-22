import SwiftUI

struct PolicySubmissionRecoveryView: View {
    let model: ShieldViewModel
    @State private var confirmingDismissal = false
    var body: some View {
        if let problem = model.submissionRecordError {
            VStack(alignment: .leading, spacing: 8) {
                Label("A change couldn't be read", systemImage: "exclamationmark.triangle.fill").font(.headline)
                    .foregroundStyle(.orange)
                Text("New changes are paused until this is cleared. Your blocks are unchanged. \(problem)")
                    .font(.body).foregroundStyle(.secondary)
                Button("Clear…") { confirmingDismissal = true }
                    .disabled(model.backendSnapshot == nil)
            }
            .shieldConfirmation(isPresented: $confirmingDismissal) {
                ShieldConfirmation(symbol: "exclamationmark.triangle.fill", tint: .orange, title: "Clear this change?",
                                   message: "A backup is kept. Nothing is unblocked.",
                                   confirmTitle: "Clear", confirmIdentifier: "confirmClearChange") {
                    model.archiveUnreadableSubmission()
                }
            }
        } else if model.pendingSubmission != nil && !model.isSubmittingPolicy {
            VStack(alignment: .leading, spacing: 8) {
                Label("A change wasn't confirmed", systemImage: "clock.badge.questionmark")
                    .font(.headline)
                Text("It may already be applied. Check, or try again; it won't be added twice.")
                    .font(.body).foregroundStyle(.secondary)
                ResponsiveRow {
                    Button("Check") { model.refresh() }.accessibilityIdentifier("checkPendingRequest")
                    Button("Try Again") { model.retryPendingSubmission() }.accessibilityIdentifier("retryPendingRequest")
                        .disabled(!model.canRetryPendingSubmission)
                    Button("Dismiss…") { confirmingDismissal = true }.disabled(model.backendSnapshot == nil)
                }
            }
            .shieldConfirmation(isPresented: $confirmingDismissal) {
                ShieldConfirmation(symbol: "clock.badge.questionmark", tint: .blue, title: "Dismiss this notice?",
                                   message: "This doesn't cancel the change or remove any block.",
                                   confirmTitle: "Dismiss", confirmIdentifier: "confirmDismissNotice") {
                    model.finishReviewingSubmission()
                }
            }
        }
    }
}

// Reflows the same controls, retaining identity, focus and accessibility hooks.
// Width is the detail column's width, not the whole window including sidebar.
struct ResponsiveRow<Content: View>: View {
    var breakpoint: CGFloat = 560
    var spacing: CGFloat = 12
    @ViewBuilder let content: Content

    init(breakpoint: CGFloat = 560, spacing: CGFloat = 12,
         @ViewBuilder content: () -> Content) {
        self.breakpoint = breakpoint
        self.spacing = spacing
        self.content = content()
    }

    // Let SwiftUI choose a fitting native stack. No manual subview
    // positioning, cache, or fixed-width controls.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: spacing) { content }
            VStack(alignment: .leading, spacing: spacing) { content }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension ShieldRuleStatus {
    var tint: Color {
        switch self {
        case .protected, .confirmed: return .green
        case .pending, .attention: return .orange
        case .unavailable: return .red
        default: return .secondary
        }
    }
}
