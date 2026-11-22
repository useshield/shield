import Darwin
import Foundation

// The installed service's enforcer: websites through the managed hosts
// section, then apps through `AppEnforcer` for the one configured user, then
// the browser layers (hardening): managed browser policy and the
// launch guard, fed the SAME effective blocked set as the hosts section (browser
// policy only the part that fits Chrome's 1,000-entry list, whole rules first).
// Apps and browser layers are enforced even when the hosts step fails, and
// when the service can't verify its state, every committed app is closed and
// browsers keep the last list, then (after 30 s) get every committed site.
final class InstalledEnforcer: FixtureExternalEnforcer, @unchecked Sendable {
    private let hosts: InstalledHostsEnforcer
    private let apps: AppEnforcer
    private let browserPolicy: InstalledBrowserPolicyWriter
    private let launchGuard: InstalledBrowserLaunchGuard
    private let browserEvidence: BrowserLayersEvidenceStore
    private let lock = NSLock()
    private var committedApps: [AppTarget] = []
    /// Each rule's websites, for the browser policy (Chrome caps its list).
    private var lastBlockedGroups: [Set<String>] = []
    private var committedGroups: [Set<String>] = []
    /// The browser-policy share of the last rule groups, computed once per change.
    private var fitted: (groups: [Set<String>], domains: Set<String>, leftOut: Int)?
    /// What each pass derives from a snapshot, kept per committed generation:
    /// the sets are then the same values (same storage) pass after pass, so
    /// comparing them downstream costs nothing however long the lists are.
    private var derived: (generation: UInt64, generatedAt: Date, value: Derived)?
    private struct Derived {
        let effective: Set<AppTarget>
        let committed: Set<AppTarget>
        let blockedGroups: [Set<String>]
        let blockedHosts: Set<String>
        let committedDomainGroups: [Set<String>]
        /// Shield 1.1: browser settings exist only while some block names a site.
        var hasWebsiteBlocks = true
    }

    private func derive(_ snapshot: BackendSnapshot) -> Derived {
        if let derived = lock.withLock({ derived }), derived.generation == snapshot.generation,
           derived.generatedAt == snapshot.authority.generatedAt {
            return derived.value
        }
        let blockedGroups = snapshot.authority.effectiveRestrictions.map(\.domains)
        let value = Derived(
            effective: snapshot.authority.effectiveRestrictions.reduce(into: Set<AppTarget>()) { $0.formUnion($1.apps) },
            // A Go day you already reached stays lifted even when state can't be verified.
            committed: snapshot.committedRestrictions.filter { $0.goDay?.arrivedAt == nil }
                .reduce(into: Set<AppTarget>()) { $0.formUnion($1.apps) }
                .union(snapshot.committedSchedules.reduce(into: Set<AppTarget>()) { $0.formUnion($1.apps) }),
            blockedGroups: blockedGroups,
            blockedHosts: blockedGroups.reduce(into: Set<String>()) { $0.formUnion($1) },
            committedDomainGroups: snapshot.committedRestrictions.filter { $0.goDay?.arrivedAt == nil }.map(\.domains)
                + snapshot.committedSchedules.map(\.domains),
            hasWebsiteBlocks: blockedGroups.contains { !$0.isEmpty } ||
                snapshot.committedRestrictions.contains { !$0.domains.isEmpty } ||
                snapshot.committedSchedules.contains { !$0.domains.isEmpty } ||
                snapshot.conditions?.rules.contains { !$0.domains.isEmpty } == true)
        lock.withLock { derived = (snapshot.generation, snapshot.authority.generatedAt, value) }
        return value
    }
    private var unverifiedSince: Date?
    private var hasVerified = false
    /// How long state must stay unverifiable before browsers get every
    /// committed site (a single failed pass doesn't flip them back and forth).
    static let browserFailClosedAfter: TimeInterval = 30
    private var browserLayersWithdrawn = false
    private var hasWebsiteBlocks = true

    init(hosts: InstalledHostsEnforcer, ownerUID: uid_t) {
        self.hosts = hosts
        self.apps = AppEnforcer(scanner: ProcessScanner(ownerUID: ownerUID))
        self.browserPolicy = .installed(ownerUID: ownerUID)
        self.launchGuard = InstalledBrowserLaunchGuard(scanner: ProcessScanner(ownerUID: ownerUID))
        self.browserEvidence = BrowserLayersEvidenceStore(
            path: "/Library/Application Support/ShieldAuthority/browser-layers.json")
    }

    var source: EnforcementSource { hosts.source }
    #if SHIELD_BROWSER_LAYERS_OFF
    var managesBrowserPolicy: Bool { false }
    #else
    var managesBrowserPolicy: Bool { true }
    #endif

