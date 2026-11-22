import CryptoKit
import Darwin
import Foundation

// This protocol and engine are for isolated fixture execution. Production requests
// require an audit-token-checked XPC boundary and a root-owned signing key.
enum BackendCommandKind: String, Codable, Sendable {
    case addRestriction
    case addSchedule
    case strengthenSchedule
    case replaceScheduleAfterDelay
    case requestRelease
    case correctRecentPermanent
    case cancelPendingRelease
    // Conditional rules (docs/conditional-rules-blueprint.md). Each change is
    // classified by PlaceChangeClassifier / RuleChangeClassifier: a stronger
    // one applies at once and takes no effectiveAt; a weaker one must name an
    // effectiveAt at least 24 hours away and waits as a pending change.
    case addPlace
    case replacePlace
    case removePlace
    case addConditionalRule
    case replaceConditionalRule
    case removeConditionalRule
    // Go there today: a Go day is added with addRestriction; until it starts
    // (its 2-minute undo) it can be withdrawn at once. After that, no command
    // ends it: only arriving or its end time does.
    case withdrawGoDay
    // Shield 1.1: a permanent or "until released" block added in the last 10
    // minutes can be removed at once (a mistake, not a weakening).
    case undoNewBlock
    // Shield 1.1: how long removing a permanent block waits. Longer applies at
    // once; shorter only after the current wait has passed.
    case setPermanentRemovalWait
    // Shield 1.1: remove Shield from this Mac. It waits at least as long as
    // removing a permanent block (and until every timed block has ended);
    // keeping Shield cancels it at once. Refused while a never-removable
    // block exists.
    case requestUninstall
    case cancelUninstall

    var isConditional: Bool {
        switch self {
        case .addPlace, .replacePlace, .removePlace,
             .addConditionalRule, .replaceConditionalRule, .removeConditionalRule: true
        default: false
        }
    }
}

struct BackendCommand: Codable, Sendable {
    let kind: BackendCommandKind
    let restriction: DomainRestriction?
    let schedule: DailySchedule?
    let policyID: String?
    let effectiveAt: Date?
    var place: RulePlace? = nil
    var conditionalRule: ConditionalRule? = nil
    /// Only for `setPermanentRemovalWait`.
    var waitSeconds: TimeInterval? = nil

    /// Remove a block added in the last 10 minutes.
    static func undoNew(_ policyID: String) -> Self {
        Self(kind: .undoNewBlock, restriction: nil, schedule: nil, policyID: policyID, effectiveAt: nil)
    }

    static func setPermanentRemovalWait(_ seconds: TimeInterval) -> Self {
        Self(kind: .setPermanentRemovalWait, restriction: nil, schedule: nil, policyID: nil, effectiveAt: nil,
             waitSeconds: seconds)
    }

    static func requestUninstall(at date: Date) -> Self {
        Self(kind: .requestUninstall, restriction: nil, schedule: nil, policyID: nil, effectiveAt: date)
    }

    static let cancelUninstall = Self(kind: .cancelUninstall, restriction: nil, schedule: nil, policyID: nil,
                                      effectiveAt: nil)

    static func add(_ restriction: DomainRestriction) -> Self {
        Self(kind: .addRestriction, restriction: restriction, schedule: nil, policyID: nil, effectiveAt: nil)
    }

    static func add(_ schedule: DailySchedule) -> Self {
        Self(kind: .addSchedule, restriction: nil, schedule: schedule, policyID: nil, effectiveAt: nil)
    }

    static func strengthen(_ schedule: DailySchedule) -> Self {
        Self(kind: .strengthenSchedule, restriction: nil, schedule: schedule, policyID: nil, effectiveAt: nil)
    }

    static func replace(_ schedule: DailySchedule, at date: Date) -> Self {
        Self(kind: .replaceScheduleAfterDelay, restriction: nil, schedule: schedule,
             policyID: nil, effectiveAt: date)
    }

    static func release(_ policyID: String, at date: Date) -> Self {
        Self(kind: .requestRelease, restriction: nil, schedule: nil, policyID: policyID, effectiveAt: date)
    }

    /// Undo a mistaken New Block permanent rule (see
    /// `DomainRestriction.isCorrectablePermanent`): it is released no sooner
    /// than 24 hours later; cancelling the correction makes it permanent again.
    static func correctRecentPermanent(_ policyID: String, releaseAt date: Date) -> Self {
        Self(kind: .correctRecentPermanent, restriction: nil, schedule: nil, policyID: policyID, effectiveAt: date)
    }

    /// Withdraw a pending release or looser-hours change. The current rules
    /// stay, which is never weaker, so it applies at once.
    static func cancelPending(_ policyID: String) -> Self {
        Self(kind: .cancelPendingRelease, restriction: nil, schedule: nil, policyID: policyID, effectiveAt: nil)
    }

    static func withdrawGoDay(_ policyID: String) -> Self {
        Self(kind: .withdrawGoDay, restriction: nil, schedule: nil, policyID: policyID, effectiveAt: nil)
    }

    static func add(_ place: RulePlace) -> Self {
        Self(kind: .addPlace, restriction: nil, schedule: nil, policyID: nil, effectiveAt: nil, place: place)
    }

    /// `effectiveAt` is nil for a rename, and at least 24 hours away otherwise.
    static func replace(_ place: RulePlace, at date: Date? = nil) -> Self {
        Self(kind: .replacePlace, restriction: nil, schedule: nil, policyID: nil, effectiveAt: date, place: place)
    }

    static func removePlace(_ id: String, at date: Date) -> Self {
        Self(kind: .removePlace, restriction: nil, schedule: nil, policyID: id, effectiveAt: date)
    }

    /// A block rule applies at once (no date); an allow rule waits (a date at least 24 hours away).
    static func add(_ rule: ConditionalRule, at date: Date? = nil) -> Self {
        Self(kind: .addConditionalRule, restriction: nil, schedule: nil, policyID: nil, effectiveAt: date,
             conditionalRule: rule)
    }

    static func replace(_ rule: ConditionalRule, at date: Date? = nil) -> Self {
        Self(kind: .replaceConditionalRule, restriction: nil, schedule: nil, policyID: nil, effectiveAt: date,
             conditionalRule: rule)
    }

    static func removeRule(_ id: String, at date: Date? = nil) -> Self {
        Self(kind: .removeConditionalRule, restriction: nil, schedule: nil, policyID: id, effectiveAt: date)
    }
}

struct BackendRequest: Codable, Sendable {
    static let schemaVersion = 1
    let version: Int
    let id: UUID
    let expectedGeneration: UInt64
    let submittedAt: Date
    let commands: [BackendCommand]
}

struct PendingPolicyRelease: Codable, Equatable, Sendable {
    let policyID: String
    let effectiveAt: Date
    let replacementSchedule: DailySchedule?
    /// Set by a permanent-block correction: cancelling it makes the block
    /// permanent again instead of leaving a releasable commitment.
    let restoresPermanent: Bool?
    /// For a "place:" or "rule:" owner: what lands when due. Nil removes it.
    let replacementPlace: RulePlace?
    let replacementRule: ConditionalRule?

    init(policyID: String, effectiveAt: Date, replacementSchedule: DailySchedule? = nil,
         restoresPermanent: Bool? = nil, replacementPlace: RulePlace? = nil,
         replacementRule: ConditionalRule? = nil) {
        self.policyID = policyID
        self.effectiveAt = effectiveAt
        self.replacementSchedule = replacementSchedule
        self.restoresPermanent = restoresPermanent
        self.replacementPlace = replacementPlace
        self.replacementRule = replacementRule
    }

    /// Applies a due place or rule change. Other owners are settled elsewhere.
    func land(in conditions: inout ConditionalPolicy) {
        if policyID.hasPrefix(ConditionalPolicy.placePrefix) {
            let id = String(policyID.dropFirst(ConditionalPolicy.placePrefix.count))
            if let place = replacementPlace {
                if let index = conditions.places.firstIndex(where: { $0.id == id }) { conditions.places[index] = place }
                else { conditions.places.append(place) }
            } else {
                conditions.places.removeAll { $0.id == id }
            }
        } else if policyID.hasPrefix(ConditionalPolicy.rulePrefix) {
            let id = String(policyID.dropFirst(ConditionalPolicy.rulePrefix.count))
            if let rule = replacementRule {
                if let index = conditions.rules.firstIndex(where: { $0.id == id }) { conditions.rules[index] = rule }
                else { conditions.rules.append(rule) }
            } else {
                conditions.rules.removeAll { $0.id == id }
            }
        }
    }
}

/// Shield 1.1: removing a permanent block waits (72 hours by default). Blocks
/// that were permanent before this existed stay never-removable: they were
/// made under that promise. A document without this record predates it, so
/// every permanent block in it is locked.
struct PermanentRemovalPolicy: Codable, Equatable, Sendable {
    static let defaultWait: TimeInterval = 259_200
    static let minimumWait: TimeInterval = 86_400
    static let maximumWait: TimeInterval = 30 * 86_400
    static let undoWindow: TimeInterval = 600

    let lockedPolicyIDs: Set<String>
    let wait: TimeInterval
    let pendingWait: TimeInterval?
    let pendingWaitAt: Date?
    /// When Shield removes itself, if asked. The real time is `uninstallDue`:
    /// never before a timed block ends or a pending change lands.
    var uninstallAt: Date? = nil

    /// "24 hours", "3 days".
    static func describe(_ wait: TimeInterval) -> String {
        let hours = Int((wait / 3600).rounded())
        if hours <= 24 || hours % 24 != 0 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        return "\(hours / 24) days"
    }

    static func first(locking ids: Set<String>) -> Self {
        Self(lockedPolicyIDs: ids, wait: defaultWait, pendingWait: nil, pendingWaitAt: nil)
    }

    static func validWait(_ value: TimeInterval) -> Bool {
        value.isFinite && (minimumWait...maximumWait).contains(value)
    }

    var isWellFormed: Bool {
        Self.validWait(wait) && (pendingWait == nil) == (pendingWaitAt == nil) &&
            pendingWait.map { Self.validWait($0) && $0 < wait } ?? true && lockedPolicyIDs.count <= 10_000 &&
            (uninstallAt?.timeIntervalSinceReferenceDate.isFinite ?? true)
    }

    func currentWait(at now: Date) -> TimeInterval {
        if let pendingWait, let pendingWaitAt, pendingWaitAt <= now { return pendingWait }
        return wait
    }

    /// The same policy with a due shorter wait landed.
    func settled(at now: Date) -> Self {
        guard let pendingWait, let pendingWaitAt, pendingWaitAt <= now else { return self }
        return Self(lockedPolicyIDs: lockedPolicyIDs, wait: pendingWait, pendingWait: nil, pendingWaitAt: nil,
                    uninstallAt: uninstallAt)
    }

    func setting(_ value: TimeInterval, at now: Date) -> Self {
        let current = currentWait(at: now)
        if value >= current {
            return Self(lockedPolicyIDs: lockedPolicyIDs, wait: value, pendingWait: nil, pendingWaitAt: nil,
                        uninstallAt: uninstallAt)
        }
        return Self(lockedPolicyIDs: lockedPolicyIDs, wait: current, pendingWait: value,
                    pendingWaitAt: now.addingTimeInterval(current), uninstallAt: uninstallAt)
    }

    func isRemovable(_ rule: DomainRestriction) -> Bool {
        rule.owner == .permanent && rule.endsAt == nil && !rule.isGoDay &&
            !rule.policyID.hasPrefix("owner-plan-") && !lockedPolicyIDs.contains(rule.policyID)
    }

