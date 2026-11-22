import Foundation

// Conditional rules (docs/conditional-rules-blueprint.md). A rule is a set of
// conditions plus an effect: "everything blocked until I'm at the library",
// "a site only at the library in the afternoon", "stricter at home after
// 10 PM", "a site after 45 minutes of study". Pure and deterministic: evidence
// comes in as values, nothing is read from a global.

// MARK: Places and presence evidence

struct RulePlace: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double
    // HMAC tags of the place's Wi-Fi access points (never raw BSSIDs at rest).
    var wifiTags: Set<String>
    var isHome: Bool = false
}

struct PresenceEvidence: Sendable, Equatable {
    struct Fix: Sendable, Equatable {
        let latitude: Double
        let longitude: Double
        let horizontalAccuracy: Double
        let observedAt: Date
        let isSimulated: Bool
        let fullAccuracy: Bool
    }
    let observedAt: Date
    let fix: Fix?
    let connectedWiFiTag: String?
    let visibleWiFiTags: Set<String>
    let sleptSinceLastEvidence: Bool
}

enum PresenceGate {
    static let maximumFixAge: TimeInterval = 120

    static func distanceMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0, p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Location counts as known only with a fresh, precise, real fix. Wi-Fi
    /// alone, a denied or approximate permission, or an old fix is unknown, so
    /// place blocks hold.
    static func hasUsableFix(_ evidence: PresenceEvidence, now: Date) -> Bool { usableFix(evidence, now: now) != nil }

    /// When the usable fix was observed (never later than `now`), so a record
    /// ages from the fix itself, not from when the service received it.
    static func usableFixTime(_ evidence: PresenceEvidence, now: Date) -> Date? {
        usableFix(evidence, now: now).map { min($0.observedAt, now) }
    }

    static func usableFix(_ evidence: PresenceEvidence, now: Date) -> PresenceEvidence.Fix? {
        guard let fix = evidence.fix, !fix.isSimulated, fix.fullAccuracy,
              now.timeIntervalSince(fix.observedAt) <= maximumFixAge,
              now.timeIntervalSince(fix.observedAt) >= -5 else { return nil }
        return fix
    }

    // Strong evidence, required before any rule may LOOSEN a block: the whole
    // error circle inside the fence, a matching Wi-Fi signal, no home veto,
    // no contradiction, and no sleep since the last sample.
    static func qualifiesForException(_ place: RulePlace, home: RulePlace?, evidence: PresenceEvidence, now: Date) -> Bool {
        guard !place.isHome, !evidence.sleptSinceLastEvidence,
              let fix = usableFix(evidence, now: now),
              fix.horizontalAccuracy <= min(place.radiusMeters * 0.6, 80) else { return false }
        let distance = distanceMeters(fix.latitude, fix.longitude, place.latitude, place.longitude)
        guard distance + fix.horizontalAccuracy <= place.radiusMeters else { return false }
        let wifi = evidence.connectedWiFiTag.map(place.wifiTags.contains) == true ||
            place.wifiTags.intersection(evidence.visibleWiFiTags).count >= 3
        return wifi && !homeVeto(home, evidence: evidence)
    }

    // Weak evidence is enough to make things STRICTER: any one signal.
    static func indicatesPlace(_ place: RulePlace, evidence: PresenceEvidence, now: Date) -> Bool {
        if let tag = evidence.connectedWiFiTag, place.wifiTags.contains(tag) { return true }
        if place.wifiTags.intersection(evidence.visibleWiFiTags).count >= 2 { return true }
        guard let fix = usableFix(evidence, now: now) else { return false }
        let distance = distanceMeters(fix.latitude, fix.longitude, place.latitude, place.longitude)
        return distance - fix.horizontalAccuracy <= place.radiusMeters
    }

    static func homeVeto(_ home: RulePlace?, evidence: PresenceEvidence) -> Bool {
        guard let home else { return false }
        if let tag = evidence.connectedWiFiTag, home.wifiTags.contains(tag) { return true }
        return home.wifiTags.intersection(evidence.visibleWiFiTags).count >= 2
    }
}

