import Foundation
import Testing
@testable import Shield

struct DevelopmentIsolationTests {
    @Test func defaultDevelopmentPathsCannotAliasInstalledShield() {
        #if DEBUG
        #expect(ShieldRuntime.isDevelopment)
        #expect(ShieldRuntime.serviceName == "com.kairos.ShieldDevelopment.backend")
        #expect(KairosConfig.directoryURL.lastPathComponent == "ShieldDevelopment")
        #expect(KairosConfig.fileURL.path != FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kairos/config.plist").path)
        #expect(AuthorityStateReader().fileURL == ShieldRuntime.authorityURL)
        #expect(HostsEnforcementReader().fileURL == ShieldRuntime.hostsURL)
        #expect(ShieldRuntime.authorityURL.path != "/usr/local/etc/kairos-policy-state.plist")
        #expect(ShieldRuntime.hostsURL.path != "/etc/hosts")
        let productionSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kairos/config.plist")
        #expect(!ShieldRuntime.permitsWrite(to: productionSupport))
        #expect(!ShieldRuntime.permitsWrite(to: URL(fileURLWithPath: "/etc/hosts")))
        #expect(!ShieldRuntime.permitsWrite(to: URL(fileURLWithPath: "/Library/Application Support/ShieldAuthority/state/authority.plist")))
        #expect(!ShieldRuntime.permitsWrite(to: URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.kairos.ShieldAuthority")))
        #expect(!ShieldRuntime.permitsWrite(to: URL(fileURLWithPath: "/Applications/Shield RC.app/Contents/Info.plist")))
        #expect(!ShieldRuntime.permitsWrite(to: URL(fileURLWithPath: "/usr/local/etc/kairos-policy-state.plist")))
        #expect(ShieldRuntime.permitsWrite(to: KairosConfig.fileURL))
        #expect(ShieldRuntime.permitsWrite(to: ShieldRuntime.fixtureDirectory.appendingPathComponent("hosts")))
        #endif
    }
}