    /// Never-removable stays never-removable when its sites move to a new rule.
    func locking(_ ids: some Sequence<String>) -> Self {
        Self(lockedPolicyIDs: lockedPolicyIDs.union(ids), wait: wait, pendingWait: pendingWait,
             pendingWaitAt: pendingWaitAt, uninstallAt: uninstallAt)
    }

    func uninstalling(at date: Date?) -> Self {
        Self(lockedPolicyIDs: lockedPolicyIDs, wait: wait, pendingWait: pendingWait, pendingWaitAt: pendingWaitAt,
             uninstallAt: date)
    }

    /// How long removing Shield waits from now: the permanent wait, and never
    /// less than 24 hours.
    func uninstallWait(at now: Date) -> TimeInterval { max(86_400, currentWait(at: now)) }

    /// A block that can never be removed also keeps Shield installed.
    func blocksUninstall(_ rule: DomainRestriction) -> Bool {
        rule.owner == .permanent && rule.endsAt == nil && !rule.isGoDay && !isRemovable(rule)
    }

    /// When the requested removal may run: its date, or later if a timed block
    /// or pending change is still running then. Nil if none was asked for.
    func uninstallDue(restrictions: [DomainRestriction], pending: [PendingPolicyRelease]) -> Date? {
        guard let uninstallAt else { return nil }
        return (restrictions.compactMap(\.endsAt) + pending.map(\.effectiveAt)).reduce(uninstallAt, max)
    }

    /// True once the requested removal is due and nothing forbids it.
    func uninstallIsDue(restrictions: [DomainRestriction], pending: [PendingPolicyRelease], at now: Date) -> Bool {
        guard let due = uninstallDue(restrictions: restrictions, pending: pending) else { return false }
        return due <= now && !restrictions.contains(where: blocksUninstall)
    }

    func canUndo(_ rule: DomainRestriction, pending: [PendingPolicyRelease], at now: Date) -> Bool {
        guard rule.owner == .permanent || rule.owner == .commitment, !rule.isGoDay,
              !rule.policyID.hasPrefix("lockin-"), !rule.policyID.hasPrefix("owner-plan-"),
              !lockedPolicyIDs.contains(rule.policyID), !pending.contains(where: { $0.policyID == rule.policyID }),
              let startsAt = rule.startsAt, startsAt <= now else { return false }
        return now.timeIntervalSince(startsAt) <= Self.undoWindow
    }
}

/// What the service sees of this Mac's time zone: the zone, and whether
/// macOS set it from Location (Settings → Date & Time → automatically).
struct ObservedZone: Equatable, Sendable {
    let identifier: String
    let automatic: Bool
}

/// Shield 1.1: the zone schedules run in. A zone macOS set from Location
/// applies at once (you traveled); one changed by hand waits 24 hours, like
/// any other change that could loosen a schedule. Going back cancels it.
struct ScheduleZone: Codable, Equatable, Sendable {
    static let manualDelay: TimeInterval = 86_400
    let identifier: String
    var pendingIdentifier: String? = nil
    var pendingAt: Date? = nil

    var isWellFormed: Bool {
        TimeZone(identifier: identifier) != nil && (pendingIdentifier == nil) == (pendingAt == nil) &&
            pendingIdentifier.map { TimeZone(identifier: $0) != nil && $0 != identifier } ?? true
    }

    func settled(at now: Date) -> Self {
        guard let pendingIdentifier, let pendingAt, pendingAt <= now else { return self }
        return Self(identifier: pendingIdentifier)
    }

    func observing(_ seen: ObservedZone, at now: Date) -> Self {
        let current = settled(at: now)
        // Compared as macOS names them ("UTC" is "GMT").
        guard let id = TimeZone(identifier: seen.identifier)?.identifier else { return current }
        if id == current.identifier || seen.automatic { return Self(identifier: id) }
        if current.pendingIdentifier == id { return current }
        return Self(identifier: current.identifier, pendingIdentifier: id,
                    pendingAt: now.addingTimeInterval(Self.manualDelay))
    }
}

struct BackendDocument: Codable, Sendable {
    // V2 adds atomic delayed schedule replacement. Old services must reject it
    // rather than decode a replacement as an unconditional release.
    // V3 adds apps to rules. V4 adds conditional rules (places, location and
    // condition rules). Each is written only while it is needed, so an older
    // service refuses exactly the documents it would otherwise mis-read
    // (silently dropping apps or rules it doesn't know). V5 adds Go days.
    // V6 adds removable permanent blocks (`PermanentRemovalPolicy`).
    static let schemaVersion = 6

    static func version(restrictions: [DomainRestriction], schedules: [DailySchedule],
                        pendingReleases: [PendingPolicyRelease], conditions: ConditionalPolicy? = nil,
                        permanentRemoval: PermanentRemovalPolicy? = nil) -> Int {
        if permanentRemoval != nil { return 6 }
        if restrictions.contains(where: \.isGoDay) { return 5 }
        if conditions != nil || pendingReleases.contains(where: { ConditionalPolicy.isConditionalOwner($0.policyID) }) ||
            restrictions.contains(where: { $0.placeID != nil }) {
            return 4
        }
        let hasApps = restrictions.contains { !$0.apps.isEmpty } || schedules.contains { !$0.apps.isEmpty }
            || pendingReleases.contains { !($0.replacementSchedule?.apps.isEmpty ?? true) }
        return hasApps ? 3 : 2
    }

    /// Nothing is stored for an empty set (a presence record alone means nothing).
    static func stored(_ conditions: ConditionalPolicy) -> ConditionalPolicy? {
        conditions.isEmpty ? nil : conditions
    }

    let version: Int
    let generation: UInt64
    let updatedAt: Date
    let lastRequestID: UUID
    let lastRequestDigest: String?
    let restrictions: [DomainRestriction]
    let schedules: [DailySchedule]
    let pendingReleases: [PendingPolicyRelease]
    var conditions: ConditionalPolicy? = nil
    var permanentRemoval: PermanentRemovalPolicy? = nil
    /// Nil: the zone the service was installed with.
    var scheduleZone: ScheduleZone? = nil
}

struct BackendReceiptPayload: Codable, Equatable, Sendable {
    let version: Int
    let requestID: UUID
    let generation: UInt64
    let appliedAt: Date
    let authorityDigest: String
    let hostsDigest: String
    let documentDigest: String
}

struct BackendReceipt: Codable, Equatable, Sendable {
    let payload: BackendReceiptPayload
    let authenticationCode: Data
}

enum BackendAckStatus: String, Codable, Sendable {
    case applied
    case alreadyApplied
    case unchanged
    case recovered
}

struct BackendAcknowledgment: Codable, Sendable {
    let version: Int
    let status: BackendAckStatus
    let receipt: BackendReceipt
    let nextTransition: Date?
}

enum EnforcementSource: String, Codable, Sendable {
    case fixtureHosts
    case disposableSystemHosts
    case installedSystemHosts
}

// Read-side contract for a future privileged transport. A fixture snapshot is
// evidence of its own committed files, never proof of network enforcement.
struct BackendSnapshot: Sendable {
    let generation: UInt64
    let committedRestrictions: [DomainRestriction]
    let committedSchedules: [DailySchedule]
    let pendingReleases: [PendingPolicyRelease]
    let authority: AuthorityState
    let enforcement: EnforcementSnapshot
    let enforcementSource: EnforcementSource
    let receipt: BackendReceipt
    let nextTransition: Date?
    var timeZoneIdentifier: String? = nil
    var serviceGaps: [ServiceGap] = []
    var conditions: ConditionalPolicy? = nil
    /// Whether the service accepts places and place blocks. The in-process
    /// backend always does; a service says so in its snapshot.
    var supportsPlaces = true
    /// Whether the service runs Go days (same pattern as places).
    var supportsGoDays = true
    /// Whether the service also gives browsers its block list as admin
    /// policy (they read it when they open). Off unless the service says so.
    var supportsBrowserPolicy = false
    /// When the service last confirmed this state (from its reply); nil from
    /// an older service, whose liveness shows as `authority.generatedAt`.
    var verifiedAt: Date? = nil

    static let placesFeature = "places"
    static let goDaysFeature = "goday"
    static let browserPolicyFeature = "browser-policy"
    static let permanentRemovalFeature = "permanent-removal"

    /// Nil from a service that predates removable permanent blocks: then
    /// every permanent block is never-removable.
    var permanentRemoval: PermanentRemovalPolicy? = nil
    var supportsPermanentRemoval: Bool { permanentRemoval != nil }
    /// A time zone change waiting its 24 hours shows here (1.1).
    var scheduleZone: ScheduleZone? = nil
}

enum FixtureBackendError: Error, LocalizedError {
    case unsafeRoot
    case uncertain(String)
    case invalidRequest(String)
    case generationConflict
    case invalidReceipt
    case injectedInterruption

    var errorDescription: String? {
        switch self {
        case .unsafeRoot: "The backend prototype accepts only an existing isolated fixture directory."
        case .uncertain(let detail): "Backend state is uncertain: \(detail)"
        case .invalidRequest(let detail): "Invalid backend request: \(detail)"
        case .generationConflict: "The request generation does not match committed state."
        case .invalidReceipt: "The reconciliation receipt could not be authenticated."
        case .injectedInterruption: "A fixture-only interruption was injected."
        }
    }
}

/// A file's identity and change times, for telling "unchanged" apart from
/// "rewritten" without reading it (R4). Any write or rename changes
/// the inode change time (ctime), which ordinary tools can't set back.
struct FileStamp: Equatable, Sendable {
    let device: Int64, inode: UInt64, size: Int64
    let modified: timespec, changed: timespec

    init(_ info: stat) {
        device = Int64(info.st_dev); inode = UInt64(info.st_ino); size = Int64(info.st_size)
        modified = info.st_mtimespec; changed = info.st_ctimespec
    }

    /// nil when the file doesn't exist or can't be examined.
    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        self.init(info)
    }

    static func == (a: FileStamp, b: FileStamp) -> Bool {
        a.device == b.device && a.inode == b.inode && a.size == b.size &&
            a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec &&
            a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
    }
}

struct FixtureBackendPaths: Sendable {
    let root: URL
    var document: URL { root.appendingPathComponent("backend-state.plist") }
    var authority: URL { root.appendingPathComponent("authority.plist") }
    var hosts: URL { root.appendingPathComponent("hosts") }
    var journal: URL { root.appendingPathComponent("pending-transition.plist") }
    var receipt: URL { root.appendingPathComponent("receipt.plist") }
    var key: URL { root.appendingPathComponent("receipt-key") }
    var lock: URL { root.appendingPathComponent("backend.lock") }
    var heartbeat: URL { root.appendingPathComponent("service-heartbeat.json") }
    var serviceGaps: URL { root.appendingPathComponent("service-gaps.json") }
}

private struct SignedBackendJournal: Codable {
    let documentData: Data
    let requestID: UUID
    let authenticationCode: Data
}

enum FixtureBackendFault: Sendable {
    case afterJournal
    case afterHosts
}

/// Decoded state files, each kept per exact content. A file that changed in
/// any way decodes and is checked again.
final class BackendReadCache: Sendable {
    let document = DecodedBytesCache<BackendDocument>()
    let authority = DecodedBytesCache<AuthorityStateReader.AuthorityStructure>()
    let hosts = DecodedBytesCache<(domains: Set<String>, managedSectionPresent: Bool)>()
    /// Hosts rendered from a given input file and blocked set.
    let renderedHosts = DecodedBytesCache<(domains: Set<String>, hosts: Data)>()
    /// The last document and authority found to agree.
    let agreement = AgreementMemo()
}