// Per-place dwell state machine. In memory only: a restart starts at unknown.
struct PresenceTracker: Sendable {
    static let maximumGap: TimeInterval = 90
    private(set) var candidateSince: [String: Date] = [:]
    private(set) var lastQualified: [String: Date] = [:]
    // Verified time spent today per place, for "after N minutes there" rules.
    private(set) var dwellToday: [String: TimeInterval] = [:]
    private var day: DateComponents?

    mutating func observe(_ evidence: PresenceEvidence, places: [RulePlace], now: Date, calendar: Calendar) {
        let today = calendar.dateComponents([.year, .month, .day], from: now)
        if today != day { dwellToday = [:]; day = today }
        let home = places.first(where: \.isHome)
        for place in places where !place.isHome {
            if PresenceGate.qualifiesForException(place, home: home, evidence: evidence, now: now) {
                if let last = lastQualified[place.id], now.timeIntervalSince(last) <= Self.maximumGap {
                    dwellToday[place.id, default: 0] += now.timeIntervalSince(last)
                } else {
                    candidateSince[place.id] = now
                }
                lastQualified[place.id] = now
            } else {
                // Contradiction or missing evidence resets presence immediately.
                candidateSince[place.id] = nil
                lastQualified[place.id] = nil
            }
        }
    }

    /// A refused report breaks continuity: dwell restarts, time already
    /// verified today is kept.
    mutating func interrupt() {
        candidateSince = [:]
        lastQualified = [:]
    }

    func verifiedDwell(at placeID: String, now: Date) -> TimeInterval {
        guard let since = candidateSince[placeID], let last = lastQualified[placeID],
              now.timeIntervalSince(last) <= Self.maximumGap else { return 0 }
        return now.timeIntervalSince(since)
    }
}

// MARK: Rules

enum RuleCondition: Codable, Sendable, Equatable {
    // Local minutes from midnight; end < start wraps past midnight.
    case timeWindow(startMinute: Int, endMinute: Int, weekdays: Set<Int>)
    case atPlace(placeID: String, minimumDwellMinutes: Int)
    case notAtPlace(placeID: String)
    // "Blocked until I get there": verified time at the place today.
    case arrivedToday(placeID: String, minimumMinutes: Int)
    case studiedToday(minimumMinutes: Int)
}

enum RuleEffect: String, Codable, Sendable { case block, allow }

struct ConditionalRule: Codable, Sendable, Equatable, Identifiable {
    static let precommitment: TimeInterval = 86_400
    let id: String
    var title: String
    var domains: Set<String>
    var effect: RuleEffect
    var conditions: [RuleCondition]
    // Weakening rules apply only once they have existed for 24 hours.
    let committedAt: Date
}

// MARK: Recorded presence

// What the service keeps after judging one report: per-place verdicts and
// verified minutes, never coordinates or Wi-Fi tags. Rules are evaluated from
// this record, so the service can re-check a committed state later from the
// record alone (its integrity check replays evaluation at the commit time).
struct PresenceSnapshot: Codable, Sendable, Equatable {
    struct PlaceState: Codable, Sendable, Equatable {
        var indicated = false          // any one signal: enough to make things stricter
        var qualified = false          // exception-grade evidence: needed to loosen
        var dwellSeconds: TimeInterval = 0   // continuous verified time there now
        var todaySeconds: TimeInterval = 0   // verified time there today
    }

    // Location verdicts older than this are unknown, so place rules turn strict.
    static let maximumAge: TimeInterval = 120

    let capturedAt: Date
    let locationKnown: Bool
    let places: [String: PlaceState]
    let studyMinutesToday: Int?

