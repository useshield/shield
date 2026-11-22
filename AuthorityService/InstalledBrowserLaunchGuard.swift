import Darwin
import Foundation

// Closes the user's browser when it was started with a switch that routes
// around the blocked hosts (`BrowserLaunchGuard.findings`). Asks it to quit
// (SIGTERM) first, then forces it (SIGKILL) after a short grace period, the
// same way app blocking closes a blocked app. Only the configured user's
// processes, only browsers (they open http/https links, or are a known
// Chromium browser), never helpers, never Shield.
final class InstalledBrowserLaunchGuard: @unchecked Sendable {
    struct Action: Codable, Equatable, Sendable {
        let bundleID: String
        let switches: [String]
        let signal: String
        let at: Date
    }

    static let knownChromiumBundles: Set<String> = Set(BrowserManagedPolicy.chromiumDomains)
        .union(["com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
                "com.google.chrome.for.testing", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
                "com.microsoft.edgemac.Canary", "company.thebrowser.Browser", "com.operasoftware.Opera",
                "com.operasoftware.OperaGX", "com.openai.atlas", "ai.perplexity.comet"])

    private let scanner: ProcessScanner
    private let signal: @Sendable (Int32, Int32) -> Int32
    private let grace: TimeInterval
    private let lock = NSLock()
    private var arguments: [Int32: (launchedAt: Date, path: String, arguments: [String]?, mentions: Bool)] = [:]
    private var identities: [Int32: (launchedAt: Date, identity: AppIdentity?)] = [:]
    private var askedAt: [Int32: (launchedAt: Date, at: Date)] = [:]

    init(scanner: ProcessScanner, grace: TimeInterval = 3,
         signal: @escaping @Sendable (Int32, Int32) -> Int32 = { kill($0, $1) }) {
        self.scanner = scanner
        self.grace = grace
        self.signal = signal
    }

    @discardableResult
    func enforce(blockedHosts: Set<String>, now: Date = .now) -> [Action] {
        lock.lock()
        defer { lock.unlock() }
        guard !blockedHosts.isEmpty else {
            askedAt = [:]
            return []
        }
        let entries = scanner.running()
        let live = Dictionary(entries.map { ($0.pid, $0.launchedAt) }, uniquingKeysWith: { first, _ in first })
        arguments = arguments.filter { live[$0.key] == $0.value.launchedAt }
        identities = identities.filter { live[$0.key] == $0.value.launchedAt }
        askedAt = askedAt.filter { live[$0.key] == $0.value.launchedAt }
        var actions: [Action] = []
        for entry in entries where entry.pid != getpid() {
            let path = ProcessScanner.executablePath(entry.pid)
            guard path.contains(".app/Contents/MacOS/") else { continue }
            if arguments[entry.pid]?.launchedAt != entry.launchedAt || arguments[entry.pid]?.path != path {
                let argv = BrowserLaunchGuard.processArguments(pid: entry.pid)
                arguments[entry.pid] = (entry.launchedAt, path, argv, argv.map(BrowserLaunchGuard.mentionsBypassSwitch) ?? false)
            }
            // argv can't change without an exec, which changes the path: the verdict is cached.
            guard let cached = arguments[entry.pid], cached.mentions, let argv = cached.arguments else { continue }
            let findings = BrowserLaunchGuard.findings(arguments: argv, blockedHosts: blockedHosts)
            guard !findings.isEmpty else { continue }
            if identities[entry.pid]?.launchedAt != entry.launchedAt {
                identities[entry.pid] = (entry.launchedAt, ProcessScanner.identity(of: entry.pid))
            }
            let identity = identities[entry.pid]?.identity
            if identity.map({ $0.bundleID.lowercased().hasPrefix("com.kairos.") }) == true { continue }
            // Only browsers: other apps (scripts, Electron apps) are never closed.
            guard Self.isBrowser(identity, executable: path) else { continue }
            let signalNumber: Int32
            if let asked = askedAt[entry.pid] {
                guard now.timeIntervalSince(asked.at) >= grace else { continue }
                signalNumber = SIGKILL
            } else {
                signalNumber = SIGTERM
            }
            // Same process as scanned: no PID reuse in between.
            guard ProcessScanner.entry(entry.pid, owner: scanner.ownerUID)?.launchedAt == entry.launchedAt,
                  signal(entry.pid, signalNumber) == 0 else { continue }
            if signalNumber == SIGTERM { askedAt[entry.pid] = (entry.launchedAt, now) }
            actions.append(Action(bundleID: identity?.bundleID ?? Self.bundle(of: path)?.lastPathComponent ?? "unknown", switches: findings.map(\.switchName),
                                  signal: signalNumber == SIGTERM ? "quit" : "force quit", at: now))
        }
        return actions
    }