/// The exact document and authority bytes (and calendar) last found to agree
/// on which sites are blocked. That check is a pure function of these three,
/// so while none changed it needn't re-evaluate every list.
final class AgreementMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: (document: Data, authority: Data, calendar: Calendar)?

    func contains(document: Data, authority: Data, calendar: Calendar) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let entry else { return false }
        return entry.calendar == calendar && entry.document == document && entry.authority == authority
    }

    func store(document: Data, authority: Data, calendar: Calendar) {
        lock.lock(); entry = (document, authority, calendar); lock.unlock()
    }
}

/// The authority and hosts a commit writes, plus the authority as a value.
struct RenderedState {
    let authority: Data
    let hosts: Data
    let state: AuthorityState
}

struct FixtureBackend: Sendable {
    /// The installed service reports this Mac's time zone here each pass
    /// (`ScheduleZone`); nil keeps the zone the backend was given.
    var observeZone: (@Sendable () -> ObservedZone?)? = nil
    let paths: FixtureBackendPaths
    private let store: AtomicFixtureStore
    let fault: FixtureBackendFault?
    /// Decoded state files, kept per exact content (big lists decode once).
    private let readCache = BackendReadCache()

    #if DEBUG
    /// Tests: write documents as a pre-1.1 service did (no removal record).
    var writesPreRemovalDocuments = false
    #endif

    init(root: URL, fault: FixtureBackendFault? = nil, installedAuthority: Bool = false) throws {
        let fixtureBase = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let path = root.standardizedFileURL.path
        let reviewRoot = ShieldRuntime.fixtureDirectory.standardizedFileURL.path
        // Root's Foundation temporary directory can differ from the runner's
        // /private/tmp. Permit only the disposable CI LaunchDaemon fixture
        // created by test_root_xpc_app.sh, with an explicit process flag.
        let declaredCIRoot = ProcessInfo.processInfo.environment["SHIELD_CI_ROOT_FIXTURE_PATH"] ?? ""
        let ciRootFixture = geteuid() == 0 &&
            ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" &&
            ProcessInfo.processInfo.environment["SHIELD_CI_ROOT_FIXTURE"] == "1" &&
            declaredCIRoot.range(of: #"^/(private/)?tmp/shield-root-xpc\.[A-Za-z0-9]{6}/fixture$"#,
                                 options: .regularExpression) != nil &&
            path == URL(fileURLWithPath: declaredCIRoot).standardizedFileURL.path
        if ProcessInfo.processInfo.environment["SHIELD_CI_ROOT_FIXTURE"] == "1", !ciRootFixture {
            fputs("fixture-backend: CI root path rejected: path=\(path) base=\(fixtureBase) uid=\(geteuid()) actions=\(ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] ?? "unset")\n", stderr)
        }
        var installedRoot = false
        #if SHIELD_AUTHORITY_SERVICE
        installedRoot = installedAuthority && fault == nil && geteuid() == 0 &&
            path == "/Library/Application Support/ShieldAuthority/state"
        #endif
        guard !installedAuthority || installedRoot else { throw FixtureBackendError.unsafeRoot }
        guard root.isFileURL,
              path.hasPrefix(fixtureBase + "/") ||
                installedRoot ||
                ciRootFixture ||
                (ShieldRuntime.isUIReview && path == reviewRoot &&
                 root.resolvingSymlinksInPath().standardizedFileURL.path == reviewRoot) else {
            throw FixtureBackendError.unsafeRoot
        }
        self.paths = FixtureBackendPaths(root: root.standardizedFileURL)
        self.store = AtomicFixtureStore(allowedRoot: root.standardizedFileURL)
        self.fault = fault
        try store.validatePath(paths.document)
    }

    // Installer-only bootstrap of a genuinely new installation. Never called
    // from XPC and never repairs an empty, partial, or invalid prior authority.
    func initializeEmptyAuthority(now: Date, calendar: Calendar) throws {
        let lock = try ExclusiveFileLock(url: paths.lock)
        defer { withExtendedLifetime(lock) {} }
        let existing = try FileManager.default.contentsOfDirectory(atPath: paths.root.path)
        guard Set(existing).isSubset(of: ["backend.lock"]), !existing.contains("hosts") else {
            throw FixtureBackendError.uncertain("Initialization requires a new, empty authority directory.")
        }
        try store.write(Data("127.0.0.1 localhost\n".utf8), to: paths.hosts)
        let id = UUID()
        let document = BackendDocument(version: 2, generation: 1,
            updatedAt: now, lastRequestID: id, lastRequestDigest: nil,
            restrictions: [], schedules: [], pendingReleases: [])
        _ = try commit(document, requestID: id, now: now, calendar: calendar, status: .applied)
    }

    func apply(_ request: BackendRequest, now: Date, calendar: Calendar) throws -> BackendAcknowledgment {
        let lock = try ExclusiveFileLock(url: paths.lock)
        defer { withExtendedLifetime(lock) {} }
        if FileManager.default.fileExists(atPath: paths.journal.path) {
            _ = try recoverLocked(now: now, calendar: calendar)
        }
        try validateEnvelope(request, now: now, checkTimestamp: false)

        let current: BackendDocument?
        if FileManager.default.fileExists(atPath: paths.document.path) {
            current = try loadVerifiedDocument(now: now, calendar: calendar)
        } else {
            guard !FileManager.default.fileExists(atPath: paths.authority.path),
                  !FileManager.default.fileExists(atPath: paths.receipt.path),
                  !FileManager.default.fileExists(atPath: paths.key.path),
                  request.expectedGeneration == 0 else {
                throw FixtureBackendError.uncertain("No valid committed document exists; bootstrap cannot infer old policy.")
            }
            let hosts = try String(data: store.read(paths.hosts), encoding: .utf8)
                .unwrap(or: FixtureBackendError.uncertain("Fixture hosts is not valid UTF-8."))
            guard try !HostsEnforcementReader(fileURL: paths.hosts).parse(hosts).managedSectionPresent else {
                throw FixtureBackendError.uncertain("Existing managed hosts rules cannot be replaced by bootstrap.")
            }
            current = nil
        }

        if let current, current.lastRequestID == request.id {
            guard current.lastRequestDigest == (try requestDigest(request)) else {
                throw FixtureBackendError.invalidRequest("A request ID was reused with different or unverified content.")
            }
            return BackendAcknowledgment(version: 1, status: .alreadyApplied,
                                         receipt: try verifiedReceipt(),
                                         nextTransition: nextTransition(in: current, at: now, calendar: calendar))
        }
        // A byte-identical acknowledged request remains queryable after the
        // submission window. Only genuinely new mutations need a fresh clock.
        try validateEnvelope(request, now: now)
        guard request.expectedGeneration == (current?.generation ?? 0) else {
            throw FixtureBackendError.generationConflict
        }
        let (nextGeneration, overflow) = (current?.generation ?? 0).addingReportingOverflow(1)
        guard !overflow else {
            throw FixtureBackendError.uncertain("Generation overflow.")
        }
        let settled = current.map { settledPolicy(in: $0, at: now) }
        var restrictions = settled?.restrictions ?? []
        var schedules = settled?.schedules ?? []
        var pending = settled?.pending ?? []
        var conditions = settled?.conditions ?? .empty
        // First request under 1.1: every permanent block already here was made
        // as never-removable, so it stays that way.
        var removal = current?.permanentRemoval?.settled(at: now) ??
            .first(locking: Set(restrictions.filter { $0.owner == .permanent }.map(\.policyID)))
        let permanentsBefore = Set(restrictions.filter { $0.owner == .permanent }.map(\.policyID))
        for command in request.commands {
            try apply(command, restrictions: &restrictions, schedules: &schedules,
                      pending: &pending, conditions: &conditions, removal: &removal, now: now)
        }
        // Correcting a never-removable block keeps its other sites in a new
        // rule; that rule is never-removable too.
        if request.commands.contains(where: { $0.kind == .correctRecentPermanent &&
            ($0.policyID.map { removal.lockedPolicyIDs.contains($0) } ?? false) }) {
            removal = removal.locking(restrictions.filter { $0.owner == .permanent &&
                !permanentsBefore.contains($0.policyID) }.map(\.policyID))
        }
        // Something stronger added while removal is pending gets the same wait
        // it would have had on its own.
        if let uninstallAt = removal.uninstallAt,
           request.commands.contains(where: { Self.strengthensWhileUninstalling.contains($0.kind) }) {
            removal = removal.uninstalling(at: max(uninstallAt, now.addingTimeInterval(removal.uninstallWait(at: now))))
        }
        guard !restrictions.isEmpty || !schedules.isEmpty else {
            throw FixtureBackendError.invalidRequest("An empty initial policy is not an authorized bootstrap.")
        }
        let conditionalPending = { (list: [PendingPolicyRelease]) in
            list.filter { ConditionalPolicy.isConditionalOwner($0.policyID) }
        }
        if conditions != (settled?.conditions ?? .empty) ||
            conditionalPending(pending) != conditionalPending(settled?.pending ?? []) {
            try validate(conditions, pending: pending)
        }
        let stored = BackendDocument.stored(conditions)
        var written: PermanentRemovalPolicy? = removal
        #if DEBUG
        if writesPreRemovalDocuments { written = nil }
        #endif
        let next = BackendDocument(version: BackendDocument.version(restrictions: restrictions, schedules: schedules,
                                                                    pendingReleases: pending, conditions: stored,
                                                                    permanentRemoval: written),
                                   generation: nextGeneration, updatedAt: now,
                                   lastRequestID: request.id, lastRequestDigest: try requestDigest(request),
                                   restrictions: restrictions,
                                   schedules: schedules, pendingReleases: pending, conditions: stored,
                                   permanentRemoval: written, scheduleZone: current?.scheduleZone?.settled(at: now))
        return try commit(next, requestID: request.id, now: now, calendar: calendar, status: .applied)
    }

    func tick(now: Date, calendar: Calendar) throws -> BackendAcknowledgment {
        let lock = try ExclusiveFileLock(url: paths.lock)
        defer { withExtendedLifetime(lock) {} }
        if FileManager.default.fileExists(atPath: paths.journal.path) {
            return try recoverLocked(now: now, calendar: calendar)
        }
        return try tickLocked(now: now, calendar: calendar)
    }

    // A presence record goes stale after 120 s. While location-based rules
    // exist, a report refreshes the stored record once it is this old, even
    // when nothing changes, so continued presence doesn't lapse between reports.
    static let presenceRefreshAge: TimeInterval = 30
    /// An unchanged authority is re-committed this often. Each re-commit
    /// rewrites every list, so it is kept rare; the service's liveness reaches
    /// the app as the `verifiedAt` of each reply instead.
    static let authorityRefreshInterval: TimeInterval = 600

