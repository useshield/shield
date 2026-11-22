import Foundation

// Read-only presentation. These values never write a request or alter an owner.
struct AllowedAccessWindow: Equatable {
    let startMinutes: Int
    let endMinutes: Int

    init?(startMinutes: Int, endMinutes: Int) {
        guard (0..<1440).contains(startMinutes), (0..<1440).contains(endMinutes),
              startMinutes != endMinutes else { return nil }
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }

    init?(blockedSchedule: DailySchedule) {
        guard blockedSchedule.isValid else { return nil }
        self.init(startMinutes: blockedSchedule.endMinutes, endMinutes: blockedSchedule.startMinutes)
    }

    // Complement in local wall-clock minutes, not elapsed seconds. The authority
    // continues to own timezone/DST evaluation and weakening/strengthening rules.
    func blockedSchedule(basedOn original: DailySchedule) -> DailySchedule {
        original.withHours(start: endMinutes, end: startMinutes)
    }

    func description(calendar: Calendar, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        func time(_ minutes: Int) -> String {
            let date = calendar.date(from: DateComponents(year: 2001, month: 1, day: 15,
                                                          hour: minutes / 60, minute: minutes % 60)) ?? .now
            return formatter.string(from: date)
        }
        let suffix = endMinutes < startMinutes ? " · until next day" : ""
        return "Allowed \(time(startMinutes))–\(time(endMinutes))\(suffix)"
    }
}

extension AllowedAccessWindow {
    func contains(_ minute: Int) -> Bool {
        startMinutes < endMinutes ? (minute >= startMinutes && minute < endMinutes)
                                  : (minute >= startMinutes || minute < endMinutes)
    }
    /// Minutes from `now` forward to `target` on a 24-hour clock.
    func minutes(from now: Int, to target: Int) -> Int { (target - now + 1440) % 1440 }
}

/// Short wall-clock wording: "2–8 PM", "10 AM–2 PM", "8:30 PM".
enum ScheduleText {
    private static func parts(_ minutes: Int) -> (time: String, period: String) {
        let hour = (minutes / 60) % 24, minute = minutes % 60
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return (minute == 0 ? "\(twelve)" : String(format: "%d:%02d", twelve, minute), hour < 12 ? "AM" : "PM")
    }
    static func time(_ minutes: Int) -> String { let p = parts(minutes); return "\(p.time) \(p.period)" }
    static func short(_ window: AllowedAccessWindow) -> String {
        let start = parts(window.startMinutes), end = parts(window.endMinutes)
        let core = start.period == end.period && window.endMinutes > window.startMinutes
            ? "\(start.time)–\(end.time) \(end.period)" : "\(time(window.startMinutes))–\(time(window.endMinutes))"
        // Ending at midnight (12 PM–12 AM) is still the same day, not overnight.
        return window.endMinutes < window.startMinutes && window.endMinutes != 0 ? core + " · overnight" : core
    }
}

enum ShieldGroupKind: String, CaseIterable, Identifiable {
    case social, video, adult, food, custom, location, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .social: return "Social media"
        case .video: return "Video & streaming"
        case .adult: return "Adult content"
        case .food: return "Food ordering"
        case .custom: return "Custom permanent sites"
        case .location: return "Location blocks"
        case .other: return "Other"
        }
    }
    var symbol: String {
        switch self {
        case .social: return "bubble.left.and.bubble.right"
        case .video: return "play.rectangle"
        case .adult: return "hand.raised"
        case .food: return "fork.knife"
        case .custom: return "lock.shield"
        case .location: return "mappin.and.ellipse"
        case .other: return "square.stack"
        }
    }
}

enum ShieldRuleStatus: Equatable {
    case confirmed, protected, overlapping, allowed, permanent, pending, attention, unavailable, preview, scheduled, inactive
    var title: String {
        switch self {
        case .confirmed: return "Confirmed"
        case .protected: return "Protected"
        case .overlapping: return "Other block applies"
        case .allowed: return "Allowed now"
        case .permanent: return "Permanent"
        case .pending: return "Blocking · change pending"
        case .attention: return "Needs attention"
        case .unavailable: return "Unavailable"
        case .preview: return "Preview only"
        case .scheduled: return "Scheduled"
        case .inactive: return "Not active"
        }
    }
}

