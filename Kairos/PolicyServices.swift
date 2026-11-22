import Darwin
import Foundation

protocol AuthorityStateReading: Sendable {
    func read(now: Date) -> AuthorityStatus
}

/// Size limits for the service's state files, shared by every writer and
/// reader so a committed state can always be read back. Sized for big block
/// lists (tens of thousands of websites); see `FixtureBackend.maximumHostsSectionBytes`.
enum StateFileLimits {
    /// The authority, the committed document and its journal.
    static let maximumBytes = 16 * 1_048_576
    /// A rendered hosts file (Shield's section plus the file's own lines).
    static let maximumHostsBytes = 24 * 1_048_576
}

/// The last decoded value of one file's exact bytes. Decoding is a pure
/// function of the bytes, so the same bytes always give the same value; any
/// change in content (even with the same size and times) misses and decodes
/// again. Only checked, successful decodes are stored. Lets the service keep
/// big block lists without re-decoding them on every pass.
final class DecodedBytesCache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var entry: (bytes: Data, value: Value)?

    init() {}

    func lookup(_ bytes: Data) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, entry.bytes == bytes else { return nil }
        return entry.value
    }

    func store(_ bytes: Data, _ value: Value) {
        lock.lock()
        entry = (bytes, value)
        lock.unlock()
    }
}

struct AuthorityStateReader: AuthorityStateReading {
    let fileURL: URL
    let maximumAge: TimeInterval
    /// Checks that depend only on the file's bytes, kept per exact content.
    let cache: DecodedBytesCache<AuthorityStructure>?

    /// The decoded authority, plus the result of the byte-only checks that
    /// come after the time checks (so failures report in the original order).
    struct AuthorityStructure {
        let state: AuthorityState
        let laterFailure: AuthorityStatus?
    }

    init(
        fileURL: URL = ShieldRuntime.authorityURL,
        maximumAge: TimeInterval = 5 * 60,
        cache: DecodedBytesCache<AuthorityStructure>? = nil
    ) {
        self.fileURL = fileURL
        self.maximumAge = maximumAge
        self.cache = cache
    }

    func read(now: Date = .now) -> AuthorityStatus { readWithBytes(now: now).status }

    /// The status, and the exact bytes it was read from (nil if none were read).
    func readWithBytes(now: Date = .now) -> (status: AuthorityStatus, bytes: Data?) {
        guard ShieldRuntime.permitsStateRead(from: fileURL) else {
            return (.unavailable(.unreadable("UI review cannot read external policy state.")), nil)
        }
        let data: Data
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            return (.unavailable(errno == ENOENT ? .missing : .unreadable("Cannot open a regular authority file.")), nil)
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (metadata.st_mode & 0o022) == 0,
              (fileURL.path != "/usr/local/etc/kairos-policy-state.plist" || metadata.st_uid == 0),
              metadata.st_size <= StateFileLimits.maximumBytes else {
            return (.unavailable(.unreadable("Authority ownership, permissions, type, or size are unsafe.")), nil)
        }
        do {
            data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                .read(upToCount: StateFileLimits.maximumBytes + 1) ?? Data()
        } catch {
            return (.unavailable(.unreadable(error.localizedDescription)), nil)
        }

        guard !data.isEmpty else {
            return (.unavailable(.empty), data)
        }
        guard data.count <= StateFileLimits.maximumBytes else {
            return (.unavailable(.unreadable("Authority exceeds its size limit.")), data)
        }

        let structure: AuthorityStructure
        if let cached = cache?.lookup(data) {
            structure = cached
        } else {
            switch Self.structure(of: data) {
            case .success(let decoded):
                structure = decoded
                cache?.store(data, decoded)
            case .failure(let failure):
                return (failure.status, data)
            }
        }
        let state = structure.state
        guard state.generatedAt <= now.addingTimeInterval(30) else {
            return (.unavailable(.incomplete("generatedAt is in the future")), data)
        }
        guard now.timeIntervalSince(state.generatedAt) <= maximumAge else {
            return (.unavailable(.stale(generatedAt: state.generatedAt)), data)
        }
        if let failure = structure.laterFailure { return (failure, data) }
        return (.valid(state), data)
    }

    struct StructureFailure: Error { let status: AuthorityStatus }