    /// Judges a report from the app (gate, then dwell tracking in `session`)
    /// and records the verdicts. Commits a new generation only when the
    /// effective blocks change or the stored record needs refreshing. A refused
    /// report changes nothing stored; the old record simply ages out (strict).
    func reportPresence(_ report: PresenceReport, session: PresenceSession,
                        now: Date, calendar: Calendar) throws -> BackendAcknowledgment {
        let lock = try ExclusiveFileLock(url: paths.lock)
        defer { withExtendedLifetime(lock) {} }
        if FileManager.default.fileExists(atPath: paths.journal.path) {
            _ = try recoverLocked(now: now, calendar: calendar)
        }
        let current = try loadVerifiedDocument(now: now, calendar: calendar)
        let settled = settledPolicy(in: current, at: now)
        var conditions = settled.conditions
        let goDays = settled.restrictions.filter { $0.isGoDay && $0.goDay?.arrivedAt == nil && $0.isEffective(at: now) }
        let record: PresenceSnapshot
        let arrived: Set<String>
        switch session.judge(report, places: conditions.places, goDays: goDays, now: now, calendar: calendar) {
        case .success(let value): (record, arrived) = value
        case .failure(let rejection):
            throw FixtureBackendError.invalidRequest("Presence report refused (\(rejection)); location stays unknown.")
        }
        let unchanged = { try BackendAcknowledgment(version: 1, status: .unchanged, receipt: self.verifiedReceipt(),
                                                     nextTransition: self.nextTransition(in: current, at: now, calendar: calendar)) }
        // A confirmed arrival lifts that day's lock for the rest of the day.
        let restrictions = settled.restrictions.map { arrived.contains($0.policyID) ? $0.arrived(at: now) : $0 }
        guard !conditions.isEmpty || !arrived.isEmpty else { return try unchanged() }
        if !conditions.isEmpty { conditions.presence = record }
        let engine = UnifiedPolicyEngine()
        let zoned = Self.zoned(calendar, current.scheduleZone, at: now)
        let before = engine.evaluate(restrictions: current.restrictions, schedules: current.schedules,
                                     at: now, calendar: zoned, conditions: current.conditions)
        let after = engine.evaluate(restrictions: restrictions, schedules: settled.schedules,
                                    at: now, calendar: zoned, conditions: conditions)
        // Refresh a stored verdict only with a newer known one: an unknown
        // record lifts nothing, and the same fix again changes nothing.
        let stale = record.locationKnown && (current.conditions?.presence.map {
            !$0.locationKnown || $0.capturedAt > now ||
                record.capturedAt.timeIntervalSince($0.capturedAt) >= Self.presenceRefreshAge
        } ?? true)
        let placeBlocks = settled.restrictions.contains { $0.placeID != nil }
        guard !arrived.isEmpty || before.domains != after.domains || before.apps != after.apps ||
                ((conditions.usesPlaces || placeBlocks) && stale) else { return try unchanged() }
        guard current.generation < UInt64.max else { throw FixtureBackendError.uncertain("Generation overflow.") }
        let stored = BackendDocument.stored(conditions)
        let next = BackendDocument(version: BackendDocument.version(restrictions: restrictions,
                                                                    schedules: settled.schedules,
                                                                    pendingReleases: settled.pending, conditions: stored,
                                                                    permanentRemoval: current.permanentRemoval?.settled(at: now)),
                                   generation: current.generation + 1, updatedAt: now,
                                   lastRequestID: current.lastRequestID, lastRequestDigest: current.lastRequestDigest,
                                   restrictions: restrictions, schedules: settled.schedules,
                                   pendingReleases: settled.pending, conditions: stored,
                                   permanentRemoval: current.permanentRemoval?.settled(at: now),
                                   scheduleZone: current.scheduleZone?.settled(at: now))
        return try commit(next, requestID: next.lastRequestID, now: now, calendar: calendar, status: .applied,
                          previous: current)
    }

    /// Run once when the service starts: a record from the previous run is not
    /// trusted (the new run has no gate or dwell state for it), so location is
    /// unknown and place blocks hold until this run accepts a fresh report.
    @discardableResult
    func forgetPresence(now: Date, calendar: Calendar) throws -> BackendAcknowledgment? {
        let lock = try ExclusiveFileLock(url: paths.lock)
        defer { withExtendedLifetime(lock) {} }
        guard FileManager.default.fileExists(atPath: paths.document.path) else { return nil }
        if FileManager.default.fileExists(atPath: paths.journal.path) {
            _ = try recoverLocked(now: now, calendar: calendar)
        }
        let current = try loadVerifiedDocument(now: now, calendar: calendar)
        guard current.conditions?.presence?.locationKnown == true else { return nil }
        // Settle due changes first, as every other commit does.
        let settled = settledPolicy(in: current, at: now)
        var conditions = settled.conditions
        conditions.presence = PresenceSnapshot(capturedAt: now, locationKnown: false, places: [:],
                                               studyMinutesToday: nil)
        let stored = BackendDocument.stored(conditions)
        guard current.generation < UInt64.max else { throw FixtureBackendError.uncertain("Generation overflow.") }
        let next = BackendDocument(version: BackendDocument.version(restrictions: settled.restrictions,
                                                                    schedules: settled.schedules,
                                                                    pendingReleases: settled.pending, conditions: stored,
                                                                    permanentRemoval: current.permanentRemoval?.settled(at: now)),
                                   generation: current.generation + 1, updatedAt: now,
                                   lastRequestID: current.lastRequestID, lastRequestDigest: current.lastRequestDigest,
                                   restrictions: settled.restrictions, schedules: settled.schedules,
                                   pendingReleases: settled.pending, conditions: stored,
                                   permanentRemoval: current.permanentRemoval?.settled(at: now),
                                   scheduleZone: current.scheduleZone?.settled(at: now))
        return try commit(next, requestID: next.lastRequestID, now: now, calendar: calendar, status: .applied,
                          previous: current)
    }

    // The caller owns the file lock, including recovery followed by maintenance.
    private func tickLocked(now: Date, calendar: Calendar) throws -> BackendAcknowledgment {
        let current = try loadVerifiedDocument(now: now, calendar: calendar)
        let settled = settledPolicy(in: current, at: now)
        let retainedRestrictions = settled.restrictions
        let retainedSchedules = settled.schedules
        let pending = settled.pending
        let conditions = BackendDocument.stored(settled.conditions)
        let nextZone = observedZone(current.scheduleZone, base: calendar, now: now)
        let changed = retainedRestrictions.count != current.restrictions.count ||
            retainedSchedules != current.schedules || pending.count != current.pendingReleases.count ||
            conditions != current.conditions || nextZone != current.scheduleZone
        let evaluated = UnifiedPolicyEngine().evaluate(restrictions: current.restrictions,
                                                       schedules: current.schedules,
                                                       at: now, calendar: Self.zoned(calendar, current.scheduleZone, at: now),
                                                       conditions: current.conditions)
        let read = AuthorityStateReader(fileURL: paths.authority, maximumAge: .infinity,
                                        cache: readCache.authority).read(now: now)
        guard case .valid(let authority) = read else {
            throw FixtureBackendError.uncertain("Authority cannot be read for transition evaluation.")
        }
        // Owners and their domains: a conditional rule can open or close part
        // of a schedule's domains without changing which owners are active.
        struct Owner: Hashable { let owner: String; let policyID: String; let domains: Set<String> }
        func owners(_ list: [DomainRestriction]) -> Set<Owner> {
            Set(list.map { Owner(owner: $0.owner.rawValue, policyID: $0.policyID, domains: $0.domains) })
        }
        let expectedOwners = owners(evaluated.restrictions)
        let observedOwners = owners(authority.effectiveRestrictions)
        if !changed && expectedOwners == observedOwners &&
           now.timeIntervalSince(current.updatedAt) < Self.authorityRefreshInterval {
            // `evaluated` is exactly what nextTransition(in: current, at: now) would compute.
            return BackendAcknowledgment(version: 1, status: .unchanged,
                                         receipt: try verifiedReceipt(),
                                         nextTransition: Self.nextTransition(evaluated.nextTransition,
                                                                             pending: current.pendingReleases, after: now,
                                                                             zone: current.scheduleZone))
        }
        guard current.generation < UInt64.max else { throw FixtureBackendError.uncertain("Generation overflow.") }
        let next = BackendDocument(version: BackendDocument.version(restrictions: retainedRestrictions,
                                                                    schedules: retainedSchedules, pendingReleases: pending,
                                                                    conditions: conditions,
                                                                    permanentRemoval: current.permanentRemoval?.settled(at: now)),
                                   generation: current.generation + 1,
                                   // Maintenance advances the generation but must not erase
                                   // the last accepted client UUID/digest. A lost reply can
                                   // still be reconciled after heartbeat, expiry or restart.
                                   updatedAt: now, lastRequestID: current.lastRequestID,
                                   lastRequestDigest: current.lastRequestDigest,
                                   restrictions: retainedRestrictions, schedules: retainedSchedules,
                                   pendingReleases: pending, conditions: conditions,
                                   permanentRemoval: current.permanentRemoval?.settled(at: now),
                                   scheduleZone: nextZone)
        return try commit(next, requestID: next.lastRequestID, now: now, calendar: calendar, status: .applied,
                          previous: current)
    }

    private func settledPolicy(in document: BackendDocument, at now: Date)
        -> (restrictions: [DomainRestriction], schedules: [DailySchedule], pending: [PendingPolicyRelease],
            conditions: ConditionalPolicy) {
        let restrictions = document.restrictions.filter { $0.endsAt.map { now < $0 } ?? true }
        let due = Set(document.pendingReleases.filter { $0.effectiveAt <= now }.map(\.policyID))
        let retainedRestrictions = restrictions.filter { !due.contains($0.policyID) }
        let retainedSchedules = document.schedules.compactMap { schedule -> DailySchedule? in
            guard due.contains(schedule.id) else { return schedule }
            return document.pendingReleases.first { $0.policyID == schedule.id }?.replacementSchedule
        }
        let retainedOwners = Set(retainedRestrictions.map(\.policyID) + retainedSchedules.map(\.id))
        // A timed commitment may expire before its requested release. Its pending
        // release must expire with that owner; an orphan would poison the next load.
        // A place or rule change may add an owner that does not exist yet.
        let pending = document.pendingReleases.filter {
            $0.effectiveAt > now &&
                (ConditionalPolicy.isConditionalOwner($0.policyID) || retainedOwners.contains($0.policyID))
        }
        var conditions = document.conditions ?? .empty
        let placesBefore = conditions.places
        for release in document.pendingReleases where release.effectiveAt <= now {
            release.land(in: &conditions)
        }
        conditions.forgetPresence(forChanged: placesBefore)
        return (retainedRestrictions, retainedSchedules, pending, conditions)
    }

    /// A place or rule set must be valid now and once every pending change
    /// has landed, so no later landing can leave a rule naming a missing place.
    private func validate(_ conditions: ConditionalPolicy, pending: [PendingPolicyRelease]) throws {
        var projected = conditions
        for release in pending.sorted(by: { $0.effectiveAt < $1.effectiveAt }) { release.land(in: &projected) }
        for candidate in [conditions, projected] {
            let problems = RulePlaceValidator.problems(places: candidate.places, rules: candidate.rules)
            guard problems.isEmpty else {
                throw FixtureBackendError.invalidRequest("Places and rules are invalid: \(problems).")
            }
        }
    }

    // Tamper evidence lives beside, not inside, the signed policy document:
    // it never participates in receipts or policy evaluation.
    func loadHeartbeat() -> AuthorityHeartbeat? {
        guard FileManager.default.fileExists(atPath: paths.heartbeat.path),
              let data = try? store.read(paths.heartbeat) else { return nil }
        return try? JSONDecoder().decode(AuthorityHeartbeat.self, from: data)
    }