    static func capture(evidence: PresenceEvidence?, places: [RulePlace], tracker: PresenceTracker,
                        studyMinutesToday: Int?, now: Date) -> PresenceSnapshot {
        let home = places.first(where: \.isHome)
        var states: [String: PlaceState] = [:]
        for place in places {
            var state = PlaceState(todaySeconds: tracker.dwellToday[place.id] ?? 0)
            if let evidence {
                state.indicated = PresenceGate.indicatesPlace(place, evidence: evidence, now: now)
                state.qualified = PresenceGate.qualifiesForException(place, home: home, evidence: evidence, now: now)
                state.dwellSeconds = tracker.verifiedDwell(at: place.id, now: now)
            }
            states[place.id] = state
        }
        // The first evidence after a sleep may describe where the Mac fell
        // asleep, so it never counts as known (place blocks hold).
        let fixTime = evidence.flatMap { $0.sleptSinceLastEvidence ? nil : PresenceGate.usableFixTime($0, now: now) }
        return PresenceSnapshot(capturedAt: fixTime ?? now, locationKnown: fixTime != nil, places: states,
                                studyMinutesToday: studyMinutesToday)
    }

    /// Location verdicts usable at `now`: known, recent, and not from the future.
    func locationUsable(at now: Date) -> Bool {
        locationKnown && now.timeIntervalSince(capturedAt) <= Self.maximumAge && capturedAt <= now.addingTimeInterval(5)
    }

    /// Verified time at a place today counts only on the day it was recorded.
    func todaySeconds(at placeID: String, now: Date, calendar: Calendar) -> TimeInterval {
        guard calendar.isDate(capturedAt, inSameDayAs: now), capturedAt <= now.addingTimeInterval(5) else { return 0 }
        return places[placeID]?.todaySeconds ?? 0
    }

    func studyMinutes(now: Date, calendar: Calendar) -> Int? {
        calendar.isDate(capturedAt, inSameDayAs: now) ? studyMinutesToday : nil
    }
}

struct RuleContext: Sendable {
    let now: Date
    let calendar: Calendar
    let places: [RulePlace]
    let snapshot: PresenceSnapshot?

    init(now: Date, calendar: Calendar, places: [RulePlace], snapshot: PresenceSnapshot?) {
        self.now = now
        self.calendar = calendar
        self.places = places
        self.snapshot = snapshot
    }

    init(now: Date, calendar: Calendar, places: [RulePlace], evidence: PresenceEvidence?,
         tracker: PresenceTracker, studyMinutesToday: Int?) {
        self.init(now: now, calendar: calendar, places: places,
                  snapshot: .capture(evidence: evidence, places: places, tracker: tracker,
                                     studyMinutesToday: studyMinutesToday, now: now))
    }
}

struct RuleDecision: Sendable, Equatable {
    let blocked: Set<String>
    let openedBy: [String: String]   // domain → allow rule id
    let tightenedBy: [String: String] // domain → block rule id
}