    /// Every check that depends only on the bytes, in the original order: the
    /// ones before the time checks fail at once; the ones after are kept as
    /// `laterFailure`, so they still report only once the time checks pass.
    private static func structure(of data: Data) -> Result<AuthorityStructure, StructureFailure> {
        func fail(_ status: AuthorityStatus) -> Result<AuthorityStructure, StructureFailure> {
            .failure(StructureFailure(status: status))
        }
        // The installed legacy backend used a different plist shape. A parseable
        // unversioned document is explicitly unsupported; migration requires
        // independent evidence of every commitment and must never guess.
        if let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dictionary = object as? [String: Any], dictionary["schemaVersion"] == nil {
            return fail(.unavailable(.unsupportedSchema(0)))
        }

        let state: AuthorityState
        do {
            state = try PropertyListDecoder().decode(AuthorityState.self, from: data)
        } catch {
            return fail(.unavailable(.malformed(error.localizedDescription)))
        }
        return structure(of: state)
    }

    /// The byte-independent checks on a decoded (or just-written) authority.
    static func structure(of state: AuthorityState) -> Result<AuthorityStructure, StructureFailure> {
        func fail(_ status: AuthorityStatus) -> Result<AuthorityStructure, StructureFailure> {
            .failure(StructureFailure(status: status))
        }
        guard AuthorityState.supportedSchemaVersions.contains(state.schemaVersion),
              state.schemaVersion >= 2 || state.conditions == nil else {
            return fail(.unavailable(.unsupportedSchema(state.schemaVersion)))
        }
        if let conditions = state.conditions {
            guard RulePlaceValidator.isStructurallyValid(places: conditions.places, rules: conditions.rules) else {
                return fail(.unavailable(.incomplete("invalid conditional rules")))
            }
        }
        guard state.generation > 0 else {
            return fail(.unavailable(.incomplete("generation")))
        }
        // (The two time checks run here, in read(now:).)
        func later(_ status: AuthorityStatus) -> Result<AuthorityStructure, StructureFailure> {
            .success(AuthorityStructure(state: state, laterFailure: status))
        }
        guard state.lastSuccessfulReconciliation <= state.generatedAt else {
            return later(.unavailable(.incomplete("lastSuccessfulReconciliation")))
        }
        guard Set(state.commitments.map(\.id)).count == state.commitments.count else {
            return later(.unavailable(.incomplete("duplicate commitment identifiers")))
        }
        guard Set(state.effectiveRestrictions.map(\.id)).count == state.effectiveRestrictions.count else {
            return later(.unavailable(.incomplete("duplicate restriction identifiers")))
        }
        for restriction in state.effectiveRestrictions {
            guard !restriction.policyID.isEmpty, !restriction.title.isEmpty,
                  // Only a well-formed Go day may name every web browser.
                  restriction.isGoDay ? restriction.isWellFormedGoDay :
                    PolicyValidation.validTargets(domains: restriction.domains, apps: restriction.apps),
                  restriction.startsAt.map({ $0 <= state.generatedAt }) ?? true,
                  restriction.endsAt.map({ state.generatedAt < $0 }) ?? true else {
                return later(.unavailable(.incomplete("invalid effective restriction")))
            }
        }
        for commitment in state.commitments {
            guard !commitment.id.isEmpty,
                  commitment.domains.allSatisfy(PolicyValidation.validDomain),
                  commitment.pendingDisableEffectiveAt.map({ $0 > state.generatedAt }) ?? true else {
                return later(.unavailable(.incomplete("invalid commitment")))
            }
        }
        return .success(AuthorityStructure(state: state, laterFailure: nil))
    }
}

protocol PolicyRequestStoring: Sendable {
    func load() throws -> PolicyRequest
    func save(_ request: PolicyRequest) throws
}

struct PolicyRequestStore: PolicyRequestStoring {
    let fileURL: URL

    init(fileURL: URL = KairosConfig.fileURL) {
        self.fileURL = fileURL
    }

