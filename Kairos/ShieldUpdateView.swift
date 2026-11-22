import AppKit
import SwiftUI

/// Settings → Updates. Shown only in builds with a release feed; checks only
/// when asked, so Shield never calls out on its own.
struct ShieldUpdateSection: View {
    private enum Stage: Equatable {
        case idle, checking, upToDate, available(ShieldUpdater.Release), downloading, failed(String)
    }
    @State private var stage: Stage = .idle
    private let configuration = ShieldUpdater.Configuration.fromBundle()

    var body: some View {
        if let configuration {
            Section("Updates") {
                LabeledContent("Shield \(configuration.currentVersion)") {
                    switch stage {
                    case .available(let release):
                        Button("Download Shield \(release.version)") { download(release, configuration) }
                            .accessibilityIdentifier("downloadUpdate")
                    case .checking, .downloading:
                        ProgressView().controlSize(.small)
                    default:
                        Button("Check for Updates") { check(configuration) }
                            .accessibilityIdentifier("checkForUpdates")
                    }
                }
                switch stage {
                case .upToDate: Text("You have the newest version.").font(.callout).foregroundStyle(.secondary)
                case .available(let release):
                    Link("What's new in \(release.version)", destination: release.notesURL).font(.callout)
                case .downloading: Text("Downloading and checking…").font(.callout).foregroundStyle(.secondary)
                case .failed(let reason): Text(reason).font(.callout).foregroundStyle(.orange)
                default: EmptyView()
                }
            }
        }
    }

    private func check(_ configuration: ShieldUpdater.Configuration) {
        stage = .checking
        Task {
            do { stage = try await ShieldUpdater.latest(configuration).map { .available($0) } ?? .upToDate }
            catch { stage = .failed(error.localizedDescription) }
        }
    }

    /// Opens the checked installer; macOS asks for the admin password.
    private func download(_ release: ShieldUpdater.Release, _ configuration: ShieldUpdater.Configuration) {
        stage = .downloading
        Task {
            do {
                let file = try await ShieldUpdater.download(release, configuration: configuration)
                NSWorkspace.shared.open(file)
                stage = .idle
            } catch { stage = .failed(error.localizedDescription) }
        }
    }
}
