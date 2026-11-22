import Foundation
import Testing
@testable import Shield

@MainActor
struct ModelCampaignTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldModelCampaign-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
        return root
    }

    @Test func clipboardReportOmitsPrivateErrorDetailsAndDomains() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let secret = "/Users/private-owner/Documents/private-policy.example token=private-token"
        let model = ShieldViewModel(authorityReader: CampaignAuthorityReader(status: .unavailable(.unreadable(secret))),
            enforcementReader: CampaignEnforcementReader(), studyLibraryRoot: root)
        model.refresh()
        #expect(model.authorityError?.contains(secret) == true)
        let report = model.diagnosticReport
        #expect(report.contains("authority=unavailable"))
        #expect(report.contains("hosts=unavailable"))
        for privateValue in [secret, "private-owner", "private-policy.example", "private-token"] {
            #expect(!report.contains(privateValue))
        }
    }

    @Test func downloadPermissionExpiresWithoutFreshBackendEvidence() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let model = ShieldViewModel(studyLibraryRoot: root.appendingPathComponent("library"), fixtureBackend: backend)
        let now = Date()
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: now, commands: [.add(DomainRestriction(owner: .permanent,
                policyID: "safe", title: "Other sites", domains: ["example.invalid"]))]), now: now, calendar: .current)
        model.refresh(now: now)
        #expect(model.studyPolicyBlockReason(now: now) == nil)
        #expect(model.studyPolicyBlockReason(now: now.addingTimeInterval(31))?.contains("out of date") == true)
        #expect(model.studyPolicyBlockReason(now: now.addingTimeInterval(-6))?.contains("out of date") == true)
        model.refresh(now: now.addingTimeInterval(32))
        #expect(model.studyPolicyBlockReason(now: now.addingTimeInterval(32)) == nil)
    }

    @Test func freshBlockingPolicyAndStaleReceiptCannotAuthorizeFetch() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        let rule = DomainRestriction(owner: .permanent, policyID: "video", title: "Video sites", domains: ["youtube.com"])
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
            submittedAt: now, commands: [.add(rule)]), now: now, calendar: .current)
        let snapshot = try backend.snapshot(now: now, calendar: .current)
        let model = ShieldViewModel(studyLibraryRoot: root.appendingPathComponent("library"), fixtureBackend: backend)
        try model.acceptBackendSnapshot(snapshot, now: now)
        #expect(model.studyPolicyBlockReason(now: now)?.contains("blocks YouTube") == true)
        // Contained fetches never open YouTube to the rest of the Mac: the
        // restriction does not pause them, but stale evidence still does.
        #expect(model.studyPolicyBlockReason(now: now, contained: true) == nil)
        #expect(model.studyPolicyBlockReason(now: now.addingTimeInterval(91), contained: true)?.contains("out of date") == true)
        // A fresh local observation timestamp cannot refresh an old service receipt.
        try model.acceptBackendSnapshot(snapshot, now: now.addingTimeInterval(91))
        #expect(model.studyPolicyBlockReason(now: now.addingTimeInterval(91))?.contains("out of date") == true)
    }
}

private struct CampaignAuthorityReader: AuthorityStateReading {
    let status: AuthorityStatus
    func read(now: Date) -> AuthorityStatus { status }
}

private struct CampaignEnforcementReader: EnforcementStateReading {
    func read() -> Result<EnforcementSnapshot, Error> {
        .success(EnforcementSnapshot(observedAt: .now, blockedDomains: [], managedSectionPresent: true))
    }
}
