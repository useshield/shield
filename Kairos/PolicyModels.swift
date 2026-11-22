import Foundation

enum PolicyOwner: String, Codable, CaseIterable, Sendable {
    case permanent
    case recurring
    case temporary
    case commitment
    // Effective-only: a conditional block rule that is on right now. Never a
    // committed restriction, and written only in schema 2 authority state.
    case conditional
}

struct DomainRestriction: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let owner: PolicyOwner
    let policyID: String
    let title: String
    let domains: Set<String>
    let startsAt: Date?
    let endsAt: Date?
    // Apps this rule closes (docs/app-blocking-design.md). Encoded only when
    // present, so rules without apps keep their exact earlier encoding.
    let apps: Set<AppTarget>
    // Place blocks (docs/conditional-rules-blueprint.md): a block that applies only
    // while Shield sees this Mac at that place, and whenever it can't tell.
    // Encoded only when set.
    let placeID: String?
    // "Go there today" (docs/conditional-rules-blueprint.md §8): this timed block lifts
    // for the rest of its day once the service sees this Mac arrive at one of
    // the gate's places. Encoded only when set.
    let goDay: GoDayGate?

    init(
        id: UUID = UUID(),
        owner: PolicyOwner,
        policyID: String,
        title: String,
        domains: Set<String>,
        startsAt: Date? = nil,
        endsAt: Date? = nil,
        apps: Set<AppTarget> = [],
        placeID: String? = nil,
        goDay: GoDayGate? = nil
    ) {
        self.id = id
        self.owner = owner
        self.policyID = policyID
        self.title = title
        self.domains = domains
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.apps = apps
        self.placeID = placeID
        self.goDay = goDay
    }

    private enum CodingKeys: String, CodingKey { case id, owner, policyID, title, domains, startsAt, endsAt, apps, placeID, goDay }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id), owner: try c.decode(PolicyOwner.self, forKey: .owner),
                  policyID: try c.decode(String.self, forKey: .policyID), title: try c.decode(String.self, forKey: .title),
                  domains: try c.decode(Set<String>.self, forKey: .domains),
                  startsAt: try c.decodeIfPresent(Date.self, forKey: .startsAt),
                  endsAt: try c.decodeIfPresent(Date.self, forKey: .endsAt),
                  apps: try c.decodeIfPresent(Set<AppTarget>.self, forKey: .apps) ?? [],
                  placeID: try c.decodeIfPresent(String.self, forKey: .placeID),
                  goDay: try c.decodeIfPresent(GoDayGate.self, forKey: .goDay))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(owner, forKey: .owner)
        try c.encode(policyID, forKey: .policyID)
        try c.encode(title, forKey: .title)
        try c.encode(domains, forKey: .domains)
        try c.encodeIfPresent(startsAt, forKey: .startsAt)
        try c.encodeIfPresent(endsAt, forKey: .endsAt)
        if !apps.isEmpty { try c.encode(apps, forKey: .apps) }
        try c.encodeIfPresent(placeID, forKey: .placeID)
        try c.encodeIfPresent(goDay, forKey: .goDay)
    }

    /// The same rule under another owner or end, keeping its sites and apps.
    func with(owner: PolicyOwner, endsAt: Date? = nil) -> DomainRestriction {
        DomainRestriction(id: id, owner: owner, policyID: policyID, title: title, domains: domains,
                          startsAt: startsAt, endsAt: endsAt, apps: apps, placeID: placeID, goDay: goDay)
    }

    /// This Go day, lifted from `date` on: the service confirmed the arrival.
    func arrived(at date: Date) -> DomainRestriction {
        var gate = goDay
        gate?.arrivedAt = date
        return DomainRestriction(id: id, owner: owner, policyID: policyID, title: title, domains: domains,
                                 startsAt: startsAt, endsAt: endsAt, apps: apps, placeID: placeID, goDay: gate)
    }

    /// A permanent block made with New Block ("focus-" owner) may be corrected
    /// within 72 hours of its start. Older permanents, including every plan
    /// owner, stay permanent. `startsAt` is never later than the time the
    /// service accepted the rule, so this cannot reopen an old commitment.
    static let permanentCorrectionWindow: TimeInterval = 259_200

    func isCorrectablePermanent(at now: Date) -> Bool {
        guard owner == .permanent, endsAt == nil, policyID.hasPrefix("focus-"),
              let startsAt, startsAt <= now else { return false }
        return now.timeIntervalSince(startsAt) <= Self.permanentCorrectionWindow
    }

    func isEffective(at date: Date) -> Bool {
        let hasStarted = startsAt.map { $0 <= date } ?? true
        let hasNotEnded = endsAt.map { date < $0 } ?? true
        // Compared with the date, so replaying an earlier generation still sees the lock.
        let hasNotArrived = goDay?.arrivedAt.map { date < $0 } ?? true
        return hasStarted && hasNotEnded && hasNotArrived
    }
}