    /// Stamps of every file a snapshot is built from (not the heartbeat or
    /// gap log). Equal stamps mean none of them was written since.
    func stateStamp() -> [FileStamp?] {
        [paths.document, paths.authority, paths.hosts, paths.journal, paths.receipt, paths.key]
            .map { FileStamp(path: $0.path) }
    }

    func recordHeartbeat(_ beat: AuthorityHeartbeat) throws {
        try store.write(JSONEncoder().encode(beat), to: paths.heartbeat)
    }

    func serviceGaps() -> [ServiceGap] {
        guard FileManager.default.fileExists(atPath: paths.serviceGaps.path),
              let data = try? store.read(paths.serviceGaps) else { return [] }
        return (try? JSONDecoder().decode([ServiceGap].self, from: data)) ?? []
    }

    func appendServiceGap(_ gap: ServiceGap) throws {
        let gaps = (serviceGaps() + [gap]).suffix(ServiceGapClassifier.retainedGaps)
        try store.write(JSONEncoder().encode(Array(gaps)), to: paths.serviceGaps)
    }

    func recover(now: Date, calendar: Calendar) throws -> BackendAcknowledgment {
        let lock = try ExclusiveFileLock(url: paths.lock)
        defer { withExtendedLifetime(lock) {} }
        return try recoverLocked(now: now, calendar: calendar)
    }

    func snapshot(now: Date, calendar: Calendar) throws -> BackendSnapshot {
        let lock = try ExclusiveFileLock(url: paths.lock)
        defer { withExtendedLifetime(lock) {} }
        guard !FileManager.default.fileExists(atPath: paths.journal.path) else {
            throw FixtureBackendError.uncertain("A transition needs recovery before state can be reported.")
        }
        let document = try loadVerifiedDocument(now: now, calendar: calendar)
        let authorityStatus = AuthorityStateReader(fileURL: paths.authority, maximumAge: .infinity,
                                                   cache: readCache.authority).read(now: now)
        guard case .valid(let authority) = authorityStatus else {
            throw FixtureBackendError.uncertain("Authority cannot be read.")
        }
        var hostsReader = HostsEnforcementReader(fileURL: paths.hosts)
        hostsReader.cache = readCache.hosts
        guard case .success(let enforcement) = hostsReader.read() else {
            throw FixtureBackendError.uncertain("Reconciled hosts evidence cannot be read.")
        }
        return BackendSnapshot(generation: document.generation,
                               committedRestrictions: document.restrictions,
                               committedSchedules: document.schedules,
                               pendingReleases: document.pendingReleases,
                               authority: authority,
                               enforcement: enforcement,
                               enforcementSource: .fixtureHosts,
                               receipt: try verifiedReceipt(),
                               nextTransition: nextTransition(in: document, at: now, calendar: calendar),
                               timeZoneIdentifier: document.scheduleZone?.settled(at: now).identifier,
                               conditions: document.conditions,
                               permanentRemoval: document.permanentRemoval?.settled(at: now) ??
                                   .first(locking: Set(document.restrictions.filter { $0.owner == .permanent }.map(\.policyID))),
                               scheduleZone: document.scheduleZone?.settled(at: now))
    }

    func verifiedReceipt() throws -> BackendReceipt {
        let key = try readKey()
        let receipt = try decode(BackendReceipt.self, at: paths.receipt)
        guard receipt.payload.version == 1,
              try authenticate(receipt.payload, key: key) == receipt.authenticationCode else {
            throw FixtureBackendError.invalidReceipt
        }
        let authority = try store.read(paths.authority)
        let hosts = try store.read(paths.hosts)
        let document = try store.read(paths.document)
        guard receipt.payload.authorityDigest == digest(authority),
              receipt.payload.hostsDigest == digest(hosts),
              receipt.payload.documentDigest == digest(document) else {
            throw FixtureBackendError.invalidReceipt
        }
        return receipt
    }

