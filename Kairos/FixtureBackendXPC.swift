import Foundation
import CryptoKit
import Darwin
import Security

// The anonymous listener supports unit tests. The named listener is used only
// by the disposable, user-owned development LaunchAgent in CI.
@objc protocol FixtureBackendXPCWire {
    func submit(_ request: NSData, reply: @escaping (NSData?, NSString?) -> Void)
    func snapshot(reply: @escaping (NSData?, NSString?) -> Void)
    func tick(reply: @escaping (NSData?, NSString?) -> Void)
    func recover(reply: @escaping (NSData?, NSString?) -> Void)
    // Location evidence from the signed app (conditional rules). The service
    // judges it; the reply is a BackendAcknowledgment, `unchanged` when the
    // effective blocks stayed the same.
    func reportPresence(_ report: NSData, reply: @escaping (NSData?, NSString?) -> Void)
    // A poll from an app that already holds the lists of `known` (a
    // SnapshotKnown). The reply is a FixtureSnapshotReply: only the fresh
    // evidence while nothing changed, otherwise the full envelope.
    func snapshotUpdate(_ known: NSData, reply: @escaping (NSData?, NSString?) -> Void)
}

struct FixtureSnapshotEnvelope: Codable {
    let generation: UInt64
    let restrictions: [DomainRestriction]
    let schedules: [DailySchedule]
    let pendingReleases: [PendingPolicyRelease]
    let authority: AuthorityState
    let enforcement: EnforcementSnapshot
    let enforcementSource: EnforcementSource
    let receipt: BackendReceipt
    let nextTransition: Date?
    var timeZoneIdentifier: String? = nil
    var serviceGaps: [ServiceGap]? = nil
    var conditions: ConditionalPolicy? = nil
    /// What this service understands beyond the original commands. An older
    /// service sends nothing, so the app hides what it can't handle.
    var features: [String]? = nil
    /// When the service last confirmed its committed state (its liveness;
    /// the authority itself is re-committed only every few minutes).
    var verifiedAt: Date? = nil
    /// Identifies `enforcement.blockedDomains`, so a later poll can skip it.
    var blockedDigest: String? = nil
    /// The permanent-block removal wait and never-removable list (1.1).
    var permanentRemoval: PermanentRemovalPolicy? = nil
    /// A time zone change waiting its 24 hours (1.1).
    var scheduleZone: ScheduleZone? = nil
}

/// What the app already holds, sent with a poll.
struct SnapshotKnown: Codable {
    let generation: UInt64
    let blockedDigest: String
}

/// The live parts of a snapshot, sent instead of the full envelope while the
/// committed generation and the observed blocked set are what the app holds.
struct FixtureSnapshotUpdate: Codable {
    let generation: UInt64
    let receipt: BackendReceipt
    let nextTransition: Date?
    let observedAt: Date
    let managedSectionPresent: Bool
    let resolution: ResolverObservation?
    let blockedApps: Set<String>?
    let blockedDigest: String
    let verifiedAt: Date
    var serviceGaps: [ServiceGap]? = nil
}

struct FixtureSnapshotReply: Codable {
    var full: FixtureSnapshotEnvelope? = nil
    var update: FixtureSnapshotUpdate? = nil
}

/// The digest of an observed blocked set, recomputed only when the set changes.
final class BlockedSetDigest: @unchecked Sendable {
    private let lock = NSLock()
    private var last: (domains: Set<String>, digest: String)?

    func digest(_ domains: Set<String>) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let last, last.domains == domains { return last.digest }
        var hasher = SHA256()
        for domain in domains.sorted() { hasher.update(data: Data((domain + "\n").utf8)) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        last = (domains, digest)
        return digest
    }
}

protocol FixtureExternalEnforcer: Sendable {
    var source: EnforcementSource { get }
    func reconcile(_ snapshot: BackendSnapshot) throws -> EnforcementSnapshot
    /// Called when maintenance can't verify the state: keep enforcing as much
    /// as was last committed, never less (fail closed).
    func enforceWithoutVerifiedState()
    /// Whether this enforcer also writes the browser admin policy.
    var managesBrowserPolicy: Bool { get }
}