enum ShieldEvidence: Equatable {
    case confirmed, preview, attention, unavailable

    /// How old the service's last evidence may be: a short reconnect
    /// (`ShieldViewModel.connectionGrace`) plus one poll and a margin.
    static let maximumAge: TimeInterval = ShieldViewModel.connectionGrace + 15

    static func resolve(authority: AuthorityStatus, enforcement: EvidenceState,
                        hasSnapshot: Bool, isLiveService: Bool, observedAt: Date?,
                        generationsMatch: Bool, now: Date) -> Self {
        guard hasSnapshot, case .valid = authority else { return .unavailable }
        guard generationsMatch, let observedAt, abs(now.timeIntervalSince(observedAt)) <= maximumAge else {
            return .attention
        }
        switch enforcement {
        case .unavailable: return .unavailable
        case .mismatch: return .attention
        case .verified: return isLiveService ? .confirmed : .preview
        }
    }

    var status: ShieldRuleStatus {
        switch self {
        case .confirmed: return .confirmed
        case .preview: return .preview
        case .attention: return .attention
        case .unavailable: return .unavailable
        }
    }
}

struct ShieldPendingChange: Identifiable {
    let policyID: String
    let effectiveAt: Date
    let replacementSchedule: DailySchedule?
    var id: String { policyID }
}

struct ShieldRuleGroup: Identifiable {
    let category: ShieldCategory
    var schedules: [DailySchedule] = []
    var restrictions: [DomainRestriction] = []
    var unmatchedChanges: [ShieldPendingChange] = []
    var id: String { category.id }
    /// The built-in category this is, or nil for one the user created.
    var kind: ShieldGroupKind? { ShieldGroupKind(rawValue: category.id) }
    var title: String { category.name }
    var count: Int { schedules.count + restrictions.count + unmatchedChanges.count }
    var domains: Set<String> {
        schedules.reduce(into: Set<String>()) { $0.formUnion($1.domains) }
            .union(restrictions.reduce(into: Set<String>()) { $0.formUnion($1.domains) })
    }
    var summary: String {
        if !schedules.isEmpty && restrictions.isEmpty && unmatchedChanges.isEmpty {
            return "\(schedules.count) daily schedule\(schedules.count == 1 ? "" : "s")"
        }
        if !restrictions.isEmpty && restrictions.allSatisfy({ $0.owner == .permanent }) && schedules.isEmpty {
            return "Always blocked · \(domains.count) websites"
        }
        if count == 0 { return "No websites yet" }
        return "\(count) rule\(count == 1 ? "" : "s")"
    }
}

enum ShieldGrouping {
    // Stable identifiers are authoritative for known plan groups. Exact legacy
    // names are a compatibility fallback; unknown names never disappear.
    static func kind(for schedule: DailySchedule) -> ShieldGroupKind {
        switch schedule.id {
        case "social-afternoon", "social-morning", "social-night", "instagram-afternoon",
             "tiktok-afternoon", "pinterest-afternoon": return .social
        case "youtube-evening", "youtube", "netflix-evening": return .video
        default:
            switch schedule.title {
            case "X / Reddit", "Social feeds", "Instagram", "TikTok", "Pinterest": return .social
            case "YouTube", "Video sites", "Netflix": return .video
            default: return .other
            }
        }
    }

    static func kind(for restriction: DomainRestriction) -> ShieldGroupKind {
        if restriction.placeID != nil { return .location }
        guard restriction.owner == .permanent else { return .other }
        // Every adult chunk (the list is split by size) shows as one Adult group.
        if restriction.policyID.hasPrefix("owner-plan-adult-") { return .adult }
        switch restriction.policyID {
        case "owner-plan-food-1": return .food
        case "owner-plan-custom-1": return .custom
        default: return .other
        }
    }