    func load() throws -> PolicyRequest {
        try ShieldRuntime.requireIsolatedStateRead(from: fileURL)
        // A genuinely absent choice file is a first-run state, not corruption
        // or a loss of root authority. Never treat an existing empty, corrupt,
        // symlinked or inaccessible file as permission to reset choices.
        var metadata = stat()
        if lstat(fileURL.path, &metadata) != 0 {
            guard errno == ENOENT else { throw CocoaError(.fileReadNoPermission) }
            return PolicyRequest(youtubeEnabled: false, socialEnabled: true)
        }
        let data = try AtomicFixtureStore(allowedRoot: fileURL.deletingLastPathComponent()).read(fileURL)
        guard data.count <= 1_048_576 else { throw CocoaError(.propertyListReadCorrupt) }
        let dictionary = try PropertyListSerialization.propertyList(
            from: data,
            format: nil
        ) as? [String: Any]

        guard let dictionary else {
            throw CocoaError(.propertyListReadCorrupt)
        }

        guard let schema = dictionary["SchemaVersion"] as? Int,
              schema == PolicyRequest.currentSchemaVersion,
              let youtube = dictionary["YouTubeEnabled"] as? Bool,
              let social = dictionary["SocialEnabled"] as? Bool,
              let updatedAt = dictionary["UpdatedAt"] as? Date else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let windows = PolicyRequest.defaultWindowMinutes.mapValues { $0 }
        var loaded = windows
        for key in windows.keys {
            if let value = dictionary[key] as? Int { loaded[key] = value }
        }
        guard loaded.values.allSatisfy({ (0..<1_440).contains($0) }),
              loaded["YouTubeStartMinutes"] != loaded["YouTubeEndMinutes"],
              loaded["SocialMorningStartMinutes"] != loaded["SocialMorningEndMinutes"],
              loaded["SocialNightStartMinutes"] != loaded["SocialNightEndMinutes"] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return PolicyRequest(youtubeEnabled: youtube, socialEnabled: social,
                             updatedAt: updatedAt, windowMinutes: loaded)
    }

    func save(_ request: PolicyRequest) throws {
        try ShieldRuntime.requireIsolatedWrite(to: fileURL)
        guard request.schemaVersion == PolicyRequest.currentSchemaVersion else {
            throw CocoaError(.propertyListWriteInvalid)
        }
        guard Set(request.windowMinutes.keys) == Set(PolicyRequest.defaultWindowMinutes.keys),
              request.windowMinutes.values.allSatisfy({ (0..<1_440).contains($0) }),
              request.windowMinutes["YouTubeStartMinutes"] != request.windowMinutes["YouTubeEndMinutes"],
              request.windowMinutes["SocialMorningStartMinutes"] != request.windowMinutes["SocialMorningEndMinutes"],
              request.windowMinutes["SocialNightStartMinutes"] != request.windowMinutes["SocialNightEndMinutes"] else {
            throw CocoaError(.propertyListWriteInvalid)
        }
        var dictionary: [String: Any] = [
            "SchemaVersion": request.schemaVersion,
            "YouTubeEnabled": request.youtubeEnabled,
            "SocialEnabled": request.socialEnabled,
            "UpdatedAt": request.updatedAt
        ]
        for (key, value) in request.windowMinutes { dictionary[key] = value }
        let data = try PropertyListSerialization.data(
            fromPropertyList: dictionary, format: .xml, options: 0
        )
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try AtomicFixtureStore(allowedRoot: directory).write(data, to: fileURL)
    }
}

protocol EnforcementStateReading: Sendable {
    func read() -> Result<EnforcementSnapshot, Error>
}

struct HostsEnforcementReader: EnforcementStateReading {
    let fileURL: URL
    let beginMarker: String
    let endMarker: String

    init(fileURL: URL = ShieldRuntime.hostsURL,
         beginMarker: String = "# BEGIN KAIROS", endMarker: String = "# END KAIROS") {
        self.fileURL = fileURL
        self.beginMarker = beginMarker
        self.endMarker = endMarker
    }

    /// Parsed managed sections, kept per exact file content.
    var cache: DecodedBytesCache<(domains: Set<String>, managedSectionPresent: Bool)>? = nil

    func read() -> Result<EnforcementSnapshot, Error> {
        do {
            try ShieldRuntime.requireIsolatedStateRead(from: fileURL)
            let bytes = try Data(contentsOf: fileURL)
            let parsed: (domains: Set<String>, managedSectionPresent: Bool)
            if let cached = cache?.lookup(bytes) {
                parsed = cached
            } else {
                guard let text = String(data: bytes, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                parsed = try parse(text)
                cache?.store(bytes, parsed)
            }
            return .success(
                EnforcementSnapshot(
                    observedAt: .now,
                    blockedDomains: parsed.domains,
                    managedSectionPresent: parsed.managedSectionPresent
                )
            )
        } catch {
            return .failure(error)
        }
    }

    func parse(_ text: String) throws -> (domains: Set<String>, managedSectionPresent: Bool) {
        var insideManagedSection = false
        var sawBegin = false
        var sawEnd = false
        var domains = Set<String>()

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == beginMarker {
                guard !sawBegin, !sawEnd else { throw ReconciliationError.unmanagedHostsMarkers }
                insideManagedSection = true
                sawBegin = true
                continue
            }
            if line == endMarker {
                guard insideManagedSection, !sawEnd else { throw ReconciliationError.unmanagedHostsMarkers }
                insideManagedSection = false
                sawEnd = true
                continue
            }
            guard insideManagedSection, !line.hasPrefix("#") else { continue }

            let fields = line.split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 2 else { continue }
            let address = String(fields[0])
            guard address == "0.0.0.0" || address == "127.0.0.1" || address == "::1" else {
                continue
            }
            for domain in fields.dropFirst() {
                let value = String(domain)
                guard PolicyValidation.validDomain(value) else {
                    throw ReconciliationError.invalidRequest("Invalid managed hosts domain.")
                }
                domains.insert(value)
            }
        }

        guard sawBegin == sawEnd else { throw ReconciliationError.unmanagedHostsMarkers }

        return (domains, sawBegin && sawEnd)
    }
}

