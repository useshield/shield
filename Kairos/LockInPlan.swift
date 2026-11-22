import Foundation

/// One Lock In rule: what to restrict, when it's allowed, and for how long.
///
/// This is a presentation-side plan only. It turns the user's choices into
/// the release-242 commands the service already understands (no new schema,
/// no new owner): a timed `.commitment`, a `.permanent` restriction, or a
/// `DailySchedule` plus a release on its end date. Every delay and refusal is
/// still the service's. Blocks without an end, and blocks at a place, are made
/// with New Block (`ShieldViewModel.commitBlock`), not here.
struct LockInPlan: Equatable {
    enum Length: Hashable {
        /// A fixed time from now; ends on its own and can't end early.
        case lasting(TimeInterval)
        /// A chosen end date and time; same rules as `lasting`.
        case until(Date)
        /// Never ends. A Shield-made permanent can be corrected within 72 hours.
        case forever
    }

    enum Access: Equatable {
        /// Blocked all day, every day of the lock.
        case never
        /// Allowed only inside these daily hours.
        case dailyHours(AllowedAccessWindow)
    }

    var title: String
    var domains: Set<String>
    var apps: Set<AppTarget> = []
    var access: Access = .never
    var length: Length = .lasting(3_600)

    // MARK: Limits

    /// The longest timed lock the app offers. The service accepts any future
    /// end; the cap only stops a typo from locking something for decades.
    static let maximumLength: TimeInterval = 90 * 86_400
    /// The service's own per-rule limit.
    static let maximumDomains = 100
    /// A release request must land at least 24 hours after the service
    /// receives it. The extra five minutes cover transit, clock skew and a
    /// Try Again (allowed for up to 290 seconds after the first send).
    static let releaseHeadroom: TimeInterval = 86_700

    /// Few on purpose: anything else is "Pick a date…".
    static let quickLengths: [(label: String, length: Length)] = [
        ("1 hour", .lasting(3_600)),
        ("1 day", .lasting(86_400)),
        ("1 week", .lasting(7 * 86_400)),
    ]

    /// When the lock really ends: the one moment the review shows and the
    /// service enforces. Daily hours end through a release request, which the
    /// service accepts only at least 24 hours out, so a relative length never
    /// lands sooner than `releaseHeadroom` ("1 day" of daily hours ends 24 h
    /// 5 min from now, and the summary says so; under a day is refused). A
    /// chosen date is never moved: one too soon is refused by `problem`.
    func endDate(now: Date) -> Date? {
        switch length {
        case .lasting(let seconds):
            if case .dailyHours = access { return now.addingTimeInterval(max(seconds, Self.releaseHeadroom)) }
            return now.addingTimeInterval(seconds)
        case .until(let date): return date
        case .forever: return nil
        }
    }

    /// Lock In's daily hours get their own ID prefix, so the app never offers
    /// to cancel the end that makes them "can't be ended early" (the service
    /// would accept that as a stricter change, then a 24-hour removal).
    static let schedulePrefix = "lockin-"
    static func isLockIn(_ policyID: String) -> Bool { policyID.hasPrefix(schedulePrefix) }

    // MARK: What the release-242 engine can hold

    /// Why this plan can't be locked in as chosen, or nil when it can.
    func problem(now: Date) -> String? {
        if domains.isEmpty && apps.isEmpty { return "Choose websites or apps." }
        if domains.count > Self.maximumDomains { return "Up to \(Self.maximumDomains) websites in one lock." }
        if apps.count > PolicyValidation.maximumApps { return "Up to \(PolicyValidation.maximumApps) apps in one lock." }
        if !PolicyValidation.validTargets(domains: domains, apps: apps) { return "Some websites aren't valid." }
        if let end = endDate(now: now) {
            if end <= now.addingTimeInterval(60) { return "Choose an end in the future." }
            if end.timeIntervalSince(now) > Self.maximumLength { return "Locks can last up to 90 days." }
        }
        if case .dailyHours = access {
            switch length {
            case .forever:
                return "Daily hours can always be removed with 24 hours' notice, so they can't be forever."
            case .lasting(let seconds) where seconds < 86_400:
                return "Daily hours need to last at least a day."
            case .lasting, .until:
                // The service's own minimum notice for a release, so the end shown is the end enforced.
                if let end = endDate(now: now), end < now.addingTimeInterval(Self.releaseHeadroom) {
                    return "Daily hours need to last at least a day."
                }
            }
        }
        return nil
    }

    // MARK: Commands

    /// The commands for one atomic request, or nil when `problem` isn't nil.
    /// `id` makes the policy identifier deterministic for tests.
    func commands(now: Date, id: UUID = UUID()) -> (policyID: String, commands: [BackendCommand])? {
        guard problem(now: now) == nil else { return nil }
        let name = Self.cleanTitle(title)
        switch access {
        case .dailyHours(let window):
            // Stored hours are the BLOCKED complement of the allowed window.
            let schedule = window.blockedSchedule(basedOn: DailySchedule(
                id: "\(Self.schedulePrefix)\(id.uuidString)", title: name, domains: domains,
                startMinutes: 0, endMinutes: 1, isRequested: true, apps: apps))
            guard schedule.isValid else { return nil }
            // Exactly the end the summary showed; `problem` already holds it to
            // the service's 24-hour minimum, so nothing is moved here.
            guard let end = endDate(now: now) else { return nil }
            return (schedule.id, [.add(schedule), .release(schedule.id, at: end)])
        case .never:
            // "focus-" keeps the existing 72-hour correction for Shield-made permanents.
            let rule = DomainRestriction(owner: length == .forever ? .permanent : .commitment,
                                         policyID: "focus-\(id.uuidString)", title: name, domains: domains,
                                         startsAt: now, endsAt: endDate(now: now), apps: apps)
            return (rule.policyID, [.add(rule)])
        }
    }

