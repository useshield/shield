import Darwin
import Foundation

struct AuthorityServiceConfiguration: Codable {
    let version: Int
    let releaseSequence: UInt64
    let allowedUID: UInt32
    let clientRequirement: String
    let sourceCommit: String
    let timeZoneIdentifier: String

    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return value
    }

    func validate() throws {
        let prefix = "identifier \"com.kairos.ShieldRC\" and cdhash H\""
        guard version == 1, releaseSequence > 0, allowedUID >= 500,
              TimeZone(identifier: timeZoneIdentifier) != nil,
              sourceCommit.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil,
              clientRequirement.hasPrefix(prefix), clientRequirement.hasSuffix("\""),
              clientRequirement.dropFirst(prefix.count).dropLast().range(
                of: "^[a-f0-9]{40}$", options: .regularExpression) != nil else {
            throw FixtureBackendError.invalidRequest("Invalid installed authority configuration.")
        }
        try validateXPCSigningRequirement(clientRequirement)
    }
}

enum AuthorityInstallation {
    struct ReleaseCounter: Codable { let highest: UInt64 }
    static let name = "com.kairos.ShieldAuthority"
    static let root = URL(fileURLWithPath: "/Library/Application Support/ShieldAuthority", isDirectory: true)
    static let state = root.appendingPathComponent("state", isDirectory: true)
    static let configuration = root.appendingPathComponent("service.plist")
    static let executable = "/Library/PrivilegedHelperTools/com.kairos.ShieldAuthority"
    static let launchDaemon = "/Library/LaunchDaemons/com.kairos.ShieldAuthority.plist"
    static let releaseCounter = root.appendingPathComponent("highest-release.plist")

    static func requireRoot() throws {
        guard geteuid() == 0 else { throw FixtureBackendError.unsafeRoot }
    }

    static func validateProtectedPath(_ path: String, directory: Bool = false) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        let parts = path.split(separator: "/")
        for (index, part) in parts.enumerated() {
            current.appendPathComponent(String(part))
            var info = stat()
            let expected = index == parts.count - 1 && !directory ? mode_t(S_IFREG) : mode_t(S_IFDIR)
            guard lstat(current.path, &info) == 0, info.st_uid == 0,
                  (info.st_mode & mode_t(S_IFMT)) == expected,
                  (info.st_mode & 0o022) == 0 else {
                throw FixtureBackendError.uncertain("Unprotected installation path: \(current.path)")
            }
        }
    }

    static func readConfiguration(_ url: URL) throws -> AuthorityServiceConfiguration {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FixtureBackendError.uncertain("Missing service configuration.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_nlink == 1,
              (info.st_mode & 0o022) == 0, info.st_size > 0, info.st_size <= 16_384 else {
            throw FixtureBackendError.uncertain("Service configuration is unsafe.")
        }
        let bytes = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: 16_385) ?? Data()
        guard bytes.count <= 16_384 else { throw FixtureBackendError.uncertain("Configuration grew during read.") }
        let value = try PropertyListDecoder().decode(AuthorityServiceConfiguration.self, from: bytes)
        try value.validate()
        return value
    }

    static func preflight(candidate: URL) throws {
        try requireRoot()
        let next = try readConfiguration(candidate)
        if FileManager.default.fileExists(atPath: configuration.path) {
            try validateProtectedPath(configuration.path)
            let current = try readConfiguration(configuration)
            let highest = try PropertyListDecoder().decode(ReleaseCounter.self,
                from: AtomicFixtureStore(allowedRoot: root).read(releaseCounter)).highest
            guard next.releaseSequence > max(current.releaseSequence, highest),
                  next.allowedUID == current.allowedUID,
                  next.timeZoneIdentifier == current.timeZoneIdentifier else {
                throw FixtureBackendError.uncertain("Upgrade must advance release sequence and preserve authorized user.")
            }
            try validateProtectedPath(state.path, directory: true)
            let backend = try FixtureBackend(root: state, installedAuthority: true)
            // Read-only: an upgrade never rewrites policy as part of preflight.
            _ = try backend.snapshot(now: .now, calendar: current.calendar)
        } else {
            let existing = [root.path, executable, launchDaemon, "/Applications/Shield RC.app"]
            guard existing.allSatisfy({ path in
                var info = stat()
                return lstat(path, &info) != 0 && errno == ENOENT
            }) else {
                throw FixtureBackendError.uncertain("Partial installation needs inspection; nothing will be initialized.")
            }
            try requireNoLegacyInstallation(uid: next.allowedUID)
        }
    }

    static func requireNoLegacyInstallation(uid: UInt32) throws {
        var legacy = ["/usr/local/etc/kairos-policy-state.plist",
                      "/usr/local/libexec/kairos-reconcile",
                      "/Library/LaunchDaemons/com.kairos.scheduler.plist",
                      "/Applications/Kairos.app"]
        // Shield 1.1 installs as /Applications/Shield.app: only a different
        // app there (the 2026 prototype) is a leftover.
        if isForeignApp(at: publicApp) { legacy.append(publicApp) }
        guard let record = getpwuid(uid) else { throw FixtureBackendError.invalidRequest("Authorized user does not exist.") }
        let home = String(cString: record.pointee.pw_dir)
        legacy += [home + "/Library/Application Support/Kairos",
                   home + "/Library/Preferences/com.kairos.Kairos.plist"]
        for path in legacy {
            var info = stat()
            if lstat(path, &info) == 0 || errno != ENOENT {
                throw FixtureBackendError.uncertain("Legacy or unreadable Shield state at \(path). Preserve it and review migration first.")
            }
        }
        let hosts = try InstalledHostsEnforcer.readSystemHosts()
        guard !hosts.contains("# BEGIN KAIROS"), !hosts.contains("# END KAIROS"),
              !hosts.contains("# BEGIN SHIELD V1"), !hosts.contains("# END SHIELD V1") else {
            throw FixtureBackendError.uncertain("Existing managed hosts rules prohibit fresh initialization.")
        }
    }

    static let publicApp = "/Applications/Shield.app"
    static let appIdentifier = "com.kairos.ShieldRC"

    /// Something at `path` that isn't this Shield (unreadable counts as foreign).
    static func isForeignApp(at path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return errno != ENOENT }
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              let data = try? Data(contentsOf: plist), data.count <= 1_048_576,
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return true
        }
        return values["CFBundleIdentifier"] as? String != appIdentifier
    }

    static func loadInstalled() throws -> (AuthorityServiceConfiguration, FixtureBackend) {
        try requireRoot()
        for path in [executable, launchDaemon, configuration.path] { try validateProtectedPath(path) }
        try validateProtectedPath(state.path, directory: true)
        return (try readConfiguration(configuration), try FixtureBackend(root: state, installedAuthority: true))
    }

    static func recordRelease(_ sequence: UInt64) throws {
        let files = AtomicFixtureStore(allowedRoot: root)
        let previous = FileManager.default.fileExists(atPath: releaseCounter.path)
            ? try PropertyListDecoder().decode(ReleaseCounter.self, from: files.read(releaseCounter)).highest : 0
        try files.write(PropertyListEncoder().encode(ReleaseCounter(highest: max(sequence, previous))), to: releaseCounter)
    }
}