extension FixtureExternalEnforcer {
    var source: EnforcementSource { .disposableSystemHosts }
    func enforceWithoutVerifiedState() {}
    var managesBrowserPolicy: Bool { false }
}

enum FixturePeerPolicy {
    case denyAll
    case currentProcessForTests
    case signedCode(requirement: String, allowedUID: uid_t)

    var signingRequirement: String? {
        if case .signedCode(let requirement, _) = self { return requirement }
        return nil
    }

    func authorizes(_ connection: NSXPCConnection) -> Bool {
        switch self {
        case .denyAll: return false
        case .currentProcessForTests:
            return connection.processIdentifier == getpid() &&
                connection.effectiveUserIdentifier == geteuid()
        case .signedCode(_, let allowedUID):
            // UID scopes the session. Before resume, the delegate installs the
            // native per-message signing requirement; no PID lookup or mutable
            // executable path participates in authentication.
            return connection.effectiveUserIdentifier == allowedUID
        }
    }
}

// Validate syntax before calling Foundation's API (which raises an exception
// for malformed requirements). Requirements come from the installed launchd
// configuration, never from an incoming policy request.
func validateXPCSigningRequirement(_ text: String) throws {
    var requirement: SecRequirement?
    guard !text.isEmpty, text.count <= 4_096,
          SecRequirementCreateWithString(text as CFString, SecCSFlags(), &requirement) == errSecSuccess,
          requirement != nil else {
        throw FixtureBackendError.invalidRequest("The XPC signing requirement is missing or malformed.")
    }
}