enum PolicyValidation {
    static let maximumApps = 20
    /// Website entries in one rule, www. twins included (about 1,000 sites).
    /// Imported lists need room; the service checks the same number. Bigger
    /// imports are split into several lists.
    static let maximumDomains = 2_000

    /// A pickable, blockable app: a plausible bundle ID, a 10-character team
    /// ID when present, and never an app on the never-blockable list.
    static func validApp(_ app: AppTarget) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return (3...255).contains(app.bundleID.count) && app.bundleID.unicodeScalars.allSatisfy(allowed.contains)
            && app.bundleID.contains(".") && !app.bundleID.hasPrefix(".") && !app.bundleID.hasSuffix(".")
            && (app.teamID.map { $0.count == 10 && $0.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) } ?? true)
            && (1...160).contains(app.displayName.count)
            && AppBlockSafety.refusal(for: app.bundleID) == nil
            && app != .webBrowsers   // only a Go day may name every browser
    }

    /// Sites and apps of one rule: at least one of either, within limits.
    static func validTargets(domains: Set<String>, apps: Set<AppTarget>) -> Bool {
        (!domains.isEmpty || !apps.isEmpty) && domains.count <= maximumDomains && apps.count <= maximumApps
            && domains.allSatisfy(validDomain) && apps.allSatisfy(validApp)
    }

    /// Lowercase letters, digits and inner hyphens in dot-separated labels of
    /// 1–63 characters, 253 at most. One pass over the bytes: lists of
    /// thousands of sites are checked on every service pass. (Fuzzed against
    /// the earlier split-based check: identical on 2 million inputs.)
    static func validDomain(_ value: String) -> Bool {
        var count = 0
        var labelLength = 0
        var previous: UInt8 = 46
        for byte in value.utf8 {
            count += 1
            if byte == 46 {            // "."
                guard labelLength > 0, previous != 45 else { return false }
                labelLength = 0
            } else {
                guard (97...122).contains(byte) || (48...57).contains(byte) || (byte == 45 && labelLength > 0) else {
                    return false
                }
                labelLength += 1
            }
            guard count <= 253, labelLength <= 63 else { return false }
            previous = byte
        }
        return labelLength > 0 && previous != 45
    }
}