enum ConditionalRuleEngine {
    static func timeWindowContains(_ start: Int, _ end: Int, weekdays: Set<Int>, at now: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: now)
        guard let hour = parts.hour, let minute = parts.minute, let weekday = parts.weekday else { return false }
        let current = hour * 60 + minute
        if start == end { return weekdays.isEmpty || weekdays.contains(weekday) } // all day
        if start < end { return (weekdays.isEmpty || weekdays.contains(weekday)) && current >= start && current < end }
        // Wrapping window: the part after midnight belongs to the previous day's weekday.
        if current >= start { return weekdays.isEmpty || weekdays.contains(weekday) }
        let previous = weekday == 1 ? 7 : weekday - 1
        return current < end && (weekdays.isEmpty || weekdays.contains(previous))
    }

    // Unknown evidence makes a BLOCK condition hold and an ALLOW condition fail:
    // uncertainty always resolves toward more blocking.
    static func holds(_ condition: RuleCondition, effect: RuleEffect, context: RuleContext) -> Bool {
        let strict = effect == .block
        let now = context.now
        let known = context.snapshot.map { $0.locationUsable(at: now) } ?? false
        func state(_ id: String) -> PresenceSnapshot.PlaceState? {
            guard context.places.contains(where: { $0.id == id }) else { return nil }
            return context.snapshot?.places[id]
        }
        switch condition {
        case .timeWindow(let start, let end, let weekdays):
            return timeWindowContains(start, end, weekdays: weekdays, at: now, calendar: context.calendar)
        case .atPlace(let id, let dwell):
            guard known, let place = state(id) else { return strict }
            if strict { return place.indicated }
            return place.qualified && place.dwellSeconds >= TimeInterval(dwell * 60)
        case .notAtPlace(let id):
            guard known, let place = state(id) else { return strict }
            // Loosening "when I'm away from home" needs proof of being elsewhere.
            if strict { return !place.qualified }
            return !place.indicated && context.places.contains { other in
                other.id != id && !other.isHome && context.snapshot?.places[other.id]?.qualified == true
            }
        case .arrivedToday(let id, let minutes):
            guard state(id) != nil, let snapshot = context.snapshot else { return strict }
            let reached = snapshot.todaySeconds(at: id, now: now, calendar: context.calendar) >= TimeInterval(minutes * 60)
            return strict ? !reached : reached
        case .studiedToday(let minutes):
            guard let studied = context.snapshot?.studyMinutes(now: now, calendar: context.calendar) else { return strict }
            return strict ? studied < minutes : studied >= minutes
        }
    }

    static func isActive(_ rule: ConditionalRule, context: RuleContext) -> Bool {
        if rule.effect == .allow &&
            context.now.timeIntervalSince(rule.committedAt) < ConditionalRule.precommitment { return false }
        return rule.conditions.allSatisfy { holds($0, effect: rule.effect, context: context) }
    }

    // Composition: active block rules add; active allow rules remove only from
    // relaxable base blocks; a block rule always wins over an allow rule; and
    // never-relaxable owners (permanent blocks, any 24/7 block) are
    // added back last, so no rule can open them.
    static func evaluate(baseBlocked: Set<String>, neverRelaxable: Set<String>,
                         rules: [ConditionalRule], context: RuleContext) -> RuleDecision {
        var tightened: [String: String] = [:], opened: [String: String] = [:]
        for rule in rules.sorted(by: { $0.id < $1.id }) where isActive(rule, context: context) {
            for domain in rule.domains {
                switch rule.effect {
                case .block: tightened[domain] = tightened[domain] ?? rule.id
                case .allow: opened[domain] = opened[domain] ?? rule.id
                }
            }
        }
        var blocked = baseBlocked.union(tightened.keys)
        for domain in opened.keys where tightened[domain] == nil && !neverRelaxable.contains(domain) {
            blocked.remove(domain)
        }
        blocked.formUnion(neverRelaxable)
        let effectiveOpen = opened.filter { !blocked.contains($0.key) && baseBlocked.contains($0.key) }
        return RuleDecision(blocked: blocked, openedBy: effectiveOpen, tightenedBy: tightened)
    }
}

// MARK: Reports from the app

// Only the signed app can hold the Location privilege (a root daemon can't),
// so it reports evidence; the service judges it against committed places. The
// XPC connection already checks the app's signature and user. This gate adds
// ordering and freshness so a replayed or held-back report can't stand in for
// a current one. A rejected report simply leaves location unknown (strict).
struct PresenceReport: Codable, Sendable, Equatable {
    let sequence: UInt64
    let bootSessionID: String       // changes on every restart
    let uptimeNanoseconds: UInt64   // awake time; stops while asleep
    let evidence: PresenceEvidenceRecord
}

// Codable mirror of PresenceEvidence for the wire. Raw Wi-Fi identifiers
// never cross it: the app sends HMAC tags only.
struct PresenceEvidenceRecord: Codable, Sendable, Equatable {
    var latitude: Double?
    var longitude: Double?
    var horizontalAccuracy: Double?
    var fixObservedAt: Date?
    var isSimulated: Bool
    var fullAccuracy: Bool
    var observedAt: Date
    var connectedWiFiTag: String?
    var visibleWiFiTags: [String]
    var sleptSinceLastEvidence: Bool

    var evidence: PresenceEvidence {
        var fix: PresenceEvidence.Fix?
        if let latitude, let longitude, let horizontalAccuracy, let fixObservedAt {
            fix = .init(latitude: latitude, longitude: longitude, horizontalAccuracy: horizontalAccuracy,
                        observedAt: fixObservedAt, isSimulated: isSimulated, fullAccuracy: fullAccuracy)
        }
        return PresenceEvidence(observedAt: observedAt, fix: fix, connectedWiFiTag: connectedWiFiTag,
                                visibleWiFiTags: Set(visibleWiFiTags), sleptSinceLastEvidence: sleptSinceLastEvidence)
    }
}