    /// A web browser: by signature (known Chromium browser, or it opens
    /// http/https links), else by its bundle on disk. Copies of Chromium
    /// downloaded or rebuilt by hand often carry no bound Info.plist in their
    /// signature, so the bundle's own Info.plist and its "<Name> Framework"
    /// (Chromium's layout; Electron apps ship "Electron Framework") count too.
    static func isBrowser(_ identity: AppIdentity?, executable: String) -> Bool {
        if let identity, identity.opensWebLinks || knownChromiumBundles.contains(identity.bundleID) { return true }
        guard let bundle = bundle(of: executable) else { return false }
        let plist = NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        if let id = plist?["CFBundleIdentifier"] as? String, knownChromiumBundles.contains(id) { return true }
        if ProcessScanner.opensWebLinks(plist) { return true }
        let frameworks = (try? FileManager.default.contentsOfDirectory(
            atPath: bundle.appendingPathComponent("Contents/Frameworks").path)) ?? []
        return frameworks.contains { $0.hasSuffix(" Framework.framework") && $0 != "Electron Framework.framework" }
    }

    /// The .app whose Contents/MacOS holds `executable`.
    static func bundle(of executable: String) -> URL? {
        guard let range = executable.range(of: ".app/Contents/MacOS/") else { return nil }
        return URL(fileURLWithPath: String(executable[..<range.lowerBound]) + ".app")
    }
}

/// What the browser layers did, for `inspect` and troubleshooting: root-owned
/// JSON beside the authority state, rewritten only when something changes.
/// No addresses, URLs or switch values are ever stored.
final class BrowserLayersEvidenceStore: @unchecked Sendable {
    struct Record: Codable, Equatable {
        var policyPatternCount = 0
        var policyFiles: [String] = []
        var foreignPolicyFiles: [String] = []
        var policyProblem: String?
        /// Sites blocked by hosts only: rules that don't fit Chrome's limit.
        var hostsOnlySites = 0
        var recentClosures: [InstalledBrowserLaunchGuard.Action] = []
    }

    private let path: String
    private let lock = NSLock()
    private var record = Record()

    init(path: String) { self.path = path }

    func record(policy: InstalledBrowserPolicyWriter.Evidence, closed: [InstalledBrowserLaunchGuard.Action],
                hostsOnlySites: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        var next = record
        next.policyPatternCount = policy.patternCount
        next.policyFiles = policy.current
        next.foreignPolicyFiles = policy.foreign
        next.policyProblem = policy.problem
        next.hostsOnlySites = hostsOnlySites
        next.recentClosures = Array((record.recentClosures + closed).suffix(50))
        guard next != record else { return }
        record = next
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(next) else { return }
        let staging = path + ".tmp-\(UUID().uuidString)"
        let output = open(staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { return }
        defer { close(output); unlink(staging) }
        try? FileHandle(fileDescriptor: output, closeOnDealloc: false).write(contentsOf: data)
        if fsync(output) == 0 { rename(staging, path) }
    }
}