    func reconcile(_ snapshot: BackendSnapshot) throws -> EnforcementSnapshot {
        // A removal the user asked for, now due: it ends this process. If it
        // fails partway, every block below is enforced again this pass.
        if ShieldRemoval.isDue(snapshot, at: .now) {
            do { try ShieldRemoval.run(hosts: hosts, browserPolicy: browserPolicy, now: .now) }
            catch { fputs("shield-authority: removal failed, still enforcing: \(error.localizedDescription)\n", stderr) }
        }
        let derived = derive(snapshot)
        let effective = derived.effective
        let committed = derived.committed
        let blockedGroups = derived.blockedGroups
        let blockedHosts = derived.blockedHosts
        let committedDomainGroups = derived.committedDomainGroups
        lock.withLock {
            committedApps = Array(committed); lastBlockedGroups = blockedGroups
            committedGroups = committedDomainGroups + blockedGroups; unverifiedSince = nil; hasVerified = true
            hasWebsiteBlocks = derived.hasWebsiteBlocks
        }
        let enforced = apps.enforce(Array(effective)).enforced
        let hostsResult = Result { try hosts.reconcile(snapshot) }
        enforceBrowsers(blockedHosts, groups: blockedGroups)
        var evidence = try hostsResult.get()
        evidence.blockedApps = enforced
        return evidence
    }

    func enforceWithoutVerifiedState() {
        enforceWithoutVerifiedState(now: .now)
    }

    func enforceWithoutVerifiedState(now: Date) {
        apps.enforce(lock.withLock { committedApps })
        #if SHIELD_BROWSER_LAYERS_OFF
        return
        #endif
        // Briefly: the last verified list stays. Past `browserFailClosedAfter`,
        // browsers get every committed site (schedules and place blocks
        // included), as apps already do, so a block that should start while
        // state is unverifiable still reaches them. Hosts keeps its last list.
        let (groups, verifiedOnce): ([Set<String>], Bool) = lock.withLock {
            let since = unverifiedSince ?? now
            unverifiedSince = since
            let failClosed = now.timeIntervalSince(since) >= Self.browserFailClosedAfter
            return (failClosed ? committedGroups : lastBlockedGroups, hasVerified)
        }
        let hosts = groups.reduce(into: Set<String>()) { $0.formUnion($1) }
        // Never verified since the service started: nothing is known, so the
        // policy files on disk (the last list) are left exactly as they are.
        guard verifiedOnce else {
            launchGuard.enforce(blockedHosts: hosts)
            return
        }
        // Verified with no website block: nothing for browsers, as above.
        guard lock.withLock({ hasWebsiteBlocks }) else { return }
        let share = browserShare(groups)
        let policy = browserPolicy.reconcile(domains: share.domains)
        let closed = launchGuard.enforce(blockedHosts: hosts)
        browserEvidence.record(policy: policy, closed: closed, hostsOnlySites: share.leftOut)
    }

    /// What browser policy carries for these rule groups (see
    /// `BrowserManagedPolicy.fitting`), recomputed only when they change.
    private func browserShare(_ groups: [Set<String>]) -> (domains: Set<String>, leftOut: Int) {
        if let fitted = lock.withLock({ fitted }), fitted.groups == groups { return (fitted.domains, fitted.leftOut) }
        let result = BrowserManagedPolicy.fitting(groups)
        lock.withLock { fitted = (groups, result.domains, result.leftOut) }
        return result
    }

    private func enforceBrowsers(_ blockedHosts: Set<String>, groups: [Set<String>]) {
        #if SHIELD_BROWSER_LAYERS_OFF
        // The rollback build: never leave the last block list behind.
        if lock.withLock({ !browserLayersWithdrawn }) {
            _ = try? browserPolicy.withdraw()
            lock.withLock { browserLayersWithdrawn = true }
        }
        return
        #endif
        // Shield 1.1 (less invasive): with no website block at all, Shield
        // leaves browsers alone and takes back its settings once.
        guard lock.withLock({ hasWebsiteBlocks }) else {
            if lock.withLock({ !browserLayersWithdrawn }) {
                _ = try? browserPolicy.withdraw()
                lock.withLock { browserLayersWithdrawn = true }
            }
            return
        }
        lock.withLock { browserLayersWithdrawn = false }
        // Hosts and the launch guard get every site; browser policy gets
        // what fits Chrome's list (see `browserShare`).
        let share = browserShare(groups)
        let policy = browserPolicy.reconcile(domains: share.domains)
        let closed = launchGuard.enforce(blockedHosts: blockedHosts)
        browserEvidence.record(policy: policy, closed: closed, hostsOnlySites: share.leftOut)
    }
}