final class FixtureBackendXPCService: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let backend: FixtureBackend
    private let peerPolicy: FixturePeerPolicy
    private let externalEnforcer: (any FixtureExternalEnforcer)?
    private let operationLock = NSLock()
    private let calendar: Calendar
    private let backgroundTransitions: Bool
    private var maintenanceTimer: DispatchSourceTimer?
    private var lastMaintenanceError: String?
    private var gapMonitor: ServiceGapMonitor?
    private let presenceSession: PresenceSession
    private let cache = MaintenanceCache()
    private let digests = BlockedSetDigest()

    init(backend: FixtureBackend, peerPolicy: FixturePeerPolicy = .denyAll,
         machServiceName: String? = nil,
         externalEnforcer: (any FixtureExternalEnforcer)? = nil,
         backgroundTransitions: Bool = false, calendar: Calendar = .current,
         presenceSession: PresenceSession = PresenceSession()) throws {
        self.backend = backend
        self.presenceSession = presenceSession
        self.calendar = calendar
        self.peerPolicy = peerPolicy
        self.externalEnforcer = externalEnforcer
        self.backgroundTransitions = backgroundTransitions
        self.listener = machServiceName.map(NSXPCListener.init(machServiceName:)) ?? .anonymous()
        super.init()
        if let requirement = peerPolicy.signingRequirement {
            try validateXPCSigningRequirement(requirement)
        }
        listener.delegate = self
    }

    var endpoint: NSXPCListenerEndpoint { listener.endpoint }
    func resume() {
        listener.resume()
        guard backgroundTransitions else { return }
        operationLock.lock()
        let monitor = ServiceGapMonitor(backend: backend)
        monitor.start()
        gapMonitor = monitor
        operationLock.unlock()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.kairos.fixture-transitions"))
        timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in self?.maintainAuthority() }
        maintenanceTimer = timer
        timer.resume()
    }
    func invalidate() {
        maintenanceTimer?.cancel()
        maintenanceTimer = nil
        listener.invalidate()
    }

    private func maintainAuthority() {
        operationLock.lock()
        defer { operationLock.unlock() }
        gapMonitor?.beat()
        guard FileManager.default.fileExists(atPath: backend.paths.document.path) ||
              FileManager.default.fileExists(atPath: backend.paths.journal.path) else { return }
        do {
            let now = Date.now
            // Nothing written and nothing due: enforce the last verified
            // snapshot instead of reloading and re-checking all state (R4).
            if let reused = cache.reusableSnapshot(now: now, stamp: backend.stateStamp()),
               !backend.observesZoneChange(in: reused, calendar: calendar, now: now) {
                let evidence = try externalEnforcer?.reconcile(reused) ?? reused.enforcement
                cache.recordEvidence(evidence, at: now)
                lastMaintenanceError = nil
                return
            }
            cache.invalidate()
            if FileManager.default.fileExists(atPath: backend.paths.journal.path) {
                _ = try backend.recover(now: now, calendar: calendar)
            } else {
                _ = try backend.tick(now: now, calendar: calendar)
            }
            let before = backend.stateStamp()
            let snapshot = try backend.snapshot(now: now, calendar: calendar)
            let evidence = try externalEnforcer?.reconcile(snapshot) ?? snapshot.enforcement
            // Only a snapshot whose files didn't change while it was read is reused.
            if backend.stateStamp() == before { cache.store(snapshot, evidence: evidence, stamp: before, at: now) }
            lastMaintenanceError = nil
        } catch {
            cache.invalidate()
            externalEnforcer?.enforceWithoutVerifiedState()
            let detail = error.localizedDescription
            if detail != lastMaintenanceError {
                fputs("fixture-xpc: background reconciliation paused: \(detail)\n", stderr)
                lastMaintenanceError = detail
            }
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard peerPolicy.authorizes(connection) else { return false }
        if let requirement = peerPolicy.signingRequirement {
            connection.setCodeSigningRequirement(requirement)
        }
        connection.exportedInterface = NSXPCInterface(with: FixtureBackendXPCWire.self)
        connection.exportedObject = Handler(backend: backend, externalEnforcer: externalEnforcer,
                                            operationLock: operationLock, calendar: calendar,
                                            presenceSession: presenceSession,
                                            cache: backgroundTransitions ? cache : nil, digests: digests)
        connection.resume()
        return true
    }

    private final class Handler: NSObject, FixtureBackendXPCWire {
        let backend: FixtureBackend
        let externalEnforcer: (any FixtureExternalEnforcer)?
        let operationLock: NSLock
        let calendar: Calendar
        let presenceSession: PresenceSession
        /// The maintenance pass's cache, when a maintenance timer runs.
        let cache: MaintenanceCache?
        let digests: BlockedSetDigest
        init(backend: FixtureBackend, externalEnforcer: (any FixtureExternalEnforcer)?,
             operationLock: NSLock, calendar: Calendar, presenceSession: PresenceSession,
             cache: MaintenanceCache? = nil, digests: BlockedSetDigest = BlockedSetDigest()) {
            self.digests = digests
            self.backend = backend
            self.externalEnforcer = externalEnforcer
            self.operationLock = operationLock
            self.calendar = calendar
            self.presenceSession = presenceSession
            self.cache = cache
        }

        private func reconciledSnapshot() throws -> (BackendSnapshot, EnforcementSnapshot) {
            // Anything that may have changed state: the next pass checks in full.
            cache?.invalidate()
            let snapshot = try backend.snapshot(now: .now, calendar: calendar)
            let evidence = try externalEnforcer?.reconcile(snapshot) ?? snapshot.enforcement
            return (snapshot, evidence)
        }

        /// A poll from the app: the latest maintenance pass's result when it is
        /// recent and nothing changed since, otherwise a full check.
        private func currentSnapshot() throws -> (BackendSnapshot, EnforcementSnapshot, verifiedAt: Date) {
            if let cache, let latest = cache.latest(now: .now, stamp: backend.stateStamp()) { return latest }
            let now = Date.now
            let snapshot = try backend.snapshot(now: now, calendar: calendar)
            let evidence = try externalEnforcer?.reconcile(snapshot) ?? snapshot.enforcement
            return (snapshot, evidence, now)
        }

        private func envelope(_ value: BackendSnapshot, _ enforcement: EnforcementSnapshot,
                              verifiedAt: Date) -> FixtureSnapshotEnvelope {
            FixtureSnapshotEnvelope(generation: value.generation,
                restrictions: value.committedRestrictions, schedules: value.committedSchedules,
                pendingReleases: value.pendingReleases, authority: value.authority,
                enforcement: enforcement,
                enforcementSource: externalEnforcer?.source ?? .fixtureHosts,
                receipt: value.receipt,
                nextTransition: value.nextTransition,
                timeZoneIdentifier: value.timeZoneIdentifier ?? calendar.timeZone.identifier,
                serviceGaps: backend.serviceGaps(), conditions: value.conditions,
                features: [BackendSnapshot.placesFeature, BackendSnapshot.goDaysFeature,
                           BackendSnapshot.permanentRemovalFeature] +
                    (externalEnforcer?.managesBrowserPolicy == true ? [BackendSnapshot.browserPolicyFeature] : []),
                verifiedAt: verifiedAt, blockedDigest: digests.digest(enforcement.blockedDomains),
                permanentRemoval: value.permanentRemoval, scheduleZone: value.scheduleZone)
        }

        func submit(_ request: NSData, reply: @escaping (NSData?, NSString?) -> Void) {
            operationLock.lock()
            defer { operationLock.unlock() }
            do {
                guard request.length > 0, request.length <= StateFileLimits.maximumBytes else {
                    throw FixtureBackendError.invalidRequest("XPC request is empty or too large.")
                }
                let decoded = try JSONDecoder().decode(BackendRequest.self, from: request as Data)
                let ack = try backend.apply(decoded, now: .now, calendar: calendar)
                _ = try reconciledSnapshot()
                reply(try JSONEncoder().encode(ack) as NSData, nil)
            } catch { reply(nil, error.localizedDescription as NSString) }
        }

        func snapshot(reply: @escaping (NSData?, NSString?) -> Void) {
            operationLock.lock()
            defer { operationLock.unlock() }
            do {
                let (value, enforcement, verifiedAt) = try currentSnapshot()
                reply(try JSONEncoder().encode(envelope(value, enforcement, verifiedAt: verifiedAt)) as NSData, nil)
            } catch { reply(nil, error.localizedDescription as NSString) }
        }

        func snapshotUpdate(_ known: NSData, reply: @escaping (NSData?, NSString?) -> Void) {
            operationLock.lock()
            defer { operationLock.unlock() }
            do {
                guard known.length > 0, known.length <= 4_096 else {
                    throw FixtureBackendError.invalidRequest("Snapshot poll is empty or oversized.")
                }
                let held = try JSONDecoder().decode(SnapshotKnown.self, from: known as Data)
                let (value, enforcement, verifiedAt) = try currentSnapshot()
                let digest = digests.digest(enforcement.blockedDomains)
                var answer = FixtureSnapshotReply()
                if held.generation == value.generation && held.blockedDigest == digest {
                    answer.update = FixtureSnapshotUpdate(generation: value.generation, receipt: value.receipt,
                        nextTransition: value.nextTransition, observedAt: enforcement.observedAt,
                        managedSectionPresent: enforcement.managedSectionPresent,
                        resolution: enforcement.resolution, blockedApps: enforcement.blockedApps,
                        blockedDigest: digest, verifiedAt: verifiedAt, serviceGaps: backend.serviceGaps())
                } else {
                    answer.full = envelope(value, enforcement, verifiedAt: verifiedAt)
                }
                reply(try JSONEncoder().encode(answer) as NSData, nil)
            } catch { reply(nil, error.localizedDescription as NSString) }
        }

        func tick(reply: @escaping (NSData?, NSString?) -> Void) {
            operationLock.lock()
            defer { operationLock.unlock() }
            do {
                // The maintenance pass ticks every 2 s; when nothing changed or
                // came due since it last checked, its result is the answer.
                if let cache, let (snapshot, _, _) = cache.latest(now: .now, stamp: backend.stateStamp()) {
                    let ack = BackendAcknowledgment(version: 1, status: .unchanged, receipt: snapshot.receipt,
                                                    nextTransition: snapshot.nextTransition)
                    reply(try JSONEncoder().encode(ack) as NSData, nil)
                    return
                }
                let ack = try backend.tick(now: .now, calendar: calendar)
                _ = try reconciledSnapshot()
                reply(try JSONEncoder().encode(ack) as NSData, nil)
            }
            catch { reply(nil, error.localizedDescription as NSString) }
        }

        func reportPresence(_ report: NSData, reply: @escaping (NSData?, NSString?) -> Void) {
            operationLock.lock()
            defer { operationLock.unlock() }
            do {
                guard report.length > 0, report.length <= 65_536 else {
                    throw FixtureBackendError.invalidRequest("Presence report is empty or exceeds 64 KiB.")
                }
                let decoded = try JSONDecoder().decode(PresenceReport.self, from: report as Data)
                let ack = try backend.reportPresence(decoded, session: presenceSession, now: .now, calendar: calendar)
                if ack.status != .unchanged { _ = try reconciledSnapshot() }
                reply(try JSONEncoder().encode(ack) as NSData, nil)
            } catch { reply(nil, error.localizedDescription as NSString) }
        }

        func recover(reply: @escaping (NSData?, NSString?) -> Void) {
            operationLock.lock()
            defer { operationLock.unlock() }
            do {
                let ack = try backend.recover(now: .now, calendar: calendar)
                _ = try reconciledSnapshot()
                reply(try JSONEncoder().encode(ack) as NSData, nil)
            }
            catch { reply(nil, error.localizedDescription as NSString) }
        }
    }
}

