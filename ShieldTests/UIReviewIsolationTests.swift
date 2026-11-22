import Foundation
import Testing
@testable import Shield

#if UI_REVIEW
struct UIReviewIsolationTests {
    @MainActor
    @Test func reviewDoesNotOpenSelectedManifest() {
        let model = ShieldViewModel()
        model.importStudyManifest(from: URL(fileURLWithPath: "/etc/hosts"))
        #expect(model.studyManifestTitle == nil)
        #expect(model.studyMessage == "UI Review cannot import files.")
    }

    @Test func reviewCapabilitiesFailClosed() async throws {
        #expect(ShieldRuntime.isUIReview)
        #expect(!ShieldRuntime.allowsExternalTools)
        #expect(!StudyWorkerFetcher.isPackaged)
        #expect(!ShieldRuntime.allowsLocalMediaImport)
        #expect(!ShieldRuntime.allowsSimulatedPolicyChanges)
        #expect(ShieldRuntime.serviceName == "com.kairos.ShieldUIReview.simulated")
        #expect(ShieldRuntime.supportDirectory.lastPathComponent == "ShieldUIReview")
        #expect(!ShieldRuntime.permitsWrite(to: URL(fileURLWithPath: "/etc/hosts")))
        #expect(!ShieldRuntime.permitsWrite(to: URL(fileURLWithPath: "/usr/local/etc/kairos-policy-state.plist")))
        #expect(!ShieldRuntime.permitsStateRead(from: URL(fileURLWithPath: "/etc/hosts")))
        #expect(throws: StudyDownloadError.self) {
            try StudyMediaImportStager.copyRegularFile(
                from: URL(fileURLWithPath: "/etc/hosts"),
                to: ShieldRuntime.supportDirectory.appendingPathComponent("forbidden.mp4"))
        }
        if case .valid = AuthorityStateReader(fileURL: URL(fileURLWithPath: "/etc/hosts")).read() {
            Issue.record("UI review read external authority state.")
        }
        if case .success = HostsEnforcementReader(fileURL: URL(fileURLWithPath: "/etc/hosts")).read() {
            Issue.record("UI review read external hosts state.")
        }
        #expect(throws: Error.self) {
            _ = try PolicyRequestStore(fileURL: URL(fileURLWithPath:
                "/Library/Application Support/Kairos/config.plist")).load()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        await #expect(throws: StudyDownloadError.self) {
            try await StudyProcessRunner().run(process, timeout: 1)
        }
        #expect(!process.isRunning)
    }

    @Test func reviewRejectsSymlinkToProductionPath() throws {
        let root = ShieldRuntime.supportDirectory.appendingPathComponent("IsolationTests", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let link = root.appendingPathComponent("hosts-link")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link,
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(!ShieldRuntime.permitsWrite(to: link))
        #expect(throws: Error.self) {
            try AtomicFixtureStore(allowedRoot: root).write(Data("unsafe".utf8), to: link)
        }
    }
}
#endif