struct PresenceReportGate: Sendable {
    static let maximumTags = 64
    private(set) var lastSequence: UInt64?
    private(set) var lastUptime: UInt64?
    private(set) var bootSessionID: String?

    enum Rejection: Error, Equatable { case replayed, clockWentBackwards, notCurrent, malformed }

    /// Accepts a report and returns its evidence, or says why it was refused.
    mutating func accept(_ report: PresenceReport, serviceBootSessionID: String, now: Date) -> Result<PresenceEvidence, Rejection> {
        let record = report.evidence
        guard report.bootSessionID == serviceBootSessionID else { return .failure(.notCurrent) }
        guard abs(now.timeIntervalSince(record.observedAt)) <= 30 else { return .failure(.notCurrent) }
        guard record.visibleWiFiTags.count <= Self.maximumTags,
              ([record.connectedWiFiTag].compactMap { $0 } + record.visibleWiFiTags).allSatisfy({ (1...128).contains($0.count) }),
              record.latitude.map({ (-90...90).contains($0) }) ?? true,
              record.longitude.map({ (-180...180).contains($0) }) ?? true,
              record.horizontalAccuracy.map({ $0.isFinite && $0 > 0 }) ?? true else { return .failure(.malformed) }
        if bootSessionID == serviceBootSessionID {
            if let last = lastSequence, report.sequence <= last { return .failure(.replayed) }
            if let last = lastUptime, report.uptimeNanoseconds < last { return .failure(.clockWentBackwards) }
        }
        bootSessionID = serviceBootSessionID
        lastSequence = report.sequence
        lastUptime = report.uptimeNanoseconds
        return .success(record.evidence)
    }
}

// MARK: Places: limits and changes

enum RulePlaceValidator {
    static let minimumRadius: Double = 100
    static let maximumRadius: Double = 2_000
    static let maximumPlaces = 20
    static let maximumRules = 50

    static let maximumConditions = 8
    static let maximumDomains = 100

    enum Problem: Equatable { case tooMany, radius, coordinates, homeCount, unknownPlace, duplicateID, malformed }

    static func wellFormed(_ place: RulePlace) -> Bool {
        (1...128).contains(place.id.count) && (1...160).contains(place.name.count) &&
            place.wifiTags.count <= PresenceReportGate.maximumTags &&
            place.wifiTags.allSatisfy { (1...128).contains($0.count) }
    }

    static func wellFormed(_ rule: ConditionalRule) -> Bool {
        let minutes = 0...1_440
        return (1...128).contains(rule.id.count) && (1...160).contains(rule.title.count) &&
            (1...maximumDomains).contains(rule.domains.count) &&
            rule.domains.allSatisfy(PolicyValidation.validDomain) &&
            rule.conditions.count <= maximumConditions &&
            rule.committedAt.timeIntervalSinceReferenceDate.isFinite &&
            rule.conditions.allSatisfy { condition in
                switch condition {
                case .timeWindow(let start, let end, let weekdays):
                    return (0..<1_440).contains(start) && (0..<1_440).contains(end) && weekdays.isSubset(of: Set(1...7))
                case .atPlace(let id, let value), .arrivedToday(let id, let value):
                    return !id.isEmpty && minutes.contains(value)
                case .notAtPlace(let id): return !id.isEmpty
                case .studiedToday(let value): return minutes.contains(value)
                }
            }
    }

    /// Shape and limits only. A missing home or a rule naming a missing place
    /// is tolerated in stored state because both resolve strict.
    static func isStructurallyValid(places: [RulePlace], rules: [ConditionalRule]) -> Bool {
        problems(places: places, rules: rules).allSatisfy { $0 == .homeCount || $0 == .unknownPlace }
    }