struct BackendInstallationInspector {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func inspect(authority: AuthorityStatus, enforcement: EvidenceState) -> BackendHealth {
        if ShieldRuntime.isDevelopment {
            return BackendHealth(authority: authority, enforcement: enforcement,
                                 reconcilerPresent: false, schedulerDefinitionPresent: false)
        }
        // The installed V1 service owns both reconciliation and recurring
        // transitions. Never report missing V0 executables as V1 failures.
        if ShieldRuntime.serviceName == "com.kairos.ShieldAuthority" {
            return BackendHealth(
                authority: authority,
                enforcement: enforcement,
                reconcilerPresent: fileManager.isExecutableFile(
                    atPath: "/Library/PrivilegedHelperTools/com.kairos.ShieldAuthority"),
                schedulerDefinitionPresent: fileManager.fileExists(
                    atPath: "/Library/LaunchDaemons/com.kairos.ShieldAuthority.plist")
            )
        }
        return BackendHealth(
            authority: authority,
            enforcement: enforcement,
            reconcilerPresent: fileManager.isExecutableFile(
                atPath: "/usr/local/libexec/kairos-reconcile"),
            schedulerDefinitionPresent: fileManager.fileExists(
                atPath: "/Library/LaunchDaemons/com.kairos.scheduler.plist")
        )
    }
}

struct UnifiedPolicyEngine: Sendable {
    /// The base policy (restrictions ∪ requested schedules), then conditional
    /// rules on top. Rules may add blocks; an allow rule may only remove a
    /// domain that is blocked solely by a daily schedule. Every other owner
    /// (permanent, Until released, timed) is never relaxable, and the stored
    /// schedule windows themselves are never changed.
    func evaluate(
        restrictions: [DomainRestriction],
        schedules: [DailySchedule],
        at date: Date,
        calendar: Calendar,
        conditions: ConditionalPolicy?
    ) -> EffectivePolicy {
        // A block limited to a place applies while Shield sees this Mac there,
        // and whenever it can't tell (unknown location is the strict reading).
        let context = RuleContext(now: date, calendar: calendar, places: conditions?.places ?? [],
                                  snapshot: conditions?.presence)
        let located = Self.located(restrictions, context: context)
        var base = evaluate(restrictions: located, schedules: schedules, at: date, calendar: calendar)
        base.nextTransition = Self.withPresenceExpiry(base.nextTransition, restrictions: restrictions,
                                                      conditions: conditions, at: date)
        guard let conditions, !conditions.rules.isEmpty else { return base }
        let neverRelaxable = base.restrictions.filter { $0.owner != .recurring }
            .reduce(into: Set<String>()) { $0.formUnion($1.domains.map { $0.lowercased() }) }
        let decision = ConditionalRuleEngine.evaluate(baseBlocked: base.domains, neverRelaxable: neverRelaxable,
                                                      rules: conditions.rules, context: context)
        let opened = Set(decision.openedBy.keys)
        var active = base.restrictions.compactMap { rule -> DomainRestriction? in
            guard rule.owner == .recurring, !rule.domains.isDisjoint(with: opened) else { return rule }
            let remaining = rule.domains.subtracting(opened)
            // Apps stay: conditional rules open sites only.
            return remaining.isEmpty && rule.apps.isEmpty ? nil :
                DomainRestriction(id: rule.id, owner: rule.owner, policyID: rule.policyID, title: rule.title,
                                  domains: remaining, apps: rule.apps)
        }
        let tightened = Dictionary(grouping: decision.tightenedBy.keys, by: { decision.tightenedBy[$0]! })
        for rule in conditions.rules where tightened[rule.id] != nil {
            active.append(DomainRestriction(owner: .conditional, policyID: ConditionalPolicy.pendingID(rule: rule.id),
                                            title: rule.title, domains: Set(tightened[rule.id]!)))
        }
        return EffectivePolicy(restrictions: active, domains: decision.blocked,
                               nextTransition: Self.withRuleTransition(base.nextTransition, conditions: conditions,
                                                                       at: date, calendar: calendar),
                               conditional: decision, apps: base.apps)
    }

