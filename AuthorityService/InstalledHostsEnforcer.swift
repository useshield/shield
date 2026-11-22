import Darwin
import Foundation

// The installed service owns only SHIELD V1 markers. It never takes over or
// deletes the legacy KAIROS section or any unrelated hosts entry.
// Calls are serialized by the service's operation lock.
final class InstalledHostsEnforcer: FixtureExternalEnforcer, @unchecked Sendable {
    let source: EnforcementSource = .installedSystemHosts
    static let begin = "# BEGIN SHIELD V1"
    static let end = "# END SHIELD V1"
    private var cacheRefreshPending = true
    private var resolution: ResolverObservation?
    /// The last time the file was read back and matched (R4): its stamp, the
    /// blocked set it matched, and when. Until something writes the file, or
    /// `fullCheckInterval` passes, it isn't parsed again.
    private var verified: (stamp: FileStamp, domains: Set<String>, at: Date)?
    /// The blocked set of the last snapshot, built once per committed generation.
    private var blocked: (generation: UInt64, generatedAt: Date, domains: Set<String>)?
    static let fullCheckInterval: TimeInterval = 30

    static func readSystemHosts() throws -> String {
        let directory = try openDirectory()
        defer { close(directory) }
        return try readHosts(in: directory).text
    }

    private static func openDirectory() throws -> Int32 {
        let descriptor = open("/private/etc", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard descriptor >= 0 else { throw FixtureBackendError.uncertain("Cannot open system configuration directory.") }
        guard fstat(descriptor, &info) == 0, info.st_uid == 0, (info.st_mode & 0o022) == 0 else {
            close(descriptor)
            throw FixtureBackendError.uncertain("System configuration directory is unsafe.")
        }
        return descriptor
    }

    private static func readHosts(in directory: Int32) throws -> (text: String, metadata: stat) {
        let descriptor = openat(directory, "hosts", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FixtureBackendError.uncertain("Cannot read system hosts.") }
        defer { close(descriptor) }
        let info = try safeMetadata(descriptor)
        let bytes = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: StateFileLimits.maximumHostsBytes + 1) ?? Data()
        guard bytes.count == Int(info.st_size) else { throw FixtureBackendError.uncertain("System hosts changed while it was read.") }
        guard bytes.count <= StateFileLimits.maximumHostsBytes, let text = String(data: bytes, encoding: .utf8) else {
            throw FixtureBackendError.uncertain("System hosts is oversized or not UTF-8.")
        }
        return (text, info)
    }

