import Darwin
import Foundation

// This bridge is enabled only by the root-owned disposable CI LaunchDaemon.
// It measures one selected macOS mechanism, not administrator resistance or
// browser-wide enforcement. The CI script restores /etc/hosts byte for byte.
struct DisposableHostsReconciler: FixtureExternalEnforcer {
    private let hostsURL = URL(fileURLWithPath: "/etc/hosts")

    func reconcile(_ snapshot: BackendSnapshot) throws -> EnforcementSnapshot {
        guard geteuid() == 0,
              ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
              ProcessInfo.processInfo.environment["SHIELD_CI_SYSTEM_HOSTS"] == "1" else {
            throw FixtureBackendError.unsafeRoot
        }
        let domains = snapshot.authority.effectiveRestrictions.reduce(into: Set<String>()) {
            $0.formUnion($1.domains)
        }
        let descriptor = open(hostsURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FixtureBackendError.uncertain("Cannot open disposable system hosts.") }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == 0, metadata.st_size > 0,
              metadata.st_size <= 1_048_576 else {
            throw FixtureBackendError.uncertain("System hosts ownership or size is unsafe.")
        }
        let originalData = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            .read(upToCount: 1_048_577) ?? Data()
        guard let original = String(data: originalData, encoding: .utf8) else {
            throw FixtureBackendError.uncertain("System hosts is not UTF-8.")
        }
        let updated = try ManagedHostsDocument().replacingManagedSection(in: original, domains: domains)
        if updated != original {
            let temporary = URL(fileURLWithPath: "/etc/.shield-ci-hosts-\(UUID().uuidString)")
            let output = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else {
                throw FixtureBackendError.uncertain("Cannot stage disposable system hosts.")
            }
            defer { try? FileManager.default.removeItem(at: temporary) }
            defer { close(output) }
            try FileHandle(fileDescriptor: output, closeOnDealloc: false)
                .write(contentsOf: Data(updated.utf8))
            guard fchmod(output, metadata.st_mode & 0o777) == 0,
                  fchown(output, 0, metadata.st_gid) == 0,
                  fsync(output) == 0,
                  rename(temporary.path, hostsURL.path) == 0 else {
                throw FixtureBackendError.uncertain("System hosts could not be atomically reconciled.")
            }
            let directory = open("/etc", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            if directory >= 0 { _ = fsync(directory); close(directory) }
        }
        guard case .success(let observed) = HostsEnforcementReader(fileURL: hostsURL).read(),
              observed.managedSectionPresent,
              observed.blockedDomains == domains else {
            throw FixtureBackendError.uncertain("Observed system hosts differs from committed authority.")
        }
        return observed
    }
}