struct DailySchedule: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let domains: Set<String>
    let startMinutes: Int
    let endMinutes: Int
    var isRequested: Bool
    let apps: Set<AppTarget>

    init(id: String, title: String, domains: Set<String>, startMinutes: Int, endMinutes: Int,
         isRequested: Bool, apps: Set<AppTarget> = []) {
        self.id = id
        self.title = title
        self.domains = domains
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
        self.isRequested = isRequested
        self.apps = apps
    }

    private enum CodingKeys: String, CodingKey { case id, title, domains, startMinutes, endMinutes, isRequested, apps }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), title: try c.decode(String.self, forKey: .title),
                  domains: try c.decode(Set<String>.self, forKey: .domains),
                  startMinutes: try c.decode(Int.self, forKey: .startMinutes),
                  endMinutes: try c.decode(Int.self, forKey: .endMinutes),
                  isRequested: try c.decode(Bool.self, forKey: .isRequested),
                  apps: try c.decodeIfPresent(Set<AppTarget>.self, forKey: .apps) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(domains, forKey: .domains)
        try c.encode(startMinutes, forKey: .startMinutes)
        try c.encode(endMinutes, forKey: .endMinutes)
        try c.encode(isRequested, forKey: .isRequested)
        if !apps.isEmpty { try c.encode(apps, forKey: .apps) }
    }

    /// The same sites and apps with other hours.
    func withHours(start: Int, end: Int, isRequested: Bool? = nil) -> DailySchedule {
        DailySchedule(id: id, title: title, domains: domains, startMinutes: start, endMinutes: end,
                      isRequested: isRequested ?? self.isRequested, apps: apps)
    }

    var spansMidnight: Bool { endMinutes <= startMinutes }

    var isValid: Bool {
        (0..<1_440).contains(startMinutes) && (0..<1_440).contains(endMinutes)
            && startMinutes != endMinutes && domains.allSatisfy(PolicyValidation.validDomain)
            && apps.count <= PolicyValidation.maximumApps && apps.allSatisfy(PolicyValidation.validApp)
    }

    // Compare every local wall-clock minute. This also covers overnight
    // windows and repeated/missing DST hours without assuming a 24-hour day.
    func isImmediateStrengthening(of previous: DailySchedule) -> Bool {
        guard isValid, previous.isValid, isRequested, previous.isRequested,
              id == previous.id, domains.isSuperset(of: previous.domains),
              apps.isSuperset(of: previous.apps) else { return false }
        func active(_ schedule: DailySchedule, minute: Int) -> Bool {
            if schedule.spansMidnight {
                return minute >= schedule.startMinutes || minute < schedule.endMinutes
            }
            return minute >= schedule.startMinutes && minute < schedule.endMinutes
        }
        return (0..<1_440).allSatisfy { minute in
            !active(previous, minute: minute) || active(self, minute: minute)
        }
    }

    func contains(_ date: Date, calendar: Calendar) -> Bool {
        guard isValid else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        if spansMidnight {
            return minute >= startMinutes || minute < endMinutes
        }
        return minute >= startMinutes && minute < endMinutes
    }

    func nextTransition(after date: Date, calendar: Calendar) -> Date? {
        guard isValid else { return nil }
        // Both occurrences matter during a fall-back hour. Asking only for
        // `.first` can skip the second start/end after the clock has repeated.
        var candidates = [startMinutes, endMinutes].flatMap { minutes -> [Date] in
            [Calendar.RepeatedTimePolicy.first, .last].compactMap { repeated in
                calendar.nextDate(
                    after: date,
                    matching: DateComponents(hour: minutes / 60, minute: minutes % 60, second: 0),
                    matchingPolicy: .nextTime,
                    repeatedTimePolicy: repeated
                )
            }
        }
        // A clock change can alter whether an overnight window is active
        // before its next nominal start or end wall-clock time.
        if let clockChange = calendar.timeZone.nextDaylightSavingTimeTransition(after: date) {
            candidates.append(clockChange)
        }
        return candidates.min()
    }
}

struct PolicyRequest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    var youtubeEnabled: Bool
    var socialEnabled: Bool
    var updatedAt: Date
    var windowMinutes: [String: Int]

    static let defaultWindowMinutes = [
        "YouTubeStartMinutes": 840, "YouTubeEndMinutes": 1_080,
        "SocialMorningStartMinutes": 420, "SocialMorningEndMinutes": 780,
        "SocialNightStartMinutes": 1_200, "SocialNightEndMinutes": 480
    ]

    init(
        schemaVersion: Int = currentSchemaVersion,
        youtubeEnabled: Bool,
        socialEnabled: Bool,
        updatedAt: Date = .now,
        windowMinutes: [String: Int] = PolicyRequest.defaultWindowMinutes
    ) {
        self.schemaVersion = schemaVersion
        self.youtubeEnabled = youtubeEnabled
        self.socialEnabled = socialEnabled
        self.updatedAt = updatedAt
        self.windowMinutes = windowMinutes
    }
}