/// The installed service's last full maintenance pass (R4). A pass
/// reuses its verified snapshot only while none of the state files was
/// written, before the snapshot's next transition, and for at most
/// `fullCheckInterval`; then it reloads and re-verifies everything. Callers
/// hold the service's operation lock.
final class MaintenanceCache: @unchecked Sendable {
    static let fullCheckInterval: TimeInterval = 30
    /// An app poll is answered from a pass at most this old.
    static let pollAnswerAge: TimeInterval = 3

    private var snapshot: BackendSnapshot?
    private var stamp: [FileStamp?] = []
    private var checkedAt: Date = .distantPast
    private var evidence: EnforcementSnapshot?
    private var evidenceAt: Date = .distantPast

    func store(_ snapshot: BackendSnapshot, evidence: EnforcementSnapshot, stamp: [FileStamp?], at now: Date) {
        self.snapshot = snapshot; self.stamp = stamp; checkedAt = now
        self.evidence = evidence; evidenceAt = now
    }

    func recordEvidence(_ evidence: EnforcementSnapshot, at now: Date) {
        self.evidence = evidence; evidenceAt = now
    }

    func invalidate() { snapshot = nil; evidence = nil; stamp = [] }

    func reusableSnapshot(now: Date, stamp current: [FileStamp?]) -> BackendSnapshot? {
        // Also due: the next transition, and the once-a-minute re-commit.
        guard let snapshot, current == stamp, now >= checkedAt,
              now.timeIntervalSince(checkedAt) < Self.fullCheckInterval,
              snapshot.nextTransition.map({ now < $0 }) ?? true,
              now.timeIntervalSince(snapshot.authority.generatedAt) < FixtureBackend.authorityRefreshInterval
        else { return nil }
        return snapshot
    }

    /// The latest pass's result and when that pass confirmed it.
    func latest(now: Date, stamp current: [FileStamp?]) -> (BackendSnapshot, EnforcementSnapshot, verifiedAt: Date)? {
        guard let snapshot = reusableSnapshot(now: now, stamp: current), let evidence, now >= evidenceAt,
              now.timeIntervalSince(evidenceAt) <= Self.pollAnswerAge else { return nil }
        return (snapshot, evidence, evidenceAt)
    }
}
