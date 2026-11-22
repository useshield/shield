import CryptoKit
import Darwin
import Foundation

// Writes `BrowserManagedPolicy` documents where browsers read MANDATORY
// policy on a Mac without MDM: /Library/Managed Preferences (machine) and
// /Library/Managed Preferences/<owner> (Chrome watches only this one, so a
// change there applies in seconds; the machine copy is the durable fallback
// that Chrome rereads every 15 minutes). Same discipline as the hosts enforcer:
//   - open each folder without following links and require safe ownership;
//   - write a temporary file, set owner and mode, fsync, rename into place;
//   - never touch a file Shield didn't write (a ledger says which files are
//     Shield's), so an existing company or user policy is preserved and
//     reported instead of overwritten;
//   - rewrite only when the bytes differ, and restore a Shield file that was
//     edited or deleted (macOS may delete profile-less managed files at
//     reboot) on the next pass, every 2 seconds in the service.
// Failures never stop the hosts layer; they are returned as evidence.
final class InstalledBrowserPolicyWriter: @unchecked Sendable {
    struct Evidence: Codable, Equatable, Sendable {
        var observedAt: Date
        var patternCount: Int
        /// Policy files (folder/domain) holding exactly this pass's block list.
        var current: [String]
        /// Policy files Shield didn't write: left untouched.
        var foreign: [String]
        var problem: String?
    }

    static let productionRoot = "/Library/Managed Preferences"

    let folders: [String]
    let ledgerPath: String
    /// 0 in production. Tests use their own user and temporary folders.
    let expectedOwner: uid_t
    /// Runs after any policy file changed. Stage 0 (a test Mac) showed
    /// the root preferences daemon keeps serving its cached copy of a managed
    /// file that was rewritten or even deleted, so browsers never see the
    /// change without a refresh. Returns false when the refresh failed.
    /// macOS also rebuilds the user's managed folder whenever profiles or
    /// Screen Time change, deleting Shield's file there; the next pass (2 s)
    /// writes it again and refreshes.
    let afterChange: () -> Bool
    private let lock = NSLock()
    // Starts pending: a change written just before a crash or restart is
    // still announced (one cache refresh per service start).
    private var refreshPending = true
    private var built: (domains: Set<String>, bytes: [String: Data], patternCount: Int, problem: String?)?

    init(folders: [String], ledgerPath: String, expectedOwner: uid_t, afterChange: @escaping () -> Bool = { true }) {
        self.folders = folders
        self.ledgerPath = ledgerPath
        self.expectedOwner = expectedOwner
        self.afterChange = afterChange
    }