    private func validateEnvelope(_ request: BackendRequest, now: Date, checkTimestamp: Bool = true) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              request.submittedAt.timeIntervalSinceReferenceDate.isFinite,
              request.version == BackendRequest.schemaVersion,
              !request.commands.isEmpty, request.commands.count <= 100,
              request.commands.allSatisfy({ command in
                  [command.effectiveAt, command.restriction?.startsAt, command.restriction?.endsAt,
                   command.conditionalRule?.committedAt]
                      .compactMap { $0 }.allSatisfy { $0.timeIntervalSinceReferenceDate.isFinite }
              }),
              (!checkTimestamp || abs(now.timeIntervalSince(request.submittedAt)) <= 300) else {
            throw FixtureBackendError.invalidRequest("Version, action count, or timestamp is invalid.")
        }
    }

    private func requestDigest(_ request: BackendRequest) throws -> String {
        func stamp(_ date: Date?) -> String { date.map { String($0.timeIntervalSinceReferenceDate.bitPattern) } ?? "" }
        var fields = [[String(request.version), request.id.uuidString,
                       String(request.expectedGeneration), stamp(request.submittedAt)]]
        for command in request.commands {
            var part = [command.kind.rawValue, command.policyID ?? "", stamp(command.effectiveAt)]
            if let wait = command.waitSeconds { part += ["wait", String(wait.bitPattern)] }
            if let rule = command.restriction {
                part += [rule.id.uuidString, rule.owner.rawValue, rule.policyID, rule.title,
                         stamp(rule.startsAt), stamp(rule.endsAt)] + rule.domains.sorted()
                // Only when present, so earlier requests keep their digest.
                if let place = rule.placeID { part += ["place", place] }
                if !rule.apps.isEmpty { part += ["apps"] + rule.apps.map { "\($0.bundleID)|\($0.teamID ?? "")" }.sorted() }
                if let gate = rule.goDay {
                    part += ["goday", stamp(gate.arrivedAt)] + gate.startTags.sorted()
                    if let fix = gate.startFix {
                        part += [fix.latitude, fix.longitude, fix.horizontalAccuracy].map { String($0.bitPattern) }
                    }
                    for place in gate.places {
                        part += [place.name] + [place.latitude, place.longitude, place.radiusMeters].map { String($0.bitPattern) }
                    }
                }
            }
            if let schedule = command.schedule {
                part += [schedule.id, schedule.title, String(schedule.startMinutes),
                         String(schedule.endMinutes), String(schedule.isRequested)] + schedule.domains.sorted()
            }
            fields.append(part)
            if let place = command.place {
                fields.append(["place", place.id, place.name, String(place.latitude.bitPattern),
                               String(place.longitude.bitPattern), String(place.radiusMeters.bitPattern),
                               String(place.isHome)] + place.wifiTags.sorted())
            }
            if let rule = command.conditionalRule {
                fields.append(["rule", rule.id, rule.title, rule.effect.rawValue, stamp(rule.committedAt)] +
                              rule.domains.sorted())
                fields.append(["conditions"] + rule.conditions.map { condition in
                    switch condition {
                    case .timeWindow(let start, let end, let weekdays):
                        "time \(start) \(end) \(weekdays.sorted())"
                    case .atPlace(let id, let minutes): "at \(minutes) \(id)"
                    case .notAtPlace(let id): "away \(id)"
                    case .arrivedToday(let id, let minutes): "arrived \(minutes) \(id)"
                    case .studiedToday(let minutes): "studied \(minutes)"
                    }
                })
            }
        }
        return digest(try JSONEncoder().encode(fields))
    }

    private static let strengthensWhileUninstalling: Set<BackendCommandKind> = [
        .addRestriction, .addSchedule, .strengthenSchedule, .addPlace, .addConditionalRule, .replaceConditionalRule,
    ]

    private func apply(_ command: BackendCommand,
                       restrictions: inout [DomainRestriction],
                       schedules: inout [DailySchedule],
                       pending: inout [PendingPolicyRelease], conditions: inout ConditionalPolicy,
                       removal: inout PermanentRemovalPolicy, now: Date) throws {
        guard command.kind.isConditional || (command.place == nil && command.conditionalRule == nil) else {
            throw FixtureBackendError.invalidRequest("A policy command carries an unrelated place or rule.")
        }
        guard (command.kind == .setPermanentRemovalWait) == (command.waitSeconds != nil) else {
            throw FixtureBackendError.invalidRequest("Only a wait change carries a wait.")
        }
        switch command.kind {
        case .addRestriction:
            if let day = command.restriction, day.isGoDay {
                // Stronger, so it applies now; one running day at a time; it
                // starts after the undo window; no place is where you are now.
                guard command.schedule == nil, command.policyID == nil, command.effectiveAt == nil,
                      day.isWellFormedGoDay, day.goDay?.arrivedAt == nil, day.goDay?.placesAtStart.isEmpty == true,
                      let startsAt = day.startsAt,
                      (GoDayGate.undoWindow - 30...GoDayGate.undoWindow + 30).contains(startsAt.timeIntervalSince(now)),
                      (1...160).contains(day.title.count),
                      !restrictions.contains(where: { $0.policyID == day.policyID || $0.id == day.id ||
                          ($0.isGoDay && $0.goDay?.arrivedAt == nil) }),
                      !schedules.contains(where: { $0.id == day.policyID }) else {
                    throw FixtureBackendError.invalidRequest("A Go day needs places away from here, an end time, and no other Go day running.")
                }
                restrictions.append(day)
                break
            }
            guard let rule = command.restriction, command.schedule == nil,
                  command.policyID == nil, command.effectiveAt == nil,
                  rule.owner != .recurring, !rule.policyID.isEmpty, rule.policyID.count <= 128,
                  !rule.title.isEmpty, rule.title.count <= 160,
                  PolicyValidation.validTargets(domains: rule.domains, apps: rule.apps),
                  rule.startsAt.map({ $0 <= (rule.endsAt ?? .distantFuture) }) ?? true,
                  rule.endsAt.map({ $0 > now }) ?? true,
                  ((rule.owner != .permanent && rule.owner != .commitment) ||
                    rule.startsAt.map({ $0 <= now }) ?? true),
                  (rule.owner != .temporary || rule.endsAt != nil),
                  (rule.owner != .permanent || rule.endsAt == nil),
                  !restrictions.contains(where: { $0.policyID == rule.policyID || $0.id == rule.id }),
                  !schedules.contains(where: { $0.id == rule.policyID }),
                  rule.owner != .conditional, !ConditionalPolicy.isConditionalOwner(rule.policyID) else {
                throw FixtureBackendError.invalidRequest("Restriction is malformed or duplicates an owner.")
            }
            // A place block is an "until released" block that names an existing
            // place not on its way out.
            if let place = rule.placeID {
                guard rule.owner == .commitment, rule.endsAt == nil,
                      conditions.places.contains(where: { $0.id == place }),
                      !pending.contains(where: { $0.policyID == ConditionalPolicy.pendingID(place: place) }) else {
                    throw FixtureBackendError.invalidRequest("A place block needs an existing place that isn't being changed or removed, and no end date.")
                }
            }
            restrictions.append(rule)
        case .addSchedule:
            guard let schedule = command.schedule, command.restriction == nil,
                  command.policyID == nil, command.effectiveAt == nil,
                  schedule.isValid, schedule.isRequested, !schedule.id.isEmpty,
                  schedule.id.count <= 128, !schedule.title.isEmpty,
                  schedule.title.count <= 160,
                  PolicyValidation.validTargets(domains: schedule.domains, apps: schedule.apps),
                  !schedules.contains(where: { $0.id == schedule.id }),
                  !restrictions.contains(where: { $0.policyID == schedule.id }),
                  !ConditionalPolicy.isConditionalOwner(schedule.id) else {
                throw FixtureBackendError.invalidRequest("Schedule is malformed or duplicates an owner.")
            }
            schedules.append(schedule)
        case .strengthenSchedule:
            guard let schedule = command.schedule, command.restriction == nil,
                  command.policyID == nil, command.effectiveAt == nil,
                  !schedule.id.isEmpty, schedule.id.count <= 128,
                  !schedule.title.isEmpty, schedule.title.count <= 160,
                  PolicyValidation.validTargets(domains: schedule.domains, apps: schedule.apps),
                  let index = schedules.firstIndex(where: { $0.id == schedule.id }),
                  schedule != schedules[index],
                  schedule.isImmediateStrengthening(of: schedules[index]),
                  !pending.contains(where: { $0.policyID == schedule.id }) else {
                throw FixtureBackendError.invalidRequest("A committed schedule can change immediately only when every existing block remains covered.")
            }
            schedules[index] = schedule
        case .replaceScheduleAfterDelay:
            guard let schedule = command.schedule, command.restriction == nil,
                  command.policyID == nil, let date = command.effectiveAt,
                  date >= now.addingTimeInterval(86_400),
                  schedule.isValid, schedule.isRequested,
                  !schedule.title.isEmpty, schedule.title.count <= 160,
                  PolicyValidation.validTargets(domains: schedule.domains, apps: schedule.apps),
                  schedules.contains(where: { $0.id == schedule.id && $0 != schedule }),
                  !pending.contains(where: { $0.policyID == schedule.id }) else {
                throw FixtureBackendError.invalidRequest("Changing committed hours requires a valid schedule and at least 24 hours delay.")
            }
            pending.append(PendingPolicyRelease(policyID: schedule.id, effectiveAt: date,
                                                replacementSchedule: schedule))
        case .requestRelease:
            guard command.restriction == nil, command.schedule == nil,
                  let id = command.policyID, !id.isEmpty,
                  let effectiveAt = command.effectiveAt,
                  effectiveAt >= now.addingTimeInterval(86_400),
                  !pending.contains(where: { $0.policyID == id }) else {
                throw FixtureBackendError.invalidRequest("Release requires a unique policy and at least 24 hours delay.")
            }
            let rule = restrictions.first { $0.policyID == id }
            // A permanent block made under 1.1 can be removed after the
            // permanent wait; older ones stay never-removable.
            if let rule, rule.owner == .permanent {
                guard removal.isRemovable(rule) else {
                    throw FixtureBackendError.invalidRequest("This block was made never-removable.")
                }
                guard effectiveAt >= now.addingTimeInterval(removal.currentWait(at: now)) else {
                    throw FixtureBackendError.invalidRequest("Removing a permanent block waits its full removal time.")
                }
                pending.append(PendingPolicyRelease(policyID: id, effectiveAt: effectiveAt))
                break
            }
            // Timed blocks end on their own; a release request adds nothing.
            guard (rule?.owner == .commitment || schedules.contains(where: { $0.id == id })),
                  rule?.endsAt == nil else {
                throw FixtureBackendError.invalidRequest("Permanent and timed blocks can't be released by request.")
            }
            pending.append(PendingPolicyRelease(policyID: id, effectiveAt: effectiveAt))
        case .correctRecentPermanent:
            guard command.restriction == nil, command.schedule == nil,
                  let id = command.policyID, !id.isEmpty,
                  let effectiveAt = command.effectiveAt,
                  !pending.contains(where: { $0.policyID == id }),
                  let index = restrictions.firstIndex(where: { $0.policyID == id }),
                  restrictions[index].isCorrectablePermanent(at: now) else {
                throw FixtureBackendError.invalidRequest("Only a permanent block created in Shield within the last 72 hours can be corrected.")
            }
            // Corrections wait like any release. (An immediate path once let a
            // just-added, nearly-always-allowed schedule unblock a site at once.)
            guard effectiveAt >= now.addingTimeInterval(86_400) else {
                throw FixtureBackendError.invalidRequest("A correction waits at least 24 hours.")
            }
            // Shield 1.1: a removable block's correction waits the removal wait,
            // so it is never a shortcut around it.
            if removal.isRemovable(restrictions[index]) {
                guard effectiveAt >= now.addingTimeInterval(removal.currentWait(at: now)) else {
                    throw FixtureBackendError.invalidRequest("Removing a permanent block waits its full removal time.")
                }
            }
            restrictions[index] = restrictions[index].with(owner: .commitment)
            pending.append(PendingPolicyRelease(policyID: id, effectiveAt: effectiveAt, restoresPermanent: true))
        case .undoNewBlock:
            // `startsAt` is never later than when the service accepted the
            // rule, so this can't reach a block older than 10 minutes.
            guard command.restriction == nil, command.schedule == nil, command.effectiveAt == nil,
                  let id = command.policyID, !id.isEmpty,
                  let index = restrictions.firstIndex(where: { $0.policyID == id }),
                  removal.canUndo(restrictions[index], pending: pending, at: now) else {
                throw FixtureBackendError.invalidRequest("Only a block added in the last 10 minutes can be undone.")
            }
            restrictions.remove(at: index)
        case .setPermanentRemovalWait:
            guard command.restriction == nil, command.schedule == nil, command.effectiveAt == nil,
                  command.policyID == nil, let seconds = command.waitSeconds,
                  PermanentRemovalPolicy.validWait(seconds) else {
                throw FixtureBackendError.invalidRequest("The removal wait must be between 1 and 30 days.")
            }
            removal = removal.setting(seconds, at: now)
        case .requestUninstall:
            guard command.restriction == nil, command.schedule == nil, command.policyID == nil,
                  let date = command.effectiveAt, removal.uninstallAt == nil,
                  date >= now.addingTimeInterval(removal.uninstallWait(at: now)),
                  date <= now.addingTimeInterval(PermanentRemovalPolicy.maximumWait + 86_400) else {
                throw FixtureBackendError.invalidRequest("Removing Shield waits at least as long as removing a permanent block.")
            }
            guard !restrictions.contains(where: removal.blocksUninstall) else {
                throw FixtureBackendError.invalidRequest("Shield can't be removed while a never-removable block exists.")
            }
            removal = removal.uninstalling(at: date)
        case .cancelUninstall:
            guard command.restriction == nil, command.schedule == nil, command.policyID == nil,
                  command.effectiveAt == nil, removal.uninstallAt != nil else {
                throw FixtureBackendError.invalidRequest("Removing Shield wasn't requested.")
            }
            removal = removal.uninstalling(at: nil)
        case .withdrawGoDay:
            guard command.restriction == nil, command.schedule == nil, command.effectiveAt == nil,
                  let id = command.policyID,
                  let index = restrictions.firstIndex(where: { $0.policyID == id && $0.isGoDay }),
                  let startsAt = restrictions[index].startsAt, now < startsAt else {
                throw FixtureBackendError.invalidRequest("A Go day can only be undone in its first 2 minutes.")
            }
            restrictions.remove(at: index)
        case .cancelPendingRelease:
            guard command.restriction == nil, command.schedule == nil, command.effectiveAt == nil,
                  let id = command.policyID, !id.isEmpty,
                  let index = pending.firstIndex(where: { $0.policyID == id }) else {
                throw FixtureBackendError.invalidRequest("There is no pending change to cancel.")
            }
            // A Lock In's end is part of the lock: cancelling it would let the
            // schedule be removed 24 hours later instead of on its chosen date.
            guard !id.hasPrefix("lockin-") else {
                throw FixtureBackendError.invalidRequest("A Lock In can't be ended early.")
            }
            if pending[index].restoresPermanent == true,
               let ruleIndex = restrictions.firstIndex(where: { $0.policyID == id && $0.owner == .commitment }) {
                restrictions[ruleIndex] = restrictions[ruleIndex].with(owner: .permanent)
            }
            pending.remove(at: index)
        case .addPlace, .replacePlace:
            guard let place = command.place, command.restriction == nil, command.schedule == nil,
                  command.policyID == nil, RulePlaceValidator.wellFormed(place) else {
                throw FixtureBackendError.invalidRequest("The place is malformed.")
            }
            let index = conditions.places.firstIndex { $0.id == place.id }
            guard (command.kind == .addPlace) == (index == nil),
                  index.map({ conditions.places[$0] != place }) ?? true else {
                throw FixtureBackendError.invalidRequest("Add a new place, or change one that exists.")
            }
            let owner = ConditionalPolicy.pendingID(place: place.id)
            try requireNoPending(owner, in: pending)
            switch PlaceChangeClassifier.classify(old: index.map { conditions.places[$0] }, new: place) {
            case .immediate:
                try requireNoDelay(command)
                if let index { conditions.places[index] = place } else { conditions.places.append(place) }
            case .delayed:
                pending.append(PendingPolicyRelease(policyID: owner, effectiveAt: try requireDelay(command, now: now),
                                                    replacementPlace: place))
            }
        case .removePlace:
            guard command.restriction == nil, command.schedule == nil,
                  let id = command.policyID, let old = conditions.places.first(where: { $0.id == id }),
                  // Always delayed: "away from" rules may loosen when a place goes.
                  PlaceChangeClassifier.classify(old: old, new: nil) == .delayed else {
                throw FixtureBackendError.invalidRequest("There is no such place to remove.")
            }
            guard !restrictions.contains(where: { $0.placeID == id }) else {
                throw FixtureBackendError.invalidRequest("Release the blocks that use this place first.")
            }
            let owner = ConditionalPolicy.pendingID(place: id)
            try requireNoPending(owner, in: pending)
            pending.append(PendingPolicyRelease(policyID: owner, effectiveAt: try requireDelay(command, now: now)))
        case .addConditionalRule, .replaceConditionalRule:
            guard let requested = command.conditionalRule, command.restriction == nil, command.schedule == nil,
                  command.policyID == nil, RulePlaceValidator.wellFormed(requested) else {
                throw FixtureBackendError.invalidRequest("The rule is malformed.")
            }
            let index = conditions.rules.firstIndex { $0.id == requested.id }
            guard (command.kind == .addConditionalRule) == (index == nil),
                  index.map({ !conditions.rules[$0].sameContent(as: requested) }) ?? true else {
                throw FixtureBackendError.invalidRequest("Add a new rule, or change one that exists.")
            }
            let owner = ConditionalPolicy.pendingID(rule: requested.id)
            try requireNoPending(owner, in: pending)
            // The service, not the client, dates a rule: an exception's 24-hour
            // wait counts from the moment the service accepted it.
            let old = index.map { conditions.rules[$0] }
            let candidate = requested.committed(at: now)
            switch RuleChangeClassifier.classify(old: old, new: candidate) {
            case .immediate:
                try requireNoDelay(command)
                // A stronger edit keeps the original date, so a narrowed
                // exception that already waited 24 hours stays usable.
                let rule = requested.committed(at: old?.committedAt ?? now)
                if let index { conditions.rules[index] = rule } else { conditions.rules.append(rule) }
            case .delayed:
                pending.append(PendingPolicyRelease(policyID: owner, effectiveAt: try requireDelay(command, now: now),
                                                    replacementRule: candidate))
            }
        case .removeConditionalRule:
            guard command.restriction == nil, command.schedule == nil,
                  let id = command.policyID, let index = conditions.rules.firstIndex(where: { $0.id == id }) else {
                throw FixtureBackendError.invalidRequest("There is no such rule to remove.")
            }
            let owner = ConditionalPolicy.pendingID(rule: id)
            try requireNoPending(owner, in: pending)
            switch RuleChangeClassifier.classify(old: conditions.rules[index], new: nil) {
            case .immediate:
                try requireNoDelay(command)
                conditions.rules.remove(at: index)
            case .delayed:
                pending.append(PendingPolicyRelease(policyID: owner, effectiveAt: try requireDelay(command, now: now)))
            }
        }
    }

    private func requireNoPending(_ owner: String, in pending: [PendingPolicyRelease]) throws {
        guard !pending.contains(where: { $0.policyID == owner }) else {
            throw FixtureBackendError.invalidRequest("A change to this is already pending. Cancel it first.")
        }
    }

    private func requireNoDelay(_ command: BackendCommand) throws {
        guard command.effectiveAt == nil else {
            throw FixtureBackendError.invalidRequest("This change makes protection stronger, so it applies at once and takes no delay.")
        }
    }

    private func requireDelay(_ command: BackendCommand, now: Date) throws -> Date {
        guard let date = command.effectiveAt, date >= now.addingTimeInterval(86_400) else {
            throw FixtureBackendError.invalidRequest("This change can loosen protection, so it waits at least 24 hours.")
        }
        return date
    }

    private func commit(_ document: BackendDocument, requestID: UUID, now: Date,
                        calendar: Calendar, status: BackendAckStatus,
                        previous: BackendDocument? = nil) throws -> BackendAcknowledgment {
        let documentData = try encode(document)
        let rendered = try render(document, requestID: requestID, now: now, calendar: calendar)
        // The readers have bounded input sizes. Never commit a state that this
        // service cannot read back after a restart, including journal overhead.
        let previewJournal = SignedBackendJournal(documentData: documentData, requestID: requestID,
                                                   authenticationCode: Data(repeating: 0, count: 32))
        guard documentData.count <= StateFileLimits.maximumBytes,
              try encode(previewJournal).count <= StateFileLimits.maximumBytes,
              rendered.authority.count <= StateFileLimits.maximumBytes,
              rendered.hosts.count <= StateFileLimits.maximumHostsBytes else {
            throw FixtureBackendError.invalidRequest("The resulting policy exceeds durable storage limits.")
        }
        // The installed service reads the system hosts file back only up to
        // `StateFileLimits.maximumHostsBytes`. Every committed site may be blocked at once (all schedules on),
        // so that worst case must fit with room for the file's own lines, or a
        // later block edge could write a file the service can't read back.
        // A commit that adds no website to what was already committed (the
        // minute refresh, presence updates, releases) can't newly exceed it.
        let addsWebsites = previous.map {
            !Self.committedDomains(document).isSubset(of: Self.committedDomains($0))
        } ?? true
        guard try !addsWebsites || Self.worstCaseHostsSection(document).utf8.count <= Self.maximumHostsSectionBytes else {
            throw FixtureBackendError.invalidRequest(
                "That's more websites than Shield can block at once. Remove some, then try again.")
        }
        let key = try keyForCommit(bootstrap: document.generation == 1)
        let signature = authenticateBytes(documentData, key: key)
        let journal = SignedBackendJournal(documentData: documentData, requestID: requestID,
                                           authenticationCode: signature)
        try store.write(encode(journal), to: paths.journal)
        if fault == .afterJournal { throw FixtureBackendError.injectedInterruption }
        return try finish(journal, key: key, now: now, calendar: calendar,
                          status: status, rendered: rendered, document: document)
    }

    private func recoverLocked(now: Date, calendar: Calendar) throws -> BackendAcknowledgment {
        guard FileManager.default.fileExists(atPath: paths.journal.path) else {
            throw FixtureBackendError.uncertain("There is no pending transition to recover.")
        }
        let key = try readKey()
        let journal = try decode(SignedBackendJournal.self, at: paths.journal)
        let document = try PropertyListDecoder().decode(BackendDocument.self, from: journal.documentData)
        guard authenticateBytes(journal.documentData, key: key) == journal.authenticationCode,
              (1...BackendDocument.schemaVersion).contains(document.version),
              document.lastRequestID == journal.requestID,
              now.timeIntervalSinceReferenceDate.isFinite,
              document.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              now >= document.updatedAt else {
            throw FixtureBackendError.uncertain("The transition journal is invalid.")
        }
        if FileManager.default.fileExists(atPath: paths.document.path) {
            let committed = try loadDocument()
            let committedBytes = try store.read(paths.document)
            let sameGeneration = committed.generation == document.generation
            let nextGeneration = committed.generation < UInt64.max &&
                committed.generation + 1 == document.generation
            guard nextGeneration || (sameGeneration &&
                committedBytes == journal.documentData) else {
                throw FixtureBackendError.uncertain("A transition journal cannot replace or roll back committed state.")
            }
        } else if document.generation != 1 {
            throw FixtureBackendError.uncertain("A nonbootstrap journal has no committed predecessor.")
        }
        // First finish precisely the durable transition at its recorded time.
        // Re-evaluating a late recovery at `now` could generate an authority with
        // an already-due pending release, which the authority reader rejects.
        // Then catch up expiry/releases under the same lock as a separate durable
        // generation. A second interruption remains recoverable by the journal.
        _ = try finish(journal, key: key, now: document.updatedAt,
                       calendar: calendar, status: .recovered)
        let current = try tickLocked(now: now, calendar: calendar)
        return BackendAcknowledgment(version: 1, status: .recovered,
                                     receipt: current.receipt, nextTransition: current.nextTransition)
    }

    private func render(_ document: BackendDocument, requestID: UUID, now: Date,
                        calendar: Calendar) throws -> RenderedState {
        let evaluated = UnifiedPolicyEngine().evaluate(restrictions: document.restrictions,
                                                      schedules: document.schedules,
                                                      at: now, calendar: Self.zoned(calendar, document.scheduleZone, at: now),
                                                      conditions: document.conditions)
        let recurring = evaluated.restrictions.map { rule -> DomainRestriction in
            guard rule.owner == .recurring || rule.owner == .conditional else { return rule }
            return DomainRestriction(id: stableID(for: rule.policyID), owner: rule.owner,
                                     policyID: rule.policyID, title: rule.title,
                                     domains: rule.domains, apps: rule.apps)
        }
        let commitments = document.restrictions.filter { $0.owner == .commitment }.map { rule in
            PolicyCommitment(id: rule.policyID, title: rule.title, domains: rule.domains,
                             // A place block counts as active only while it's applied.
                             committed: true, active: rule.isEffective(at: now) &&
                                (rule.placeID == nil || evaluated.restrictions.contains { $0.policyID == rule.policyID }),
                             activeUntil: rule.endsAt,
                             pendingDisableEffectiveAt: document.pendingReleases
                                .first(where: { $0.policyID == rule.policyID })?.effectiveAt)
        }
        let conditions = document.conditions.map { conditions in
            ConditionalAuthorityState(places: conditions.places, rules: conditions.rules,
                                      presence: conditions.presence,
                                      openedBy: evaluated.conditional?.openedBy ?? [:],
                                      tightenedBy: evaluated.conditional?.tightenedBy ?? [:])
        }
        let authority = AuthorityState(schemaVersion: AuthorityState.schemaVersion(for: conditions),
                                       generation: document.generation,
                                       generatedAt: now, reconciliationID: requestID,
                                       lastSuccessfulReconciliation: now,
                                       commitments: commitments,
                                       effectiveRestrictions: recurring, conditions: conditions)
        let authorityData = try encode(authority)
        let originalBytes = try store.read(paths.hosts)
        let hostsData: Data
        // Most commits (minute refresh, presence) block the same websites as
        // the last one: the same input file and set render the same output.
        if let previous = readCache.renderedHosts.lookup(originalBytes), previous.domains == evaluated.domains {
            hostsData = previous.hosts
        } else {
            let original = try String(data: originalBytes, encoding: .utf8)
                .unwrap(or: FixtureBackendError.uncertain("Fixture hosts is not valid UTF-8."))
            let rendered = try ManagedHostsDocument().replacingManagedSection(in: original,
                                                                               domains: evaluated.domains)
            hostsData = Data(rendered.utf8)
            readCache.renderedHosts.store(originalBytes, (evaluated.domains, hostsData))
        }
        return RenderedState(authority: authorityData, hosts: hostsData, state: authority)
    }

    /// Room for Shield's section of the system hosts file: about 50,000
    /// websites (was 900 KB, about 9,000). Measured at 50,000: a
    /// re-commit takes about 0.75 s and the service averages under 1% of one
    /// core (about 2% while location rules commit every minute). The reader's limit
    /// (`StateFileLimits.maximumHostsBytes`) leaves plenty for the file's own
    /// lines. Note an older service can't read state over 1 MiB, so going back
    /// to one needs the lists made smaller first.
    static let maximumHostsSectionBytes = 6_000_000

    /// Shield's hosts section if every committed site were blocked at once.
    static func worstCaseHostsSection(_ document: BackendDocument) throws -> String {
        try ManagedHostsDocument().replacingManagedSection(in: "", domains: committedDomains(document))
    }

    /// Every website the document could ever block: all owners, schedules,
    /// waiting replacements and rules.
    static func committedDomains(_ document: BackendDocument) -> Set<String> {
        var domains = Set<String>()
        for rule in document.restrictions { domains.formUnion(rule.domains) }
        for schedule in document.schedules { domains.formUnion(schedule.domains) }
        for release in document.pendingReleases {
            domains.formUnion(release.replacementSchedule?.domains ?? [])
            domains.formUnion(release.replacementRule?.domains ?? [])
        }
        for rule in document.conditions?.rules ?? [] { domains.formUnion(rule.domains) }
        return domains
    }

    private func finish(_ journal: SignedBackendJournal, key: Data, now: Date,
                        calendar: Calendar, status: BackendAckStatus,
                        rendered: RenderedState? = nil,
                        document committed: BackendDocument? = nil) throws -> BackendAcknowledgment {
        // commit() passes the document it just encoded into the journal; recovery decodes it.
        let document = try committed ?? PropertyListDecoder().decode(BackendDocument.self, from: journal.documentData)
        let artifacts = try rendered ?? render(document, requestID: journal.requestID,
                                               now: now, calendar: calendar)
        let authorityData = artifacts.authority
        let hostsData = artifacts.hosts
        guard journal.documentData.count <= StateFileLimits.maximumBytes,
              authorityData.count <= StateFileLimits.maximumBytes,
              hostsData.count <= StateFileLimits.maximumHostsBytes else {
            throw FixtureBackendError.uncertain("The transition exceeds durable storage limits; its journal is preserved.")
        }
        try store.write(hostsData, to: paths.hosts)
        if fault == .afterHosts { throw FixtureBackendError.injectedInterruption }
        try store.write(journal.documentData, to: paths.document)
        try store.write(authorityData, to: paths.authority)
        let payload = BackendReceiptPayload(version: 1, requestID: journal.requestID,
                                            generation: document.generation, appliedAt: now,
                                            authorityDigest: digest(authorityData),
                                            hostsDigest: digest(hostsData),
                                            documentDigest: digest(journal.documentData))
        let receipt = BackendReceipt(payload: payload,
                                     authenticationCode: try authenticate(payload, key: key))
        try store.write(encode(receipt), to: paths.receipt)
        // What was just written is already known: reuse it on the next read
        // instead of decoding it back. Each value passes the same checks a
        // read would apply; a later change to any file misses and decodes.
        if committed != nil, Self.isWellFormed(document) {
            readCache.document.store(journal.documentData, document)
            if case .success(let structure) = AuthorityStateReader.structure(of: artifacts.state) {
                readCache.authority.store(authorityData, structure)
            }
        }
        try store.remove(paths.journal)
        return BackendAcknowledgment(version: 1, status: status, receipt: receipt,
                                     nextTransition: nextTransition(in: document, at: now,
                                                                    calendar: calendar))
    }

    /// The committed document, checked against the receipt and authority.
    private func loadVerifiedDocument(now: Date, calendar: Calendar) throws -> BackendDocument {
        let (document, bytes) = try loadDocumentAndBytes()
        try verifyCommittedDocument(document, bytes: bytes, now: now, calendar: calendar)
        return document
    }

    private func verifyCommittedDocument(_ document: BackendDocument, bytes documentBytes: Data, now: Date,
                                         calendar: Calendar) throws {
        let receipt = try verifiedReceipt()
        let (authority, authorityBytes) = AuthorityStateReader(fileURL: paths.authority, maximumAge: .infinity,
                                                               cache: readCache.authority).readWithBytes(now: now)
        guard case .valid(let state) = authority,
              document.generation == state.generation,
              receipt.payload.generation == document.generation,
              receipt.payload.requestID == document.lastRequestID else {
            throw FixtureBackendError.uncertain("Committed document, authority, and receipt disagree.")
        }
        if let authorityBytes, readCache.agreement.contains(document: documentBytes, authority: authorityBytes,
                                                            calendar: calendar) {
            return
        }
        // Replays with the stored presence record, so a committed conditional
        // decision verifies exactly, however old the record is now.
        let expected = UnifiedPolicyEngine().evaluate(restrictions: document.restrictions,
                                                     schedules: document.schedules,
                                                     at: state.generatedAt,
                                                     calendar: Self.zoned(calendar, document.scheduleZone,
                                                                          at: state.generatedAt),
                                                     conditions: document.conditions)
        let observed = state.effectiveRestrictions.reduce(into: Set<String>()) { $0.formUnion($1.domains) }
        let observedApps = state.effectiveRestrictions.reduce(into: Set<AppTarget>()) { $0.formUnion($1.apps) }
        guard expected.domains == observed, expected.apps == observedApps else {
            throw FixtureBackendError.uncertain("Authority does not match its committed policy owners.")
        }
        if let authorityBytes {
            readCache.agreement.store(document: documentBytes, authority: authorityBytes, calendar: calendar)
        }
    }

    private func nextTransition(in document: BackendDocument, at now: Date,
                                calendar: Calendar) -> Date? {
        let engine = UnifiedPolicyEngine().nextTransition(restrictions: document.restrictions,
                                                          schedules: document.schedules,
                                                          at: now, calendar: Self.zoned(calendar, document.scheduleZone, at: now),
                                                          conditions: document.conditions)
        return Self.nextTransition(engine, pending: document.pendingReleases, after: now, zone: document.scheduleZone)
    }

    private static func nextTransition(_ engine: Date?, pending: [PendingPolicyRelease], after now: Date,
                                       zone: ScheduleZone? = nil) -> Date? {
        ([engine, zone?.pendingAt] + pending.map { Optional($0.effectiveAt) })
            .compactMap { $0 }.filter { $0 > now }.min()
    }

    /// The calendar schedules run in for this document at `date`.
    static func zoned(_ calendar: Calendar, _ zone: ScheduleZone?, at date: Date) -> Calendar {
        guard let id = zone?.settled(at: date).identifier, id != calendar.timeZone.identifier,
              let timeZone = TimeZone(identifier: id) else { return calendar }
        var zoned = calendar
        zoned.timeZone = timeZone
        return zoned
    }

    /// The zone to commit next: due changes landed and what the service sees
    /// of this Mac applied. Nil while it is still the installed zone.
    private func observedZone(_ zone: ScheduleZone?, base: Calendar, now: Date) -> ScheduleZone? {
        let settled = zone?.settled(at: now)
        guard let seen = observeZone?() else { return settled }
        let start = settled ?? ScheduleZone(identifier: base.timeZone.identifier)
        let next = start.observing(seen, at: now)
        return settled == nil && next == start ? nil : next
    }

    /// True when the zone the service sees means the next pass must commit.
    func observesZoneChange(in snapshot: BackendSnapshot, calendar: Calendar, now: Date) -> Bool {
        observeZone != nil && observedZone(snapshot.scheduleZone, base: calendar, now: now) != snapshot.scheduleZone
    }

    private func loadDocument() throws -> BackendDocument { try loadDocumentAndBytes().document }

    private func loadDocumentAndBytes() throws -> (document: BackendDocument, bytes: Data) {
        let data = try store.read(paths.document)
        if let cached = readCache.document.lookup(data) { return (cached, data) }
        let document = try decode(BackendDocument.self, from: data)
        guard Self.isWellFormed(document) else {
            throw FixtureBackendError.uncertain("Committed backend document is malformed.")
        }
        readCache.document.store(data, document)
        return (document, data)
    }

    /// The checks every committed document must pass when it is read back.
    static func isWellFormed(_ document: BackendDocument) -> Bool {
        guard (1...BackendDocument.schemaVersion).contains(document.version), document.generation > 0,
              document.version >= BackendDocument.version(restrictions: document.restrictions,
                  schedules: document.schedules, pendingReleases: document.pendingReleases,
                  conditions: document.conditions, permanentRemoval: document.permanentRemoval),
              document.permanentRemoval?.isWellFormed ?? true, document.scheduleZone?.isWellFormed ?? true,
              Set(document.restrictions.map(\.policyID)).count == document.restrictions.count,
              document.restrictions.allSatisfy({ $0.placeID == nil || (document.version >= 4 && $0.owner == .commitment) }),
              document.restrictions.allSatisfy({ !$0.isGoDay || (document.version >= 5 && $0.isWellFormedGoDay) }),
              Set(document.schedules.map(\.id)).count == document.schedules.count,
              Set(document.pendingReleases.map(\.policyID)).count == document.pendingReleases.count,
              document.conditions.map({ conditions in
                  document.version >= 4 && !conditions.isEmpty &&
                      RulePlaceValidator.isStructurallyValid(places: conditions.places, rules: conditions.rules)
              }) ?? true,
              document.pendingReleases.allSatisfy({ release in
                  if ConditionalPolicy.isConditionalOwner(release.policyID) {
                      guard document.version >= 4, release.replacementSchedule == nil,
                            release.restoresPermanent == nil else { return false }
                      let conditions = document.conditions ?? .empty
                      if release.policyID.hasPrefix(ConditionalPolicy.placePrefix) {
                          let id = String(release.policyID.dropFirst(ConditionalPolicy.placePrefix.count))
                          guard release.replacementRule == nil else { return false }
                          if let place = release.replacementPlace {
                              return place.id == id && RulePlaceValidator.wellFormed(place)
                          }
                          return conditions.places.contains { $0.id == id }
                      }
                      let id = String(release.policyID.dropFirst(ConditionalPolicy.rulePrefix.count))
                      guard release.replacementPlace == nil else { return false }
                      if let rule = release.replacementRule {
                          return rule.id == id && RulePlaceValidator.wellFormed(rule)
                      }
                      return conditions.rules.contains { $0.id == id }
                  }
                  guard release.replacementPlace == nil, release.replacementRule == nil else { return false }
                  if let replacement = release.replacementSchedule {
                      return document.version >= 2 && replacement.id == release.policyID && replacement.isValid &&
                          replacement.isRequested && (!replacement.domains.isEmpty || !replacement.apps.isEmpty) &&
                          document.schedules.contains { $0.id == release.policyID }
                  }
                  return document.restrictions.contains { $0.policyID == release.policyID && $0.owner == .commitment } ||
                      document.schedules.contains { $0.id == release.policyID } ||
                      (release.restoresPermanent == nil && document.permanentRemoval.map { removal in
                          document.restrictions.contains { $0.policyID == release.policyID && removal.isRemovable($0) }
                      } ?? false)
              }) else { return false }
        return true
    }

    private func decode<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        try decode(type, from: store.read(url))
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard !data.isEmpty, data.count <= StateFileLimits.maximumBytes else {
            throw FixtureBackendError.uncertain("A backend artifact is empty or oversized.")
        }
        do { return try PropertyListDecoder().decode(type, from: data) }
        catch { throw FixtureBackendError.uncertain("A backend artifact is malformed.") }
    }

    private func keyForCommit(bootstrap: Bool) throws -> Data {
        if FileManager.default.fileExists(atPath: paths.key.path) { return try readKey() }
        guard bootstrap else { throw FixtureBackendError.uncertain("Receipt key is missing.") }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try store.write(key, to: paths.key)
        return key
    }

    private func readKey() throws -> Data {
        var info = stat()
        guard lstat(paths.key.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (info.st_mode & 0o077) == 0,
              info.st_uid == geteuid() else {
            throw FixtureBackendError.uncertain("Receipt key ownership or permissions are invalid.")
        }
        let key = try store.read(paths.key)
        guard key.count == 32 else { throw FixtureBackendError.uncertain("Receipt key length is invalid.") }
        return key
    }

    private func authenticate<T: Encodable>(_ value: T, key: Data) throws -> Data {
        let encoded = try encode(value)
        return authenticateBytes(encoded, key: key)
    }

    private func authenticateBytes(_ bytes: Data, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: key)))
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    private func stableID(for policyID: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(policyID.utf8)).prefix(16))
        let tuple: uuid_t = (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                             bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
        return UUID(uuid: tuple)
    }
}