    /// The same safety checks as reading, on an open file.
    private static func safeMetadata(_ descriptor: Int32) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == 0, info.st_nlink == 1,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), (info.st_mode & 0o022) == 0,
              info.st_size > 0, info.st_size <= StateFileLimits.maximumHostsBytes else {
            throw FixtureBackendError.uncertain("Unsafe system hosts metadata.")
        }
        return info
    }

    /// The hosts file's stamp, with the same safety checks, without reading it.
    private static func stampHosts(in directory: Int32) throws -> FileStamp {
        let descriptor = openat(directory, "hosts", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FixtureBackendError.uncertain("Cannot read system hosts.") }
        defer { close(descriptor) }
        return FileStamp(try safeMetadata(descriptor))
    }

    func reconcile(_ snapshot: BackendSnapshot) throws -> EnforcementSnapshot {
        try AuthorityInstallation.requireRoot()
        let domains: Set<String>
        if let blocked, blocked.generation == snapshot.generation, blocked.generatedAt == snapshot.authority.generatedAt {
            domains = blocked.domains
        } else {
            domains = snapshot.authority.effectiveRestrictions.reduce(into: Set<String>()) { $0.formUnion($1.domains) }
            blocked = (snapshot.generation, snapshot.authority.generatedAt, domains)
        }
        let directory = try Self.openDirectory()
        defer { close(directory) }
        let now = Date()
        if let verified, !cacheRefreshPending, verified.domains == domains, now >= verified.at,
           now.timeIntervalSince(verified.at) < Self.fullCheckInterval,
           try Self.stampHosts(in: directory) == verified.stamp {
            return observation(snapshot, domains: domains)
        }
        self.verified = nil
        let original = try Self.readHosts(in: directory)
        let document = ManagedHostsDocument(beginMarker: Self.begin, endMarker: Self.end)
        let updated = try document.replacingManagedSection(in: original.text, domains: domains)
        let conflicts = document.conflictingMappings(in: original.text, domains: domains)
        guard conflicts.isEmpty else {
            throw FixtureBackendError.uncertain("Existing hosts mappings conflict with these blocks: \(conflicts.sorted().joined(separator: ", ")). Their original entries were preserved.")
        }
        if updated != original.text {
            try Self.write(updated, replacing: original, in: directory)
            cacheRefreshPending = true
        }
        if cacheRefreshPending {
            try Self.runSystemTool("/usr/bin/dscacheutil", ["-flushcache"])
            try Self.runSystemTool("/usr/bin/killall", ["-HUP", "mDNSResponder"])
            cacheRefreshPending = false
        }
        let final = try Self.readHosts(in: directory)
        let observed = try HostsEnforcementReader(beginMarker: Self.begin, endMarker: Self.end).parse(final.text)
        guard observed.managedSectionPresent, observed.domains == domains else {
            throw FixtureBackendError.uncertain("System hosts does not match authority.")
        }
        // The stamp is taken from the same open file that was just read and
        // matched; if anything replaced it since, the next pass reads it again.
        verified = (FileStamp(final.metadata), domains, now)
        return observation(snapshot, domains: domains)
    }

    private static func write(_ updated: String, replacing original: (text: String, metadata: stat),
                              in directory: Int32) throws {
        let name = ".shield-authority-\(UUID()).tmp"
        let output = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw FixtureBackendError.uncertain("Cannot stage system hosts.") }
        defer { close(output); unlinkat(directory, name, 0) }
        try FileHandle(fileDescriptor: output, closeOnDealloc: false).write(contentsOf: Data(updated.utf8))
        guard fchown(output, 0, original.metadata.st_gid) == 0,
              fchmod(output, original.metadata.st_mode & 0o777) == 0, fsync(output) == 0,
              try readHosts(in: directory).text == original.text else {
            throw FixtureBackendError.uncertain("System hosts changed during reconciliation.")
        }
        guard renameat(directory, name, directory, "hosts") == 0, fsync(directory) == 0 else {
            throw FixtureBackendError.uncertain("System hosts could not be committed.")
        }
    }

    /// Removing Shield: takes out only Shield's section, keeps every other
    /// line, refreshes the resolver, and reads the file back.
    func removeManagedSection() throws {
        try AuthorityInstallation.requireRoot()
        let directory = try Self.openDirectory()
        defer { close(directory) }
        let original = try Self.readHosts(in: directory)
        let document = ManagedHostsDocument(beginMarker: Self.begin, endMarker: Self.end)
        let updated = try document.removingManagedSection(in: original.text)
        if updated != original.text { try Self.write(updated, replacing: original, in: directory) }
        try Self.runSystemTool("/usr/bin/dscacheutil", ["-flushcache"])
        try Self.runSystemTool("/usr/bin/killall", ["-HUP", "mDNSResponder"])
        guard try !HostsEnforcementReader(beginMarker: Self.begin, endMarker: Self.end)
            .parse(Self.readHosts(in: directory).text).managedSectionPresent else {
            throw FixtureBackendError.uncertain("Shield's hosts section is still present.")
        }
        verified = nil
    }

    private func observation(_ snapshot: BackendSnapshot, domains: Set<String>) -> EnforcementSnapshot {
        if resolution?.generation != snapshot.generation ||
            Date().timeIntervalSince(resolution?.observedAt ?? .distantPast) >= 20 {
            resolution = ResolverProbe.childObservation(generation: snapshot.generation, domains: domains)
        }
        return EnforcementSnapshot(observedAt: .now, blockedDomains: domains, managedSectionPresent: true,
                                   resolution: resolution)
    }

    private static func runSystemTool(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        guard done.wait(timeout: .now() + 5) == .success else {
            kill(process.processIdentifier, SIGKILL)
            throw FixtureBackendError.uncertain("Resolver cache refresh timed out.")
        }
        guard process.terminationStatus == 0 else {
            throw FixtureBackendError.uncertain("Resolver cache refresh failed: \(executable)")
        }
    }
}
