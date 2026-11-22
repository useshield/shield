import Foundation
import Darwin

// Built separately with SHIELD_AUTHORITY_SERVICE. No development environment
// flags can redirect this service or disable its signing requirement.
do {
    try AuthorityInstallation.requireRoot()
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else { throw FixtureBackendError.invalidRequest("Expected preflight, initialize, verify, or serve.") }
    if arguments[1] == "resolve", arguments.count >= 4,
       let generation = UInt64(arguments[2]), let total = Int(arguments[3]) {
        let observation = try ResolverProbe.run(generation: generation, total: total, domains: Array(arguments.dropFirst(4)))
        let bytes = try JSONEncoder().encode(observation)
        guard bytes.count <= 16_384 else { throw FixtureBackendError.invalidRequest("Resolver sample too large.") }
        FileHandle.standardOutput.write(bytes)
        exit(0)
    }
    if arguments[1] == "preflight", arguments.count == 3 {
        try AuthorityInstallation.preflight(candidate: URL(fileURLWithPath: arguments[2]))
        print("Installation preflight passed; no files changed.")
        exit(0)
    }
    guard arguments.count == 2 else { throw FixtureBackendError.invalidRequest("Unexpected service arguments.") }
    let (configuration, backend) = try AuthorityInstallation.loadInstalled()
    let calendar = configuration.calendar
    switch arguments[1] {
    case "initialize":
        if FileManager.default.fileExists(atPath: backend.paths.journal.path) {
            _ = try backend.recover(now: .now, calendar: calendar)
        } else if FileManager.default.fileExists(atPath: backend.paths.document.path) {
            _ = try backend.snapshot(now: .now, calendar: calendar)
        } else {
            try AuthorityInstallation.requireNoLegacyInstallation(uid: configuration.allowedUID)
            let backup = AuthorityInstallation.root.appendingPathComponent("hosts-before-first-install")
            guard !FileManager.default.fileExists(atPath: backup.path) else {
                throw FixtureBackendError.uncertain("An interrupted bootstrap requires inspection.")
            }
            try AtomicFixtureStore(allowedRoot: AuthorityInstallation.root)
                .write(Data(InstalledHostsEnforcer.readSystemHosts().utf8), to: backup)
            try backend.initializeEmptyAuthority(now: .now, calendar: calendar)
        }
        try AuthorityInstallation.recordRelease(configuration.releaseSequence)
        print("Authority initialized or verified; system hosts were not changed.")
    case "verify":
        let receipt = try backend.snapshot(now: .now, calendar: calendar).receipt
        print("Authority generation \(receipt.payload.generation), release \(configuration.releaseSequence), source \(configuration.sourceCommit)")
    case "withdraw-browser-policy":
        // Rollback only: a release without the browser layers must not leave
        // the last block list behind. Removes only Shield's unchanged files.
        let removed = try InstalledBrowserPolicyWriter.installed(ownerUID: configuration.allowedUID).withdraw()
        print("Removed \(removed.count) Shield browser policy files; nothing else changed.")
    case "inspect":
        let snapshot = try backend.snapshot(now: .now, calendar: calendar)
        let envelope = FixtureSnapshotEnvelope(generation: snapshot.generation,
            restrictions: snapshot.committedRestrictions, schedules: snapshot.committedSchedules,
            pendingReleases: snapshot.pendingReleases, authority: snapshot.authority,
            enforcement: snapshot.enforcement, enforcementSource: .fixtureHosts,
            receipt: snapshot.receipt, nextTransition: snapshot.nextTransition,
            timeZoneIdentifier: configuration.timeZoneIdentifier,
            serviceGaps: backend.serviceGaps())
        FileHandle.standardOutput.write(try JSONEncoder().encode(envelope))
    case "serve":
        // Schedules follow this Mac's time zone (at once when macOS set it from
        // Location, after 24 hours when it was changed by hand).
        var backend = backend
        backend.observeZone = { SystemTimeZone.observe() }
        // Before anything is rendered: a previous run's location is never trusted.
        try backend.forgetPresence(now: .now, calendar: calendar)
        let enforcer = InstalledEnforcer(hosts: InstalledHostsEnforcer(), ownerUID: configuration.allowedUID)
        // A failure here used to exit, and launchd restarted the service every
        // 10 s with nothing enforced and no app connection in between. Now it
        // enforces what it can (fail closed) and starts serving; the 2 s
        // maintenance pass keeps retrying the full reconcile.
        do {
            _ = try backend.tick(now: .now, calendar: calendar)
            _ = try enforcer.reconcile(backend.snapshot(now: .now, calendar: calendar))
        } catch {
            fputs("shield-authority: start-up reconcile failed, enforcing without verified state: \(error.localizedDescription)\n", stderr)
            enforcer.enforceWithoutVerifiedState()
        }
        let service = try FixtureBackendXPCService(backend: backend,
            peerPolicy: .signedCode(requirement: configuration.clientRequirement, allowedUID: configuration.allowedUID),
            machServiceName: AuthorityInstallation.name,
            externalEnforcer: enforcer, backgroundTransitions: true, calendar: calendar)
        service.resume()
        RunLoop.current.run()
        withExtendedLifetime(service) {}
    default: throw FixtureBackendError.invalidRequest("Unknown installed-service command.")
    }
} catch {
    fputs("shield-authority: \(error.localizedDescription)\n", stderr)
    exit(1)
}