struct PolicyCommitment: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let domains: Set<String>
    let committed: Bool
    let active: Bool
    let activeUntil: Date?
    let pendingDisableEffectiveAt: Date?
}

struct AuthorityState: Codable, Equatable, Sendable {
    // Schema 2 adds conditional rules. It is written only when places or rules
    // exist, so older readers (which accept exactly 1) refuse such a state
    // instead of showing its blocks without the rules that changed them.
    static let currentSchemaVersion = 2
    static let supportedSchemaVersions = 1...2

    static func schemaVersion(for conditions: ConditionalAuthorityState?) -> Int {
        conditions == nil ? 1 : 2
    }

    let schemaVersion: Int
    let generation: UInt64
    let generatedAt: Date
    let reconciliationID: UUID
    let lastSuccessfulReconciliation: Date
    let commitments: [PolicyCommitment]
    let effectiveRestrictions: [DomainRestriction]
    var conditions: ConditionalAuthorityState? = nil
}

// What the service decided about conditional rules at `generatedAt`.
struct ConditionalAuthorityState: Codable, Equatable, Sendable {
    let places: [RulePlace]
    let rules: [ConditionalRule]
    let presence: PresenceSnapshot?
    let openedBy: [String: String]     // domain → allow rule id
    let tightenedBy: [String: String]  // domain → block rule id
}

enum AuthorityStatus: Equatable, Sendable {
    case unavailable(AuthorityReadError)
    case valid(AuthorityState)
}

enum AuthorityReadError: Error, Equatable, LocalizedError, Sendable {
    case missing
    case empty
    case unreadable(String)
    case malformed(String)
    case unsupportedSchema(Int)
    case incomplete(String)
    case stale(generatedAt: Date)

    var errorDescription: String? {
        switch self {
        case .missing:
            "Authority state is missing."
        case .empty:
            "Authority state is empty. Enforcement cannot be verified."
        case .unreadable(let detail):
            "Authority state is unreadable: \(detail)"
        case .malformed(let detail):
            "Authority state is malformed: \(detail)"
        case .unsupportedSchema(let version):
            "Authority schema version \(version) is unsupported."
        case .incomplete(let field):
            "Authority state is incomplete: \(field)."
        case .stale(let generatedAt):
            "Authority state is stale (generated \(generatedAt.formatted()))."
        }
    }
}

struct EnforcementSnapshot: Codable, Equatable, Sendable {
    let observedAt: Date
    let blockedDomains: Set<String>
    let managedSectionPresent: Bool
    let resolution: ResolverObservation?
    // IDs (`AppTarget.id`) of the apps an app enforcer is closing; nil when
    // no app enforcer ran, so the app can't claim apps are blocked.
    var blockedApps: Set<String>? = nil

    init(observedAt: Date, blockedDomains: Set<String>, managedSectionPresent: Bool,
         resolution: ResolverObservation? = nil, blockedApps: Set<String>? = nil) {
        self.observedAt = observedAt
        self.blockedDomains = blockedDomains
        self.managedSectionPresent = managedSectionPresent
        self.resolution = resolution
        self.blockedApps = blockedApps
    }
}

struct ResolverObservation: Codable, Equatable, Sendable {
    struct Result: Codable, Equatable, Sendable {
        let domain: String
        let addresses: [String]
        let usesBlockingAddresses: Bool
        let error: String?
    }
    let generation: UInt64
    let observedAt: Date
    let totalDomains: Int
    let results: [Result]
    let problem: String?
}

enum EvidenceState: Equatable, Sendable {
    case verified
    case mismatch(String)
    case unavailable(String)
}

struct BackendHealth: Equatable, Sendable {
    let authority: AuthorityStatus
    let enforcement: EvidenceState
    let reconcilerPresent: Bool
    let schedulerDefinitionPresent: Bool

    var isVerifiedHealthy: Bool {
        guard case .valid = authority, enforcement == .verified else { return false }
        return reconcilerPresent && schedulerDefinitionPresent
    }
}

struct EffectivePolicy: Equatable, Sendable {
    let restrictions: [DomainRestriction]
    let domains: Set<String>
    var nextTransition: Date?
    var conditional: RuleDecision? = nil
    var apps: Set<AppTarget> = []
}