    /// A block set to a place is always under Location blocks; other rules
    /// follow the user's placement.
    static func categoryID(for restriction: DomainRestriction, layout: ShieldCategoryLayout) -> String {
        restriction.placeID != nil ? ShieldCategoryLayout.locationID
            : layout.categoryID(for: restriction.policyID, defaultKind: kind(for: restriction))
    }

    /// Legacy schedule names only. Rules the user named keep their own name.
    static func title(_ title: String) -> String {
        switch title {
        case "Social feeds": return "X / Reddit"
        case "Video sites": return "YouTube"
        default: return title.hasPrefix("Focus:") ? "Custom block" : title
        }
    }

    /// A rule's own title as shown: legacy names mapped, except for rules the
    /// owner made in Shield ("focus-"), which keep the name they were given.
    static func title(_ title: String, policyID: String) -> String {
        policyID.hasPrefix("focus-") ? title : self.title(title)
    }

    /// Every rule appears in exactly one category, in the user's order.
    /// Empty built-in categories are hidden; empty owner-made ones are kept
    /// when `includeEmpty` so websites can be added to them.
    static func groups(schedules: [DailySchedule], restrictions: [DomainRestriction],
                       pending: [ShieldPendingChange], layout: ShieldCategoryLayout = .default,
                       includeEmpty: Bool = false) -> [ShieldRuleGroup] {
        let layout = layout.normalized()
        let knownIDs = Set(schedules.map(\.id) + restrictions.map(\.policyID))
        return layout.categories.compactMap { category in
            let group = ShieldRuleGroup(category: category,
                schedules: schedules.filter {
                    layout.categoryID(for: $0.id, defaultKind: kind(for: $0)) == category.id
                },
                restrictions: restrictions.filter { categoryID(for: $0, layout: layout) == category.id },
                unmatchedChanges: category.id == ShieldCategoryLayout.otherID
                    ? pending.filter { !knownIDs.contains($0.policyID) } : [])
            return group.count > 0 || (includeEmpty && !category.isBuiltIn) ? group : nil
        }
    }

    static func scheduleStatus(_ schedule: DailySchedule, evidence: ShieldEvidence,
                               effectiveIDs: Set<String>, pendingIDs: Set<String>,
                               otherBlockedDomains: Set<String> = []) -> ShieldRuleStatus {
        guard evidence == .confirmed else { return evidence.status }
        guard schedule.isValid else { return .attention }
        guard schedule.isRequested else { return .inactive }
        if effectiveIDs.contains(schedule.id) { return pendingIDs.contains(schedule.id) ? .pending : .protected }
        return schedule.domains.isDisjoint(with: otherBlockedDomains) ? .allowed : .overlapping
    }

    static func restrictionStatus(_ restriction: DomainRestriction, evidence: ShieldEvidence,
                                  effectiveIDs: Set<String>, pendingIDs: Set<String>, now: Date) -> ShieldRuleStatus {
        guard evidence == .confirmed else { return evidence.status }
        // A pending release never stops blocking early: only say "pending"
        // while the rule is actually blocking.
        if pendingIDs.contains(restriction.policyID) && effectiveIDs.contains(restriction.policyID) { return .pending }
        guard effectiveIDs.contains(restriction.policyID) else {
            return restriction.startsAt.map { $0 > now } == true ? .scheduled : .inactive
        }
        return restriction.owner == .permanent ? .permanent : .protected
    }

    static func groupStatus(_ statuses: [ShieldRuleStatus], evidence: ShieldEvidence) -> ShieldRuleStatus {
        guard evidence == .confirmed else { return evidence.status }
        if statuses.contains(.attention) { return .attention }
        if statuses.contains(.pending) { return .pending }
        if let first = statuses.first, statuses.allSatisfy({ $0 == first }) { return first }
        return .confirmed
    }
}
