import Darwin
import Foundation

struct ReconciliationPaths: Sendable {
    let authorityURL: URL
    let hostsURL: URL
    let lockURL: URL

    func validate(allowedRoot: URL) throws {
        let root = allowedRoot.standardizedFileURL.path
        for url in [authorityURL, hostsURL, lockURL] {
            let path = url.standardizedFileURL.path
            guard path == root || path.hasPrefix(root + "/") else {
                throw ReconciliationError.pathOutsideAllowedRoot(path)
            }
        }
    }
}

enum ReconciliationError: Error, LocalizedError {
    case pathOutsideAllowedRoot(String)
    case symbolicLink(String)
    case lockUnavailable
    case authorityUncertain(AuthorityReadError)
    case invalidRequest(String)
    case unmanagedHostsMarkers
    case unsafeOwnership(String)

    var errorDescription: String? {
        switch self {
        case .pathOutsideAllowedRoot(let path): "Path is outside the fixture root: \(path)"
        case .symbolicLink(let path): "Symbolic links are not allowed: \(path)"
        case .lockUnavailable: "The reconciliation lock could not be acquired."
        case .authorityUncertain(let error): "Reconciliation stopped: \(error.localizedDescription)"
        case .invalidRequest(let detail): "Invalid request: \(detail)"
        case .unmanagedHostsMarkers: "The managed hosts markers are malformed."
        case .unsafeOwnership(let path): "Fixture ownership or permissions are unsafe: \(path)"
        }
    }
}

struct ReconciliationPlan: Equatable, Sendable {
    let effectiveDomains: Set<String>
    let immediateStrengthening: Set<String>
    let delayedWeakening: Set<String>

    var status: ReconciliationStatus {
        switch (immediateStrengthening.isEmpty, delayedWeakening.isEmpty) {
        case (true, true): .unchanged
        case (false, true): .strengthening
        case (true, false): .weakeningDeferred
        case (false, false): .strengtheningAndWeakeningDeferred
        }
    }
}

enum ReconciliationStatus: Equatable, Sendable {
    case unchanged
    case strengthening
    case weakeningDeferred
    case strengtheningAndWeakeningDeferred
}

struct AuthorityRecoveryPolicy: Sendable {
    func plan(
        authority: AuthorityStatus,
        requestedDomains: Set<String>
    ) throws -> ReconciliationPlan {
        guard case .valid(let state) = authority else {
            if case .unavailable(let error) = authority {
                throw ReconciliationError.authorityUncertain(error)
            }
            throw ReconciliationError.authorityUncertain(.missing)
        }

        let committed = state.effectiveRestrictions.reduce(into: Set<String>()) {
            $0.formUnion($1.domains.map { $0.lowercased() })
        }
        guard requestedDomains.allSatisfy(PolicyValidation.validDomain) else {
            throw ReconciliationError.invalidRequest("Domains must be canonical DNS names.")
        }
        let normalizedRequest = requestedDomains
        let strengthening = normalizedRequest.subtracting(committed)
        let weakening = committed.subtracting(normalizedRequest)

        // Strengthening applies now. Weakening remains enforced until a valid
        // commitment-specific effective time is reached by the policy engine.
        return ReconciliationPlan(
            effectiveDomains: committed.union(strengthening),
            immediateStrengthening: strengthening,
            delayedWeakening: weakening
        )
    }
}

struct ManagedHostsDocument: Sendable {
    static let beginMarker = "# BEGIN KAIROS"
    static let endMarker = "# END KAIROS"
    let sectionBegin: String
    let sectionEnd: String

    init(beginMarker: String = Self.beginMarker, endMarker: String = Self.endMarker) {
        self.sectionBegin = beginMarker
        self.sectionEnd = endMarker
    }