enum ShieldSection: String, CaseIterable, Identifiable {
    case protection = "Protection"
    case places = "Places"
    case schedules = "Schedules"
    case studyLibrary = "Library"
    case diagnostics = "Settings"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .protection: "shield.lefthalf.filled"
        case .places: "mappin.and.ellipse"
        case .schedules: "calendar.badge.clock"
        case .studyLibrary: "play.square.stack"
        case .diagnostics: "gearshape.fill"
        }
    }
}

// MARK: Go there today

/// The condition that lifts a Go day: arriving at one of `places`. The places
/// are copies taken when the day began, so editing a saved place never changes
/// a running day. Where the day began (its Wi-Fi and fix) never counts.
struct GoDayGate: Codable, Hashable, Sendable {
    struct Place: Codable, Hashable, Sendable {
        let name: String
        let latitude: Double
        let longitude: Double
        let radiusMeters: Double
    }

    struct StartFix: Codable, Hashable, Sendable {
        let latitude: Double
        let longitude: Double
        let horizontalAccuracy: Double
    }

    static let policyPrefix = "goday-"
    static let undoWindow: TimeInterval = 120
    static let radiusRange: ClosedRange<Double> = 100...1_000
    // A place this close to where the day began is "already there".
    static let minimumStartDistance: Double = 400
    static let maximumPlaces = 5
    // 25 h: the day the clocks go back is that long, and "until 11:59 PM" must fit.
    static let maximumLength: TimeInterval = 90_000

    let places: [Place]
    let startTags: Set<String>
    let startFix: StartFix?
    var arrivedAt: Date?

    /// Shape only (no clock): what a stored day must always satisfy. Shield
    /// must know where the day began (a fix, or the Wi-Fi it could see), or
    /// "arriving" could happen without leaving.
    var isWellFormed: Bool {
        (startFix != nil || startTags.count >= 2) && (1...Self.maximumPlaces).contains(places.count) && startTags.count <= PresenceReportGate.maximumTags &&
            startTags.allSatisfy { (1...128).contains($0.count) } &&
            places.allSatisfy { place in
                (1...80).contains(place.name.count) && Self.radiusRange.contains(place.radiusMeters) &&
                    (-90...90).contains(place.latitude) && (-180...180).contains(place.longitude)
            } &&
            (startFix.map { (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude) &&
                $0.horizontalAccuracy.isFinite && $0.horizontalAccuracy > 0 } ?? true)
    }

    /// Places where the day began (when that is known): its centre too close,
    /// or a big circle that reaches back to it.
    var placesAtStart: [Place] {
        guard let startFix else { return [] }
        return places.filter {
            PresenceGate.distanceMeters(startFix.latitude, startFix.longitude, $0.latitude, $0.longitude)
                < max(Self.minimumStartDistance, $0.radiusMeters + Self.minimumStartDistance / 2)
        }
    }
}

extension DomainRestriction {
    var isGoDay: Bool { goDay != nil }

    /// A Go day as stored: timed, no place block, a well-formed gate, and
    /// something to block: web browsers, chosen apps, websites, or a mix
    /// Browsers are a choice, and websites can be added.
    /// Every part is stronger, so nothing here can weaken another rule.
    var isWellFormedGoDay: Bool {
        let chosenApps = apps.subtracting([.webBrowsers])
        guard let goDay, owner == .temporary, policyID.hasPrefix(GoDayGate.policyPrefix),
              placeID == nil, !apps.isEmpty || !domains.isEmpty,
              domains.count <= PolicyValidation.maximumDomains, domains.allSatisfy(PolicyValidation.validDomain),
              chosenApps.count <= PolicyValidation.maximumApps, chosenApps.allSatisfy(PolicyValidation.validApp),
              let startsAt, let endsAt, endsAt > startsAt,
              endsAt.timeIntervalSince(startsAt) <= GoDayGate.maximumLength else { return false }
        return goDay.isWellFormed && goDay.arrivedAt.map { $0 >= startsAt } ?? true
    }
}