// In-memory presence state for one service run: the report gate and the dwell
// tracker. Never persisted. The service calls `forgetPresence` at start, so a
// verdict from a previous run never lifts a place block.
final class PresenceSession: @unchecked Sendable {
    let bootSessionID: String
    private let lock = NSLock()
    private var gate = PresenceReportGate()
    private var tracker = PresenceTracker()
    private var arrivals = GoDayConfirmation()

    init(bootSessionID: String = PresenceSession.currentBootSessionID()) {
        self.bootSessionID = bootSessionID
    }

    /// The kernel's per-boot identifier; the app reads the same value.
    static func currentBootSessionID() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func judge(_ report: PresenceReport, places: [RulePlace], now: Date,
               calendar: Calendar) -> Result<PresenceSnapshot, PresenceReportGate.Rejection> {
        judge(report, places: places, goDays: [], now: now, calendar: calendar).map { $0.0 }
    }

    /// Also the running Go days this report confirms as arrived.
    func judge(_ report: PresenceReport, places: [RulePlace], goDays: [DomainRestriction], now: Date,
               calendar: Calendar) -> Result<(PresenceSnapshot, Set<String>), PresenceReportGate.Rejection> {
        lock.lock()
        defer { lock.unlock() }
        // An unknown boot session can never match, so every report is refused.
        guard !bootSessionID.isEmpty else { return .failure(.notCurrent) }
        switch gate.accept(report, serviceBootSessionID: bootSessionID, now: now) {
        case .failure(let rejection):
            tracker.interrupt()
            arrivals.interrupt()
            return .failure(rejection)
        case .success(let evidence):
            tracker.observe(evidence, places: places, now: now, calendar: calendar)
            let arrived = arrivals.observe(evidence, uptime: report.uptimeNanoseconds, days: goDays, now: now)
            return .success((.capture(evidence: evidence, places: places, tracker: tracker,
                                      studyMinutesToday: nil, now: now), arrived))
        }
    }
}

private extension Optional {
    func unwrap(or error: Error) throws -> Wrapped {
        guard let value = self else { throw error }
        return value
    }
}