    static func cleanTitle(_ title: String) -> String {
        let trimmed = ShieldCategoryLayout.cleanName(title)
        return trimmed.isEmpty ? "Lock" : trimmed
    }

    // MARK: Wording

    static func endText(_ date: Date, now: Date, calendar: Calendar) -> String {
        var time = Date.FormatStyle(date: .omitted, time: .shortened)
        time.timeZone = calendar.timeZone
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(date.formatted(time))" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "tomorrow at \(date.formatted(time))"
        }
        var day = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        day.timeZone = calendar.timeZone
        return "\(date.formatted(day)) at \(date.formatted(time))"
    }
}

/// One website or app in a Lock In, with its own "when it's allowed".
/// A Lock In can block one site outright and give another daily hours.
struct LockInItem: Identifiable, Equatable {
    enum Target: Equatable {
        case website(String)
        case app(AppTarget)
    }
    let id: UUID
    var target: Target
    var access: LockInPlan.Access

    init(id: UUID = UUID(), target: Target, access: LockInPlan.Access = .never) {
        self.id = id
        self.target = target
        self.access = access
    }

    var name: String {
        switch target {
        case .website(let domain): domain
        case .app(let app): app.displayName
        }
    }
}

extension LockInPlan {
    /// One plan per distinct "when it's allowed": every fully blocked item
    /// shares one rule; each set of daily hours gets its own schedule. All the
    /// rules end at one moment: with any daily hours, a relative length is
    /// held to the service's release minimum for every rule, so the lock has
    /// a single end and the summary can name it.
    static func plans(for items: [LockInItem], length: Length) -> [LockInPlan] {
        let hasHours = items.contains { if case .dailyHours = $0.access { true } else { false } }
        var shared = length
        // Only a day or more is stretched (to 24 h 5 min); anything shorter stays
        // as chosen so the daily-hours rule refuses it rather than silently growing.
        if hasHours, case .lasting(let seconds) = length, seconds >= 86_400 {
            shared = .lasting(max(seconds, releaseHeadroom))
        }
        var groups: [(access: Access, items: [LockInItem])] = []
        for item in items {
            if let index = groups.firstIndex(where: { $0.access == item.access }) {
                groups[index].items.append(item)
            } else {
                groups.append((item.access, [item]))
            }
        }
        return groups.map { group in
            var domains = Set<String>()
            var apps = Set<AppTarget>()
            for item in group.items {
                switch item.target {
                case .website(let domain): domains.formUnion(WebsiteListParser.withWWW([domain]))
                case .app(let app): apps.insert(app)
                }
            }
            let names = group.items.map(\.name)
            let title = names.count > 1 ? "\(names[0]) + \(names.count - 1) more" : names.first ?? "Lock"
            return LockInPlan(title: title, domains: domains, apps: apps, access: group.access, length: shared)
        }
    }

    /// The whole Lock In in plain words, said before anything is locked:
    /// what happens to each site, then when it ends and whether it can end early.
    /// "reddit.com is blocked all day. youtube.com is allowed only from 6 PM to
    /// 8 PM, blocked the rest of the day. Both stay locked until tomorrow at
    /// 10:01 AM and can't be ended early."
    /// `removalWait`: the service's permanent removal wait (1.1); nil from an older one.
    static func summary(for items: [LockInItem], plans: [LockInPlan], now: Date, calendar: Calendar,
                        removalWait: TimeInterval? = nil) -> String? {
        guard !items.isEmpty, let first = plans.first else { return nil }
        var groups: [(access: Access, names: [String])] = []
        for item in items {
            if let index = groups.firstIndex(where: { $0.access == item.access }) {
                groups[index].names.append(item.name)
            } else {
                groups.append((item.access, [item.name]))
            }
        }
        var sentences = groups.map { group -> String in
            let subject = listed(group.names) + (group.names.count == 1 ? " is" : " are")
            switch group.access {
            case .never:
                return "\(subject) blocked all day."
            case .dailyHours(let window):
                return "\(subject) allowed only from \(ScheduleText.time(window.startMinutes)) to " +
                    "\(ScheduleText.time(window.endMinutes)), blocked the rest of the day."
            }
        }
        let count = items.count
        let all = count == 1 ? "It" : count == 2 ? "Both" : "All \(count)"
        switch first.length {
        case .forever:
            if let removalWait {
                sentences.append("\(all) \(count == 1 ? "is" : "are") locked until you remove " +
                    "\(count == 1 ? "it" : "them"), which takes \(PermanentRemovalPolicy.describe(removalWait)). " +
                    "A mistake can be undone within 10 minutes.")
            } else {
                sentences.append("\(all) \(count == 1 ? "is" : "are") locked forever. A mistake can be fixed within 72 hours.")
            }
        case .lasting, .until:
            guard let end = plans.compactMap({ $0.endDate(now: now) }).max() else { return nil }
            sentences.append("\(all) \(count == 1 ? "stays" : "stay") locked until " +
                "\(endText(end, now: now, calendar: calendar)) and can't be ended early.")
        }
        return sentences.joined(separator: " ")
    }

    /// "a", "a and b", "a, b and c", "a, b and 3 more".
    static func listed(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        case 3: return "\(names[0]), \(names[1]) and \(names[2])"
        default: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
        }
    }
}