    func conflictingMappings(in text: String, domains: Set<String>) -> Set<String> {
        var inside = false
        var conflicts = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == sectionBegin { inside = true; continue }
            if line == sectionEnd { inside = false; continue }
            guard !inside else { continue }
            let fields = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count > 1, !["0.0.0.0", "127.0.0.1", "::1"].contains(fields[0]) else { continue }
            conflicts.formUnion(fields.dropFirst().map { $0.lowercased() }.filter(domains.contains))
        }
        return conflicts
    }

    func replacingManagedSection(
        in original: String,
        domains: Set<String>
    ) throws -> String {
        guard domains.allSatisfy(PolicyValidation.validDomain) else {
            throw ReconciliationError.invalidRequest("Managed hosts contains an invalid domain.")
        }
        let lines = original.components(separatedBy: .newlines)
        let beginIndices = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == sectionBegin }
        let endIndices = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == sectionEnd }

        guard beginIndices.count <= 1, endIndices.count <= 1 else {
            throw ReconciliationError.unmanagedHostsMarkers
        }

        var preserved = lines
        if let begin = beginIndices.first, let end = endIndices.first {
            guard begin < end else { throw ReconciliationError.unmanagedHostsMarkers }
            preserved.removeSubrange(begin...end)
        } else if !beginIndices.isEmpty || !endIndices.isEmpty {
            throw ReconciliationError.unmanagedHostsMarkers
        }

        while preserved.last?.isEmpty == true {
            preserved.removeLast()
        }

        let managed = [
            sectionBegin,
            "# Generated from validated authority state. Do not edit this section."
        ] + domains.sorted().flatMap { ["0.0.0.0 \($0)", "::1 \($0)"] } + [sectionEnd]

        return (preserved + [""] + managed + [""]).joined(separator: "\n")
    }

    /// The file with this section taken out and every other line kept, for
    /// removing Shield. Unchanged if there is no section.
    func removingManagedSection(in original: String) throws -> String {
        var lines = original.components(separatedBy: .newlines)
        let begins = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == sectionBegin }
        let ends = lines.indices.filter { lines[$0].trimmingCharacters(in: .whitespaces) == sectionEnd }
        if begins.isEmpty && ends.isEmpty { return original }
        guard begins.count == 1, ends.count == 1, let begin = begins.first, let end = ends.first, begin < end else {
            throw ReconciliationError.unmanagedHostsMarkers
        }
        lines.removeSubrange(begin...end)
        while lines.last?.isEmpty == true { lines.removeLast() }
        return (lines + [""]).joined(separator: "\n")
    }
}

struct AtomicFixtureStore: Sendable {
    let allowedRoot: URL