    /// Problems with a whole set of places and rules, or none.
    static func problems(places: [RulePlace], rules: [ConditionalRule]) -> [Problem] {
        var problems: [Problem] = []
        if !places.allSatisfy(wellFormed) || !rules.allSatisfy(wellFormed) { problems.append(.malformed) }
        if places.count > maximumPlaces || rules.count > maximumRules { problems.append(.tooMany) }
        if Set(places.map(\.id)).count != places.count || Set(rules.map(\.id)).count != rules.count {
            problems.append(.duplicateID)
        }
        if places.contains(where: { !(minimumRadius...maximumRadius).contains($0.radiusMeters) }) { problems.append(.radius) }
        if places.contains(where: { !(-90...90).contains($0.latitude) || !(-180...180).contains($0.longitude) }) {
            problems.append(.coordinates)
        }
        // Home is the veto for every exception, so exceptions need exactly one.
        let homes = places.filter(\.isHome).count
        if homes > 1 || (homes == 0 && rules.contains { $0.effect == .allow && !$0.placeIDs.isEmpty }) {
            problems.append(.homeCount)
        }
        let ids = Set(places.map(\.id))
        if rules.contains(where: { !$0.placeIDs.isSubset(of: ids) }) { problems.append(.unknownPlace) }
        return problems
    }
}

extension ConditionalRule {
    var placeIDs: Set<String> {
        Set(conditions.compactMap {
            switch $0 {
            case .atPlace(let id, _), .notAtPlace(let id), .arrivedToday(let id, _): id
            case .timeWindow, .studiedToday: nil
            }
        })
    }
}

enum PlaceChangeClassifier {
    // A new place does nothing until a rule uses it. Moving, resizing, retagging
    // or deleting one can loosen some rule ("at" and "away from" rules pull in
    // opposite directions), so every such change waits 24 hours. A new name is
    // only a label.
    static func classify(old: RulePlace?, new: RulePlace?) -> RuleChangeClass {
        switch (old, new) {
        case (nil, _): return .immediate
        case (_?, nil): return .delayed
        case (let before?, let after?):
            var renamed = before
            renamed.name = after.name
            return renamed == after ? .immediate : .delayed
        }
    }
}

// MARK: Change classification (stronger: immediate; weaker: at least 24 h)

enum RuleChangeClass: Equatable { case immediate, delayed }

enum RuleChangeClassifier {
    static func classify(old: ConditionalRule?, new: ConditionalRule?) -> RuleChangeClass {
        switch (old, new) {
        case (nil, nil): return .immediate
        case (nil, let added?): return added.effect == .block ? .immediate : .delayed
        case (let removed?, nil): return removed.effect == .allow ? .immediate : .delayed
        case (let before?, let after?):
            guard before.effect == after.effect else { return .delayed }
            if before.effect == .block {
                // Stronger only with a superset of domains and identical conditions
                // (narrowing conditions could make the block apply less often).
                return after.domains.isSuperset(of: before.domains) && after.conditions == before.conditions
                    ? .immediate : .delayed
            }
            // An allow rule is stronger with fewer domains and the same conditions
            // plus any extra ones (more conditions → applies less often).
            let keepsConditions = before.conditions.allSatisfy(after.conditions.contains)
            return after.domains.isSubset(of: before.domains) && keepsConditions ? .immediate : .delayed
        }
    }
}

// MARK: Committed conditions

// What the authority stores beside restrictions and schedules: places, rules,
// and the last presence record it accepted. Delayed changes to a place or rule
// wait in the ordinary pending-release list under a prefixed owner id.
struct ConditionalPolicy: Codable, Sendable, Equatable {
    var places: [RulePlace] = []
    var rules: [ConditionalRule] = []
    var presence: PresenceSnapshot?

    static let empty = ConditionalPolicy()
    var isEmpty: Bool { places.isEmpty && rules.isEmpty }

    static let placePrefix = "place:"
    static let rulePrefix = "rule:"
    static func pendingID(place id: String) -> String { placePrefix + id }
    static func pendingID(rule id: String) -> String { rulePrefix + id }
    static func isConditionalOwner(_ policyID: String) -> Bool {
        policyID.hasPrefix(placePrefix) || policyID.hasPrefix(rulePrefix)
    }