    /// Exactly `evaluate(...).nextTransition`, without building the blocked
    /// sets (Nov 13: a snapshot needs only this, and the sets grow with the lists).
    func nextTransition(
        restrictions: [DomainRestriction],
        schedules: [DailySchedule],
        at date: Date,
        calendar: Calendar,
        conditions: ConditionalPolicy?
    ) -> Date? {
        let context = RuleContext(now: date, calendar: calendar, places: conditions?.places ?? [],
                                  snapshot: conditions?.presence)
        let base = Self.withPresenceExpiry(
            Self.baseTransition(restrictions: Self.located(restrictions, context: context), schedules: schedules,
                                at: date, calendar: calendar),
            restrictions: restrictions, conditions: conditions, at: date)
        guard let conditions, !conditions.rules.isEmpty else { return base }
        return Self.withRuleTransition(base, conditions: conditions, at: date, calendar: calendar)
    }

    /// A block limited to a place applies while Shield sees this Mac there,
    /// and whenever it can't tell (unknown location is the strict reading).
    private static func located(_ restrictions: [DomainRestriction], context: RuleContext) -> [DomainRestriction] {
        restrictions.filter { rule in
            guard let place = rule.placeID else { return true }
            return ConditionalRuleEngine.holds(.atPlace(placeID: place, minimumDwellMinutes: 0), effect: .block,
                                               context: context)
        }
    }

    /// The record going stale can start a place block without a new report.
    private static func withPresenceExpiry(_ next: Date?, restrictions: [DomainRestriction],
                                           conditions: ConditionalPolicy?, at date: Date) -> Date? {
        guard restrictions.contains(where: { $0.placeID != nil }), let presence = conditions?.presence,
              presence.locationKnown else { return next }
        let stale = presence.capturedAt.addingTimeInterval(PresenceSnapshot.maximumAge)
        return stale > date ? [next, stale].compactMap { $0 }.min() : next
    }

    private static func withRuleTransition(_ next: Date?, conditions: ConditionalPolicy, at date: Date,
                                           calendar: Calendar) -> Date? {
        [next, ConditionalRuleEngine.nextTransition(conditions, after: date, calendar: calendar)].compactMap { $0 }.min()
    }

    /// The next start or end of any restriction or requested schedule.
    private static func baseTransition(restrictions: [DomainRestriction], schedules: [DailySchedule],
                                       at date: Date, calendar: Calendar) -> Date? {
        let fixedTransitions = restrictions.compactMap { restriction -> Date? in
            [restriction.startsAt, restriction.endsAt]
                .compactMap { $0 }
                .filter { $0 > date }
                .min()
        }
        let scheduleTransitions = schedules
            .filter(\.isRequested)
            .compactMap { $0.nextTransition(after: date, calendar: calendar) }
        return (fixedTransitions + scheduleTransitions).min()
    }

    func evaluate(
        restrictions: [DomainRestriction],
        schedules: [DailySchedule],
        at date: Date,
        calendar: Calendar
    ) -> EffectivePolicy {
        var active = restrictions.filter { $0.isEffective(at: date) }
        for schedule in schedules where schedule.isRequested && schedule.contains(date, calendar: calendar) {
            active.append(
                DomainRestriction(
                    owner: .recurring,
                    policyID: schedule.id,
                    title: schedule.title,
                    domains: schedule.domains,
                    apps: schedule.apps
                )
            )
        }

        let domains = active.reduce(into: Set<String>()) { result, restriction in
            result.formUnion(restriction.domains.map { $0.lowercased() })
        }
        let apps = active.reduce(into: Set<AppTarget>()) { $0.formUnion($1.apps) }

        return EffectivePolicy(
            restrictions: active,
            domains: domains,
            nextTransition: Self.baseTransition(restrictions: restrictions, schedules: schedules,
                                                at: date, calendar: calendar),
            apps: apps
        )
    }

    func weakeningDomains(
        committed: Set<String>,
        requested: Set<String>
    ) -> Set<String> {
        committed.subtracting(requested)
    }

    func strengtheningDomains(
        committed: Set<String>,
        requested: Set<String>
    ) -> Set<String> {
        requested.subtracting(committed)
    }
}
