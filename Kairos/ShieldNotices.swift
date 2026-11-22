import SwiftUI

// MARK: - Notices: real notification banners

/// A notice shaped like a Mac notification: app-style icon, bold title, a
/// line under it, its buttons, and a × that appears when you point at it.
/// They sit in the window's top-right corner and slide in from the side.
/// The earlier "floating" notice was the same strip with
/// rounder corners; "if you're gonna make it float, make it an actual notice".
struct ShieldBanner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var message: String? = nil
    /// For tests that look for the message itself.
    var messageIdentifier: String? = nil
    /// Shown under the message in orange (a reopen that didn't work, say).
    var warning: String? = nil
    var onClose: (() -> Void)? = nil
    @ViewBuilder var actions: Actions

    static var width: CGFloat { 372 }
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                CategoryIcon(symbol: symbol, tint: tint, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let message {
                        Text(message)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(messageIdentifier ?? "")
                    }
                    if let warning {
                        Text(warning)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            // Only a row of buttons when there are buttons (an `if` inside
            // the builder isn't an EmptyView even when it shows nothing).
            Group(subviews: actions) { buttons in
                if !buttons.isEmpty {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        buttons
                    }
                    .controlSize(.regular)
                    .buttonStyle(ShieldPillButtonStyle())
                    .buttonBorderShape(.capsule)
                }
            }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75))
        .overlay(alignment: .topLeading) {
            // The Mac's own notifications show their × when pointed at.
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.75))
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: -7, y: -7)
                .opacity(hovering ? 1 : 0)
                .help("Hide")
                .accessibilityLabel("Hide")
                .accessibilityIdentifier("hideNotice")
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityElement(children: .contain)
        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .opacity.combined(with: .scale(scale: 0.96))))
    }
}

extension ShieldBanner where Actions == EmptyView {
    init(symbol: String, tint: Color, title: String, message: String? = nil, messageIdentifier: String? = nil,
         warning: String? = nil, onClose: (() -> Void)? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, message: message, messageIdentifier: messageIdentifier,
                  warning: warning, onClose: onClose) { EmptyView() }
    }
}

// MARK: - A filled button that keeps its color

/// The main button on a banner or confirmation: a filled capsule in a solid
/// color with white text. Unlike `.borderedProminent` it keeps its color when
/// the window isn't in front, so the choice that matters always stands out.
struct ShieldFilledButtonStyle: ButtonStyle {
    var tint: Color = .shieldAccent

    func makeBody(configuration: Configuration) -> some View {
        FilledBody(configuration: configuration, tint: tint)
    }

    private struct FilledBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.controlSize) private var controlSize
        @State private var hovering = false

        var body: some View {
            let small = controlSize == .small || controlSize == .mini
            let large = controlSize == .large || controlSize == .extraLarge
            configuration.label
                .font(small ? .callout.weight(.semibold) : .body.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, small ? 11 : (large ? 18 : 14))
                .padding(.vertical, small ? 4 : (large ? 8 : 5))
                .background(Capsule().fill(tint.gradient))
                .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.18 : 0)))
                .overlay(Capsule().fill(Color.white.opacity(hovering && !configuration.isPressed && isEnabled ? 0.1 : 0)))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.1), value: hovering)
        }
    }
}

// MARK: - Are you sure?

/// What a confirmation asks before something that can't simply be taken back:
/// keeping the current rules instead of a waiting change, removing a block or
/// place, starting a Go There day, deleting saved things.
struct ShieldConfirmation: Identifiable {
    struct Alternative {
        var title: String
        var destructive = false
        var identifier: String
        var action: () -> Void
    }

    let id = UUID()
    var symbol: String
    /// The category's own color when the action is about a rule or place
    ///, so the card matches what it's about.
    var tint: Color
    var title: String
    /// One or two short sentences. No lists of what happens.
    var message: String
    var confirmTitle: String
    /// Something is removed or deleted (the button's role; its color stays the tint).
    var destructive = false
    var confirmIdentifier = "confirmAction"
    /// A second choice (Delete Category Only / Delete and Remove Its Rules).
    var alternative: Alternative? = nil
    var action: () -> Void
}

/// The confirmation card itself: a tinted symbol, the question, a line on
/// what happens, and full-width buttons. Esc cancels; Return never confirms.
struct ShieldConfirmationSheet: View {
    let confirmation: ShieldConfirmation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let c = confirmation
        VStack(spacing: 0) {
            Image(systemName: c.symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(c.tint.gradient, in: Circle())
                .shadow(color: c.tint.opacity(0.4), radius: 10, y: 4)
                .accessibilityHidden(true)

            Text(c.title)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .accessibilityIdentifier("confirmationTitle")
            Text(c.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            VStack(spacing: 8) {
                Button(role: c.destructive ? .destructive : nil) {
                    dismiss()
                    c.action()
                } label: {
                    Text(c.confirmTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(ShieldFilledButtonStyle(tint: c.tint))
                .accessibilityIdentifier(c.confirmIdentifier)

                if let alternative = c.alternative {
                    Button(role: alternative.destructive ? .destructive : nil) {
                        dismiss()
                        alternative.action()
                    } label: {
                        Text(alternative.title).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ShieldPillButtonStyle())
                    .accessibilityIdentifier(alternative.identifier)
                }

                Button {
                    dismiss()
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(ShieldPillButtonStyle())
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("cancelConfirmation")
            }
            .controlSize(.large)
            .buttonBorderShape(.capsule)
            .padding(.top, 22)
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .frame(width: 340)
        .background(Color.shieldPage)
    }
}

extension View {
    /// Asks with Shield's confirmation card while `isPresented` is true.
    func shieldConfirmation(isPresented: Binding<Bool>,
                            _ confirmation: @escaping () -> ShieldConfirmation) -> some View {
        sheet(isPresented: isPresented) { ShieldConfirmationSheet(confirmation: confirmation()) }
    }

    /// Asks with Shield's confirmation card while `item` is set.
    func shieldConfirmation(_ item: Binding<ShieldConfirmation?>) -> some View {
        sheet(item: item) { ShieldConfirmationSheet(confirmation: $0) }
    }
}