    /// Whether any rule depends on location, so the presence record must stay fresh.
    var usesPlaces: Bool { rules.contains { !$0.placeIDs.isEmpty } }

    /// Removes recorded verdicts for places whose geometry or tags changed:
    /// they were judged against the old fence, so they no longer prove anything.
    mutating func forgetPresence(forChanged before: [RulePlace]) {
        guard var record = presence else { return }
        var states = record.places
        for place in places where before.first(where: { $0.id == place.id }).map({
            PlaceChangeClassifier.classify(old: $0, new: place) == .delayed
        }) ?? true {
            states[place.id] = nil
        }
        for id in states.keys where !places.contains(where: { $0.id == id }) { states[id] = nil }
        record = PresenceSnapshot(capturedAt: record.capturedAt, locationKnown: record.locationKnown,
                                  places: states, studyMinutesToday: record.studyMinutesToday)
        presence = record
    }
}

extension ConditionalRule {
    /// Same rule apart from when it was committed (the service sets that).
    func sameContent(as other: ConditionalRule) -> Bool {
        id == other.id && title == other.title && domains == other.domains &&
            effect == other.effect && conditions == other.conditions
    }

    func committed(at date: Date) -> ConditionalRule {
        ConditionalRule(id: id, title: title, domains: domains, effect: effect,
                        conditions: conditions, committedAt: date)
    }
}

extension ConditionalRuleEngine {
    /// The next moment a rule could change effect without a new report: a
    /// time-window edge, an exception finishing its 24 h wait, the presence
    /// record going stale, or local midnight (daily totals reset).
    static func nextTransition(_ conditions: ConditionalPolicy, after date: Date, calendar: Calendar) -> Date? {
        guard !conditions.rules.isEmpty else { return nil }
        var candidates: [Date] = []
        for rule in conditions.rules {
            if rule.effect == .allow { candidates.append(rule.committedAt.addingTimeInterval(ConditionalRule.precommitment)) }
            for case .timeWindow(let start, let end, _) in rule.conditions {
                for minutes in [start, end] {
                    for repeated in [Calendar.RepeatedTimePolicy.first, .last] {
                        if let next = calendar.nextDate(after: date, matching: DateComponents(hour: minutes / 60, minute: minutes % 60, second: 0),
                                                        matchingPolicy: .nextTime, repeatedTimePolicy: repeated) {
                            candidates.append(next)
                        }
                    }
                }
            }
        }
        if let presence = conditions.presence, presence.locationKnown {
            candidates.append(presence.capturedAt.addingTimeInterval(PresenceSnapshot.maximumAge))
        }
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) {
            candidates.append(midnight)
        }
        return candidates.filter { $0 > date }.min()
    }
}

// MARK: Presentation

enum ConditionalRulePresentation {
    static func clock(_ minute: Int) -> String {
        let hour = (minute / 60) % 24, m = minute % 60
        let h12 = hour % 12 == 0 ? 12 : hour % 12
        return m == 0 ? "\(h12) \(hour < 12 ? "AM" : "PM")" : "\(h12):\(String(format: "%02d", m)) \(hour < 12 ? "AM" : "PM")"
    }

    // Block rules lift once an "earned" condition is met, so they read "until".
    static func describe(_ condition: RuleCondition, effect: RuleEffect = .allow, places: [RulePlace]) -> String {
        let lead = effect == .block ? "until" : "after"
        func name(_ id: String) -> String { places.first { $0.id == id }?.name ?? "an unknown place" }
        switch condition {
        case .timeWindow(let start, let end, _): return start == end ? "all day" : "\(clock(start))–\(clock(end))"
        case .atPlace(let id, let dwell): return dwell > 0 ? "at \(name(id)) for \(dwell) min" : "at \(name(id))"
        case .notAtPlace(let id): return "away from \(name(id))"
        case .arrivedToday(let id, let minutes): return "\(lead) \(minutes) min at \(name(id)) today"
        case .studiedToday(let minutes): return "\(lead) \(minutes) min of study today"
        }
    }

