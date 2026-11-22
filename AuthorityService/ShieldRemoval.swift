import Darwin
import Foundation

/// Shield 1.1: removes Shield from this Mac once a requested removal is due
/// (`PermanentRemovalPolicy.uninstallIsDue`). Blocks come off first; if any
/// step that lifts a block fails, nothing else is removed and the next pass
/// tries again with every block still enforced. The user's own files (the
/// Video Library and app settings in their home folder) are left alone.
enum ShieldRemoval {
    static let receipt = "/Library/Logs/Shield Removal.txt"

    static func isDue(_ snapshot: BackendSnapshot, at now: Date) -> Bool {
        snapshot.permanentRemoval?.uninstallIsDue(restrictions: snapshot.committedRestrictions,
                                                  pending: snapshot.pendingReleases, at: now) == true
    }

    /// Never returns once the service is unloaded.
    static func run(hosts: InstalledHostsEnforcer, browserPolicy: InstalledBrowserPolicyWriter, now: Date) throws {
        try AuthorityInstallation.requireRoot()
        var log = ["Shield removal requested in the app ran at \(ISO8601DateFormatter().string(from: now))."]
        func note(_ line: String) {
            log.append(line)
            try? (log.joined(separator: "\n") + "\n").write(toFile: receipt, atomically: true, encoding: .utf8)
        }
        note("Removing Shield's website blocks.")
        try hosts.removeManagedSection()
        note("Removed Shield's section of /etc/hosts. Every other line was kept.")
        let withdrawn = try browserPolicy.withdraw()
        note("Removed \(withdrawn.count) browser settings files Shield had written.")

        // Blocks are off. From here a failure leaves files behind but no block.
        let fileManager = FileManager.default
        let launchDaemon = AuthorityInstallation.launchDaemon
        for (path, what) in [(launchDaemon, "the background service's launch file"),
                             (AuthorityInstallation.executable, "the background service"),
                             (AuthorityInstallation.root.path, "Shield's rules and keys")] {
            do {
                if fileManager.fileExists(atPath: path) { try fileManager.removeItem(atPath: path) }
                note("Removed \(what) (\(path)).")
            } catch {
                note("Could not remove \(path): \(error.localizedDescription)")
            }
        }
        let app = AuthorityInstallation.publicApp
        if fileManager.fileExists(atPath: app) {
            if AuthorityInstallation.isForeignApp(at: app) {
                note("Left \(app) in place: it isn't this Shield.")
            } else {
                do { try fileManager.removeItem(atPath: app); note("Removed \(app).") }
                catch { note("Could not remove \(app): \(error.localizedDescription)") }
            }
        }
        _ = launch("/usr/sbin/pkgutil", ["--forget", "com.kairos.Shield"])
        note("Your Video Library and settings in your home folder were not touched. Shield is removed.")
        // Unloads this service, which ends this process.
        _ = launch("/bin/launchctl", ["bootout", "system/\(AuthorityInstallation.name)"])
        exit(0)
    }

    private static func launch(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