    func write(_ data: Data, to destination: URL) throws {
        try ShieldRuntime.requireIsolatedWrite(to: destination)
        let parent = try StoreDirectory(root: allowedRoot, destination: destination)
        try parent.validateLeaf()
        let temporary = ".\(parent.name).\(UUID().uuidString).tmp"
        let descriptor = openat(parent.descriptor, temporary,
                                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor); unlinkat(parent.descriptor, temporary, 0) }
        try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
        try parent.validateLeaf()
        guard renameat(parent.descriptor, temporary, parent.descriptor, parent.name) == 0,
              fsync(parent.descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func read(_ url: URL) throws -> Data {
        let parent = try StoreDirectory(root: allowedRoot, destination: url)
        try parent.validateLeaf()
        let descriptor = openat(parent.descriptor, parent.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadUnknown) }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              (metadata.st_mode & 0o022) == 0, metadata.st_size <= StateFileLimits.maximumHostsBytes else {
            throw ReconciliationError.unsafeOwnership(url.path)
        }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            .read(upToCount: StateFileLimits.maximumHostsBytes + 1) ?? Data()
        guard data.count <= StateFileLimits.maximumHostsBytes else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    func remove(_ url: URL) throws {
        try ShieldRuntime.requireIsolatedWrite(to: url)
        let parent = try StoreDirectory(root: allowedRoot, destination: url)
        try parent.validateLeaf()
        guard unlinkat(parent.descriptor, parent.name, 0) == 0,
              fsync(parent.descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func validatePath(_ url: URL) throws {
        try StoreDirectory(root: allowedRoot, destination: url).validateLeaf()
    }
}

// File operations stay relative to open directory descriptors. Replacing a
// validated directory with a symlink cannot redirect a later read or rename.
private final class StoreDirectory {
    let descriptor: Int32
    let name: String

    init(root: URL, destination: URL) throws {
        let base = root.standardizedFileURL.path
        let target = destination.standardizedFileURL.path
        guard root.isFileURL, destination.isFileURL, target.hasPrefix(base + "/") else {
            throw ReconciliationError.pathOutsideAllowedRoot(target)
        }
        var parts = target.dropFirst(base.count + 1).split(separator: "/").map(String.init)
        guard let leaf = parts.popLast(), !leaf.isEmpty else {
            throw ReconciliationError.pathOutsideAllowedRoot(target)
        }
        name = leaf
        var current = open(base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw ReconciliationError.unsafeOwnership(base) }
        do {
            try Self.validateDirectory(current, path: base)
            for part in parts {
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ReconciliationError.unsafeOwnership(target) }
                close(current)
                current = next
                try Self.validateDirectory(current, path: target)
            }
        } catch { close(current); throw error }
        descriptor = current
    }

    private static func validateDirectory(_ descriptor: Int32, path: String) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(),
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              (info.st_mode & 0o022) == 0 else { throw ReconciliationError.unsafeOwnership(path) }
    }

    func validateLeaf() throws {
        var info = stat()
        if fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  info.st_uid == geteuid(), info.st_nlink == 1,
                  (info.st_mode & 0o022) == 0 else { throw ReconciliationError.unsafeOwnership(name) }
        } else if errno != ENOENT { throw ReconciliationError.unsafeOwnership(name) }
    }

    deinit { close(descriptor) }

}

final class ExclusiveFileLock: @unchecked Sendable {
    private let descriptor: Int32

    init(url: URL) throws {
        try ShieldRuntime.requireIsolatedWrite(to: url)
        let parent = try StoreDirectory(root: url.deletingLastPathComponent(), destination: url)
        try parent.validateLeaf()
        descriptor = openat(parent.descriptor, parent.name, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            throw ReconciliationError.lockUnavailable
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              (metadata.st_mode & 0o022) == 0 else {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw ReconciliationError.unsafeOwnership(url.path)
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

struct FixtureReconciler: Sendable {
    let paths: ReconciliationPaths
    let allowedRoot: URL
    let maximumAuthorityAge: TimeInterval

    func reconcile(requestedDomains: Set<String>, now: Date) throws -> ReconciliationPlan {
        try paths.validate(allowedRoot: allowedRoot)
        let store = AtomicFixtureStore(allowedRoot: allowedRoot)
        for path in [paths.authorityURL, paths.hostsURL, paths.lockURL] {
            try store.validatePath(path)
        }
        let lock = try ExclusiveFileLock(url: paths.lockURL)

        let authority = AuthorityStateReader(
            fileURL: paths.authorityURL,
            maximumAge: maximumAuthorityAge
        ).read(now: now)
        let plan = try AuthorityRecoveryPolicy().plan(
            authority: authority,
            requestedDomains: requestedDomains
        )

        guard let originalHosts = String(data: try store.read(paths.hostsURL), encoding: .utf8) else {
            throw ReconciliationError.invalidRequest("Fixture hosts must be UTF-8.")
        }
        let rendered = try ManagedHostsDocument().replacingManagedSection(
            in: originalHosts,
            domains: plan.effectiveDomains
        )
        try store.write(
            Data(rendered.utf8),
            to: paths.hostsURL
        )
        withExtendedLifetime(lock) {}
        return plan
    }
}
