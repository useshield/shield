import AppKit
import SwiftUI

// MARK: - Video Library add-on

/// The main Shield is a blocker. The Video Library (Library, collections,
/// downloads and Shield's own player) is an add-on: off for someone new, one
/// click to add here, and removable without losing any saved video.
enum VideoLibraryAddOn {
    struct Tool: Identifiable, Equatable {
        let name: String
        let found: Bool
        var id: String { name }
    }

    /// The free tools downloads use. Shield doesn't ship them; you install
    /// them yourself, and Shield runs them sandboxed.
    static let toolNames = ["yt-dlp", "deno", "ffmpeg", "ffprobe"]
    static let installCommand = "brew install yt-dlp deno ffmpeg"

    /// Where Shield looks for them (the same places downloads look).
    static func tools(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Tool] {
        let roots = [home.appendingPathComponent(".local/bin"), URL(fileURLWithPath: "/opt/homebrew/bin"),
                     URL(fileURLWithPath: "/usr/local/bin")]
        return toolNames.map { name in
            Tool(name: name, found: roots.contains {
                FileManager.default.isExecutableFile(atPath: $0.appendingPathComponent(name).path)
            })
        }
    }
}

/// The Settings row: what the add-on is, and Add… or Remove….
struct VideoLibraryAddOnRow: View {
    let model: ShieldViewModel
    @State private var adding = false
    @State private var removing = false

    var body: some View {
        LabeledContent {
            if model.videoLibraryEnabled {
                Button("Remove…") { removing = true }
                    .accessibilityIdentifier("removeVideoLibrary")
            } else {
                Button("Add…") { adding = true }
                    .accessibilityIdentifier("addVideoLibrary")
            }
        } label: {
            HStack(spacing: 10) {
                CategoryIcon(symbol: "play.rectangle.on.rectangle.fill", tint: .red, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Video Library")
                    Text(model.videoLibraryEnabled ? "On" : "Save videos to watch in Shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $adding) { VideoLibraryAddOnSheet(model: model) }
        .shieldConfirmation(isPresented: $removing) {
            ShieldConfirmation(symbol: "play.rectangle.on.rectangle.fill", tint: .red,
                               title: "Remove the Video Library?",
                               message: "Library leaves the sidebar and downloads stop. Your videos stay on this Mac, and adding it again brings them back.",
                               confirmTitle: "Remove", destructive: true,
                               confirmIdentifier: "confirmRemoveVideoLibrary") {
                model.setVideoLibraryEnabled(false)
            }
        }
    }
}

/// Adding the Video Library: what it is, the free tools downloads need, and
/// one button. Tools can be installed later; Library works for playing and
/// organizing either way.
struct VideoLibraryAddOnSheet: View {
    let model: ShieldViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var tools = VideoLibraryAddOn.tools()
    @State private var copied = false

    private var missing: [VideoLibraryAddOn.Tool] { tools.filter { !$0.found } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle.on.rectangle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.red.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Video Library").font(.title2.weight(.bold))
                    Text("Save videos from links and watch them in Shield, even while the site is blocked.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Downloads use free tools").font(.headline)
                HStack(spacing: 8) {
                    ForEach(tools) { tool in
                        HStack(spacing: 5) {
                            Image(systemName: tool.found ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(tool.found ? Color.green : Color.secondary)
                            Text(tool.name)
                        }
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(tool.found ? "Found" : "Not found")
                    }
                }
                if missing.isEmpty {
                    Label("All set.", systemImage: "checkmark.seal.fill")
                        .font(.callout).foregroundStyle(.green)
                } else {
                    Text("Install them with Homebrew, then check again:")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(VideoLibraryAddOn.installCommand)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.06)))
                        Button(copied ? "Copied" : "Copy") {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(VideoLibraryAddOn.installCommand, forType: .string)
                        }
                        Button("Check Again") { tools = VideoLibraryAddOn.tools() }
                            .accessibilityIdentifier("checkVideoTools")
                    }
                    Text("You can add the Library now and install them later.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.09)))

            Text("Use only videos you're allowed to download. Shield runs these tools in a sandbox, and the blocked site stays blocked for everything else.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(ShieldPillButtonStyle())
                Button("Add Video Library") {
                    model.setVideoLibraryEnabled(true)
                    dismiss()
                }
                .buttonStyle(ShieldFilledButtonStyle(tint: .red))
                .accessibilityIdentifier("confirmAddVideoLibrary")
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 480)
        .background(Color.shieldPage)
    }
}