    static func summary(_ rule: ConditionalRule, places: [RulePlace]) -> String {
        let sites = rule.domains.sorted().joined(separator: ", ")
        let when = rule.conditions.map { describe($0, effect: rule.effect, places: places) }.joined(separator: ", ")
        return "\(rule.effect == .allow ? "Allow" : "Block") \(sites)\(when.isEmpty ? "" : " — \(when)")"
    }
}

// MARK: Go there today: arriving

enum GoDayArrival {
    static let maximumAccuracy: Double = 100
    static let maximumFixAge: TimeInterval = 60
    // Two qualifying readings this far apart in awake time (sleep stops the
    // clock, and any reading in between that doesn't qualify starts over).
    static let confirmationNanoseconds: UInt64 = 20_000_000_000

    /// One reading that counts toward arriving: a fresh, precise, real fix
    /// whose centre is inside one of the day's places, not just after a sleep,
    /// and nothing that looks like where the day began.
    static func qualifies(_ evidence: PresenceEvidence, gate: GoDayGate, now: Date) -> Bool {
        guard !evidence.sleptSinceLastEvidence, let fix = PresenceGate.usableFix(evidence, now: now),
              fix.horizontalAccuracy <= maximumAccuracy,
              now.timeIntervalSince(fix.observedAt) <= maximumFixAge else { return false }
        if let tag = evidence.connectedWiFiTag, gate.startTags.contains(tag) { return false }
        if gate.startTags.intersection(evidence.visibleWiFiTags).count >= 2 { return false }
        if let start = gate.startFix,
           PresenceGate.distanceMeters(fix.latitude, fix.longitude, start.latitude, start.longitude)
            < GoDayGate.minimumStartDistance / 2 { return false }
        return gate.places.contains {
            PresenceGate.distanceMeters(fix.latitude, fix.longitude, $0.latitude, $0.longitude) <= $0.radiusMeters
        }
    }

    /// Distance to the nearest place, for the practice readout.
    static func nearest(_ fix: PresenceEvidence.Fix, gate: GoDayGate) -> (place: GoDayGate.Place, meters: Double)? {
        gate.places.map { ($0, PresenceGate.distanceMeters(fix.latitude, fix.longitude, $0.latitude, $0.longitude)) }
            .min { $0.1 < $1.1 }.map { (place: $0.0, meters: $0.1) }
    }
}

/// In memory, per service run: the first qualifying reading of each running
/// Go day. A restart, a refused report or a reading that doesn't qualify
/// starts over, so arrival always rests on two readings from this run.
struct GoDayConfirmation: Sendable {
    struct Reading: Sendable, Equatable { let uptime: UInt64; let fixAt: Date }
    private(set) var firstQualifying: [String: Reading] = [:]

    /// The days (policy IDs) that this reading confirms as arrived.
    mutating func observe(_ evidence: PresenceEvidence, uptime: UInt64, days: [DomainRestriction], now: Date) -> Set<String> {
        let running = Set(days.map(\.policyID))
        firstQualifying = firstQualifying.filter { running.contains($0.key) }
        var arrived = Set<String>()
        for day in days {
            guard let gate = day.goDay, gate.arrivedAt == nil, let fixAt = evidence.fix?.observedAt,
                  GoDayArrival.qualifies(evidence, gate: gate, now: now) else {
                firstQualifying[day.policyID] = nil
                continue
            }
            guard let first = firstQualifying[day.policyID], uptime >= first.uptime else {
                firstQualifying[day.policyID] = Reading(uptime: uptime, fixAt: fixAt)
                continue
            }
            // Two separate fixes, not one fix sent twice: a Mac sitting still
            // keeps reporting its last fix until Core Location is asked again.
            let seconds = Double(GoDayArrival.confirmationNanoseconds) / 1e9
            if uptime - first.uptime >= GoDayArrival.confirmationNanoseconds,
               fixAt.timeIntervalSince(first.fixAt) >= seconds {
                arrived.insert(day.policyID)
            }
        }
        return arrived
    }

    mutating func interrupt() { firstQualifying = [:] }
}
