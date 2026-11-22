import Foundation
import Testing
@testable import Shield

struct InstalledAuthorityTests {
    @Test func freshAuthorityConnectsBeforeFirstBlockAndNeverReinitializes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldBootstrap-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = try FixtureBackend(root: root)
        let now = Date()
        try backend.initializeEmptyAuthority(now: now, calendar: .current)
        let initial = try backend.snapshot(now: now, calendar: .current)
        #expect(initial.generation == 1)
        #expect(initial.authority.effectiveRestrictions.isEmpty)
        let permanent = DomainRestriction(owner: .permanent, policyID: "preserved", title: "Permanent",
                                          domains: ["example.com"])
        _ = try backend.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 1,
            submittedAt: now, commands: [.add(permanent)]), now: now, calendar: .current)
        #expect(throws: Error.self) { try backend.initializeEmptyAuthority(now: now, calendar: .current) }
        let reopened = try FixtureBackend(root: root)
        #expect(try reopened.snapshot(now: now, calendar: .current).committedRestrictions == [permanent])
        #expect(try reopened.verifiedReceipt().payload.generation == 2)
    }

    @Test func partialAndEmptyHistoricalStateCannotBeInitialized() throws {
        for name in ["authority.plist", "backend-state.plist", "receipt-key", "hosts"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldPartial-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let historical = root.appendingPathComponent(name)
            try Data().write(to: historical)
            let backend = try FixtureBackend(root: root)
            #expect(throws: Error.self) { try backend.initializeEmptyAuthority(now: .now, calendar: .current) }
            #expect(try Data(contentsOf: historical).isEmpty)
        }
    }

    @Test func installedHostsSectionPreservesLegacyAndDetectsConflictingRoutes() throws {
        let original = "127.0.0.1 localhost\n# BEGIN KAIROS\n0.0.0.0 legacy.example\n# END KAIROS\n10.0.0.1 intranet.example\n"
        let document = ManagedHostsDocument(beginMarker: "# BEGIN SHIELD V1", endMarker: "# END SHIELD V1")
        let updated = try document.replacingManagedSection(in: original, domains: ["new.example"])
        #expect(updated.hasPrefix(original))
        #expect(updated.contains("0.0.0.0 new.example"))
        #expect(document.conflictingMappings(in: updated, domains: ["intranet.example", "new.example"]) == ["intranet.example"])
        let released = try document.replacingManagedSection(in: updated, domains: [])
        #expect(released.contains("0.0.0.0 legacy.example"))
        #expect(!released.contains("new.example"))
    }

    @Test func protectedStoreRejectsHardlinksAndWritableArtifacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldStore-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        let linked = root.appendingPathComponent("linked")
        try Data("preserved".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: linked)
        let files = AtomicFixtureStore(allowedRoot: root)
        #expect(throws: Error.self) { try files.write(Data("changed".utf8), to: linked) }
        #expect(throws: Error.self) { try files.read(linked) }
        #expect(try String(contentsOf: original, encoding: .utf8) == "preserved")
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: original.path)
        #expect(throws: Error.self) { try files.read(original) }
    }
}
