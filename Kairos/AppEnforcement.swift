import Darwin
import Foundation
import Security

// App blocking, stage 1 (docs/app-blocking-design.md): find running apps by
// their code signature and close the blocked ones. `AppSweep` decides; this
// file looks at processes and sends the signals. Only one user's processes are
// ever considered, and never this process, launchd, or a never-blockable app.

struct ProcessScanner: Sendable {
    struct Entry: Equatable, Sendable {
        let pid: Int32
        let launchedAt: Date
    }

    let ownerUID: uid_t
    // Tests: never look beyond these processes.
    var onlyPIDs: Set<Int32>? = nil

    func running() -> [Entry] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [Int32](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<Int32>.size)))
        return pids.prefix(max(0, count)).compactMap { pid in
            guard pid > 1, onlyPIDs?.contains(pid) ?? true else { return nil }
            return Self.entry(pid, owner: ownerUID)
        }
    }

    /// The process's start time, or nil when it is gone or someone else's.
    static func entry(_ pid: Int32, owner: uid_t) -> Entry? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == owner else { return nil }
        let launched = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) +
                            TimeInterval(info.pbi_start_tvusec) / 1_000_000)
        return Entry(pid: pid, launchedAt: launched)
    }

    /// The running executable. It changes when a process execs another
    /// program, which keeps the same PID and start time.
    static func executablePath(_ pid: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : ""
    }

    /// Identity from the running code's signature.
    static func identity(of pid: Int32) -> AppIdentity? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess, let code else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        return identity(of: staticCode)
    }

    /// Identity of an app on disk, for choosing what to block.
    static func identity(ofBundleAt url: URL) -> AppIdentity? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        return identity(of: staticCode)
    }

    /// Info.plist claims the http or https URL scheme: how macOS knows a browser.
    static func opensWebLinks(_ plist: [String: Any]?) -> Bool {
        let types = plist?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return types.contains { type in
            (type["CFBundleURLSchemes"] as? [String] ?? []).contains { ["http", "https"].contains($0.lowercased()) }
        }
    }

    private static func identity(of code: SecStaticCode) -> AppIdentity? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any] else { return nil }
        let signingID = values[kSecCodeInfoIdentifier as String] as? String
        let plist = values[kSecCodeInfoPList as String] as? [String: Any]
        guard let bundleID = plist?["CFBundleIdentifier"] as? String ?? signingID, !bundleID.isEmpty else { return nil }
        return AppIdentity(bundleID: bundleID, teamID: values[kSecCodeInfoTeamIdentifier as String] as? String,
                           signingID: signingID, opensWebLinks: opensWebLinks(plist))
    }
}

/// Closes blocked apps for one user: asks them to quit (SIGTERM), then forces
/// them (SIGKILL) per `AppSweep`. Thread-safe; the service calls it from its
/// maintenance timer.
final class AppEnforcer: @unchecked Sendable {
    private let scanner: ProcessScanner
    private let signal: @Sendable (Int32, Int32) -> Int32
    private let lock = NSLock()
    private var sweep = AppSweep()
    private var known: [Int32: (launchedAt: Date, path: String, identity: AppIdentity?)] = [:]

    init(scanner: ProcessScanner, signal: @escaping @Sendable (Int32, Int32) -> Int32 = { kill($0, $1) }) {
        self.scanner = scanner
        self.signal = signal
    }

    /// Enforces `targets` now. Returns the target IDs being enforced and the
    /// actions taken (for evidence and tests).
    @discardableResult
    func enforce(_ targets: [AppTarget], now: Date = .now) -> (enforced: Set<String>, actions: [AppAction]) {
        lock.lock()
        defer { lock.unlock() }
        let blocked = targets.filter { $0 == .webBrowsers || AppBlockSafety.refusal(for: $0.bundleID) == nil }
        guard !blocked.isEmpty else {
            sweep = AppSweep()
            known = [:]
            return ([], [])
        }
        let entries = scanner.running()
        let live = Set(entries.map(\.pid))
        known = known.filter { live.contains($0.key) }
        var running: [RunningApp] = []
        for entry in entries {
            // Re-read after exec too: `sh -c 'exec Game'` keeps the shell's PID and start time.
            let path = ProcessScanner.executablePath(entry.pid)
            if known[entry.pid]?.launchedAt != entry.launchedAt || known[entry.pid]?.path != path {
                known[entry.pid] = (entry.launchedAt, path, ProcessScanner.identity(of: entry.pid))
            }
            if let identity = known[entry.pid]?.identity {
                running.append(RunningApp(pid: entry.pid, identity: identity, launchedAt: entry.launchedAt))
            }
        }
        let actions = sweep.decide(running: running, blocked: blocked, now: now, ownPID: getpid())
        var taken: [AppAction] = []
        for action in actions {
            let (pid, signalNumber): (Int32, Int32) = switch action {
            case .askToQuit(let pid, _): (pid, SIGTERM)
            case .forceQuit(let pid, _): (pid, SIGKILL)
            }
            // The PID must still be the same process (no reuse since the scan).
            guard let launched = known[pid]?.launchedAt,
                  ProcessScanner.entry(pid, owner: scanner.ownerUID)?.launchedAt == launched else { continue }
            if signal(pid, signalNumber) == 0 { taken.append(action) }
        }
        return (Set(blocked.map(\.id)), taken)
    }
}

// MARK: Choosing an app to block

extension AppTarget {
    enum ChoiceProblem: Error, Equatable {
        case unreadable, essential, browser, shield

        var message: String {
            switch self {
            case .unreadable: "Shield couldn't read that app's signature, so it can't be blocked."
            case .essential: "That app is part of the Mac (or needed to fix problems), so it can't be blocked."
            case .browser: "Web browsers can't be blocked here. Block the websites instead."
            case .shield: "Shield can't block itself."
            }
        }
    }

    /// The app at `url` as a block target, from its own code signature.
    static func chosen(at url: URL) -> Result<AppTarget, ChoiceProblem> {
        guard let identity = ProcessScanner.identity(ofBundleAt: url) else { return .failure(.unreadable) }
        switch AppBlockSafety.refusal(for: identity.bundleID) {
        case .essential?: return .failure(.essential)
        case .browser?: return .failure(.browser)
        case .shield?: return .failure(.shield)
        case nil: break
        }
        let info = Bundle(url: url)?.localizedInfoDictionary ?? Bundle(url: url)?.infoDictionary
        let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let target = AppTarget(displayName: String(name.prefix(160)), bundleID: identity.bundleID,
                               teamID: identity.teamID)
        return PolicyValidation.validApp(target) ? .success(target) : .failure(.unreadable)
    }
}