    /// The installed service: the machine folder plus the user's folder.
    static func installed(ownerUID: uid_t) -> InstalledBrowserPolicyWriter {
        var folders = [productionRoot]
        if let entry = getpwuid(ownerUID), let name = String(validatingCString: entry.pointee.pw_name),
           !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") {
            folders.append(productionRoot + "/" + name)
        }
        return InstalledBrowserPolicyWriter(folders: folders,
            ledgerPath: "/Library/Application Support/ShieldAuthority/browser-policy-ledger.json", expectedOwner: 0,
            afterChange: { refreshPreferencesDaemon() })
    }

    /// Makes the preferences daemons drop their cached managed files by
    /// restarting them (launchd starts each again on its next request).
    /// Evidence on a test Mac:
    ///   - `mcxrefresh` clears the cache but rebuilds the user's managed folder
    ///     from installed profiles, deleting Shield's file there (Stage 0b/0c);
    ///   - restarting only the root daemon applied a new block but not a lift;
    ///   - restarting every cfprefsd applied blocks and lifts from both folders,
    ///     and left the Screen Time files untouched (Stage 0c).
    /// Runs only when a policy file changed: schedule edges, Home/away, or
    /// macOS rebuilding the folder.
    static func refreshPreferencesDaemon() -> Bool {
        runTool("/usr/bin/killall", ["cfprefsd"])
    }

    // Tried and disproven (Stage 0f, a test Mac): posting macOS's
    // managed-preferences notification (com.apple.MCX.preferencesChanged,
    // user session or a root job in the system domain), with or without this
    // restart, never made an already-running process see a changed managed
    // value within 12 s. Running browsers keep their list until reopened; the
    // app's Reopen notice covers that.

    /// Runs a system tool with a 10-second limit; true when it exited 0.
    static func runTool(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return false }
        guard done.wait(timeout: .now() + 10) == .success else {
            kill(process.processIdentifier, SIGKILL)
            return false
        }
        return process.terminationStatus == 0
    }

    func reconcile(domains: Set<String>, now: Date = .now) -> Evidence {
        lock.lock()
        defer { lock.unlock() }
        var evidence = Evidence(observedAt: now, patternCount: 0, current: [], foreign: [], problem: nil)
        // The documents depend only on the blocked set: built once per change,
        // not every pass. The files themselves are still read every pass, so an
        // edited or deleted file is put back within one pass.
        if built?.domains != domains {
            switch BrowserManagedPolicy.documents(for: domains) {
            case .success(let documents):
                var bytes: [String: Data] = [:]
                for (domain, document) in documents {
                    guard let data = try? BrowserManagedPolicy.propertyList(document) else { continue }
                    bytes[domain] = data
                }
                built = (domains, bytes, BrowserManagedPolicy.chromiumPatterns(domains).count, nil)
            case .failure(.tooManyPatterns(let count)):
                built = (domains, [:], 0, "Too many blocked sites for browser policy (\(count)); hosts blocking still applies.")
            }
        }
        guard let built, built.problem == nil else {
            evidence.problem = built?.problem
            return evidence
        }
        let documents = built.bytes
        evidence.patternCount = built.patternCount
        var ledger = readLedger()
        var ledgerChanged = false
        var problems: [String] = []
        for folderPath in folders {
            do {
                let folder = try openFolder(folderPath, create: folderPath == folders.first)
                defer { close(folder) }
                for domain in documents.keys.sorted() {
                    let name = domain + ".plist"
                    let key = folderPath + "/" + name
                    let desired = documents[domain]!
                    let existing = try readFile(name, in: folder)
                    // Shield's file once written (the ledger says so). A file identical to
                    // Shield's is adopted; any other file Shield never wrote is preserved.
                    if let existing, existing != desired, ledger[key] == nil {
                        evidence.foreign.append(key)
                        continue
                    }
                    if existing != desired {
                        try writeFile(name, bytes: desired, in: folder)
                        refreshPending = true
                        guard try readFile(name, in: folder) == desired else {
                            throw Failure("\(key) did not read back as written.")
                        }
                    }
                    let hash = Self.hash(desired)
                    if ledger[key] != hash { ledger[key] = hash; ledgerChanged = true }
                    evidence.current.append(key)
                }
            } catch {
                problems.append((error as? Failure)?.message ?? "\(folderPath) could not be written.")
            }
        }
        if ledgerChanged {
            do { try writeLedger(ledger) } catch { problems.append("The browser policy ledger could not be saved.") }
        }
        // Retried every pass until it succeeds, so a failed refresh never strands a change.
        if refreshPending {
            if afterChange() { refreshPending = false } else { problems.append("Browsers haven't picked up the change yet.") }
        }
        evidence.problem = problems.isEmpty ? nil : problems.joined(separator: " ")
        return evidence
    }

    /// Removes only the files Shield wrote and that are still exactly as Shield
    /// left them (a release rollback). Anything else stays.
    @discardableResult
    func withdraw() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var ledger = readLedger()
        var removed: [String] = []
        for (key, recorded) in ledger.sorted(by: { $0.key < $1.key }) {
            let folderPath = (key as NSString).deletingLastPathComponent
            let name = (key as NSString).lastPathComponent
            guard folders.contains(folderPath) else { continue }
            let folder = try openFolder(folderPath, create: false)
            defer { close(folder) }
            if let existing = try readFile(name, in: folder), Self.hash(existing) == recorded {
                guard unlinkat(folder, name, 0) == 0 else { throw Failure("Could not remove \(key).") }
                fsync(folder)
                removed.append(key)
            }
            ledger[key] = nil
        }
        try writeLedger(ledger)
        if !removed.isEmpty { _ = afterChange() }
        return removed
    }

    // MARK: Files

    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func openFolder(_ path: String, create: Bool) throws -> Int32 {
        if create && !FileManager.default.fileExists(atPath: path) {
            // macOS normally has it; create it not writable by others.
            guard mkdir(path, 0o755) == 0 || errno == EEXIST else { throw Failure("Cannot create \(path).") }
        }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure("Cannot open \(path).") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == expectedOwner, (info.st_mode & 0o022) == 0 else {
            close(descriptor)
            throw Failure("\(path) has unsafe ownership.")
        }
        return descriptor
    }

    private func readFile(_ name: String, in folder: Int32) throws -> Data? {
        let descriptor = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw Failure("Cannot read \(name).")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size <= 1_048_576 else { throw Failure("\(name) is not a plain policy file.") }
        return try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: 1_048_577) ?? Data()
    }

    private func writeFile(_ name: String, bytes: Data, in folder: Int32) throws {
        let staging = ".shield-browser-\(UUID().uuidString).tmp"
        let output = openat(folder, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Failure("Cannot stage \(name).") }
        defer { close(output); unlinkat(folder, staging, 0) }
        try FileHandle(fileDescriptor: output, closeOnDealloc: false).write(contentsOf: bytes)
        if expectedOwner == 0 { guard fchown(output, 0, 0) == 0 else { throw Failure("Cannot own \(name).") } }
        guard fchmod(output, 0o644) == 0, fsync(output) == 0 else { throw Failure("Cannot finish \(name).") }
        guard renameat(folder, staging, folder, name) == 0, fsync(folder) == 0 else {
            throw Failure("Cannot commit \(name).")
        }
    }

    private func readLedger() -> [String: String] {
        guard let data = FileManager.default.contents(atPath: ledgerPath),
              let ledger = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return ledger
    }

    private func writeLedger(_ ledger: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(ledger)
        let staging = ledgerPath + ".tmp-\(UUID().uuidString)"
        let output = open(staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Failure("Cannot stage the browser policy ledger.") }
        defer { close(output); unlink(staging) }
        try FileHandle(fileDescriptor: output, closeOnDealloc: false).write(contentsOf: data)
        guard fsync(output) == 0, rename(staging, ledgerPath) == 0 else {
            throw Failure("Cannot save the browser policy ledger.")
        }
    }
}
