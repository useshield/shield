import Foundation
import Testing
@testable import Shield

// Lock In is a presentation plan over the release-242 engine. These tests run
// every supported shape through the real FixtureBackend (the same engine the
// root service runs) and prove the old guarantees still hold: timed locks
// can't end early, permanent can't be released, removals wait 24 hours, a
// place lock fails closed, and nothing touches other rules.
struct LockInPlanTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 10, minute: 0))!
    }

    private func backend(startingAt start: Date? = nil) throws -> FixtureBackend {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LockIn-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
        let backend = try FixtureBackend(root: root)
        // The engine refuses an empty first policy, so start like a real Mac:
        // one unrelated permanent rule already in place.
        _ = try backend.apply(request(0, [.add(DomainRestriction(owner: .permanent, policyID: "baseline",
                                                                 title: "Baseline", domains: ["baseline.example"]))],
                                      at: start ?? now), now: start ?? now, calendar: calendar)
        return backend
    }

    private func request(_ generation: UInt64, _ commands: [BackendCommand], at date: Date) -> BackendRequest {
        BackendRequest(version: 1, id: UUID(), expectedGeneration: generation, submittedAt: date, commands: commands)
    }

    @discardableResult
    private func lockIn(_ plan: LockInPlan, on backend: FixtureBackend, at date: Date) throws -> String {
        let built = try #require(plan.commands(now: date))
        let generation = try backend.snapshot(now: date, calendar: calendar).generation
        _ = try backend.apply(request(generation, built.commands, at: date), now: date, calendar: calendar)
        return built.policyID
    }

    private func blocked(_ backend: FixtureBackend, at date: Date) throws -> Set<String> {
        _ = try backend.tick(now: date, calendar: calendar)
        return try backend.snapshot(now: date, calendar: calendar).authority.effectiveRestrictions
            .reduce(into: Set<String>()) { $0.formUnion($1.domains) }
    }

    private func refuses(_ backend: FixtureBackend, _ commands: [BackendCommand], at date: Date) throws -> Bool {
        let generation = try backend.snapshot(now: date, calendar: calendar).generation
        do {
            _ = try backend.apply(request(generation, commands, at: date), now: date, calendar: calendar)
            return false
        } catch { return true }
    }

    // MARK: Timed

    @Test func aFourWeekLockBlocksNowCantEndEarlyAndEndsOnItsOwn() throws {
        let backend = try backend()
        let plan = LockInPlan(title: "Netflix", domains: ["netflix.com", "nflxvideo.net"],
                              length: .lasting(28 * 86_400))
        let id = try lockIn(plan, on: backend, at: now)
        let rule = try #require(try backend.snapshot(now: now, calendar: calendar).committedRestrictions
            .first { $0.policyID == id })
        #expect(rule.owner == .commitment)
        #expect(rule.endsAt == now.addingTimeInterval(28 * 86_400))
        #expect(try blocked(backend, at: now).isSuperset(of: plan.domains))
        // No release request, even with the full 24-hour notice.
        #expect(try refuses(backend, [.release(id, at: now.addingTimeInterval(86_460))], at: now))
        // Still blocked one minute before the end; gone one minute after.
        let end = now.addingTimeInterval(28 * 86_400)
        #expect(try blocked(backend, at: end.addingTimeInterval(-60)).contains("nflxvideo.net"))
        #expect(try !blocked(backend, at: end.addingTimeInterval(60)).contains("nflxvideo.net"))
    }

    @Test func aChosenEndDateIsExactAndCappedAtNinetyDays() throws {
        let end = now.addingTimeInterval(10 * 86_400 + 1_234)
        let plan = LockInPlan(title: "x", domains: ["example.org"], length: .until(end))
        #expect(plan.problem(now: now) == nil)
        let built = try #require(plan.commands(now: now))
        #expect(built.commands.first?.restriction?.endsAt == end)
        #expect(LockInPlan(title: "x", domains: ["example.org"], length: .until(now.addingTimeInterval(91 * 86_400)))
            .problem(now: now) != nil)
        #expect(LockInPlan(title: "x", domains: ["example.org"], length: .until(now.addingTimeInterval(-60)))
            .problem(now: now) != nil)
    }

    // MARK: Forever

    @Test func foreverIsPermanentAndRefusesRelease() throws {
        let backend = try backend()
        let id = try lockIn(LockInPlan(title: "Jumpstream", domains: ["jumpstream.com"], length: .forever), on: backend, at: now)
        let rule = try #require(try backend.snapshot(now: now, calendar: calendar).committedRestrictions
            .first { $0.policyID == id })
        #expect(rule.owner == .permanent && rule.endsAt == nil)
        #expect(id.hasPrefix("focus-"), "keeps the existing 72-hour correction path")
        #expect(try refuses(backend, [.release(id, at: now.addingTimeInterval(86_460))], at: now))
    }

    // MARK: Daily hours

    @Test func dailyHoursAreAScheduleStoredAsItsBlockedComplement() throws {
        let window = try #require(AllowedAccessWindow(startMinutes: 19 * 60, endMinutes: 20 * 60))
        let plan = LockInPlan(title: "YouTube", domains: ["youtube.com", "youtu.be"], access: .dailyHours(window),
                              length: .lasting(7 * 86_400))
        let built = try #require(plan.commands(now: now))
        #expect(built.commands.count == 2, "the schedule and its one end")
        let schedule = try #require(built.commands.first?.schedule)
        // Allowed 7–8 PM is stored as blocked 8 PM → 7 PM. Never inverted.
        #expect(schedule.startMinutes == 20 * 60 && schedule.endMinutes == 19 * 60)
        let backend = try backend()
        try lockIn(plan, on: backend, at: now)
        let at = { (hour: Int, minute: Int) in
            self.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: self.now)!
        }
        #expect(try blocked(backend, at: at(18, 59)).contains("youtu.be"))
        #expect(try !blocked(backend, at: at(19, 30)).contains("youtu.be"))
        #expect(try blocked(backend, at: at(20, 1)).contains("youtu.be"))
    }

    @Test func dailyHoursWithAnEndAddAScheduledRemovalThatCantComeSooner() throws {
        let window = try #require(AllowedAccessWindow(startMinutes: 14 * 60, endMinutes: 20 * 60))
        let end = now.addingTimeInterval(28 * 86_400)
        let plan = LockInPlan(title: "X", domains: ["x.com", "t.co"], access: .dailyHours(window), length: .until(end))
        let backend = try backend()
        let id = try lockIn(plan, on: backend, at: now)
        let snapshot = try backend.snapshot(now: now, calendar: calendar)
        #expect(snapshot.committedSchedules.map(\.id) == [id])
        #expect(snapshot.pendingReleases.map(\.policyID) == [id])
        #expect(snapshot.pendingReleases.first?.effectiveAt == end)
        // A second, earlier removal can't be queued on top of it.
        #expect(try refuses(backend, [.release(id, at: now.addingTimeInterval(86_460))], at: now))
        // Cancelling the end would let the schedule be removed 24 h later, so
        // the service itself refuses it, not just the app.
        #expect(LockInPlan.isLockIn(id) && id.hasPrefix("lockin-"))
        #expect(try refuses(backend, [.cancelPending(id)], at: now))
        #expect(try backend.snapshot(now: now, calendar: calendar).pendingReleases.map(\.policyID) == [id])
    }

    @Test func dailyHoursEndingTomorrowNeverRequestALessThan24HourRemoval() throws {
        let window = try #require(AllowedAccessWindow(startMinutes: 14 * 60, endMinutes: 20 * 60))
        let plan = LockInPlan(title: "X", domains: ["x.com"], access: .dailyHours(window), length: .lasting(86_400))
        let built = try #require(plan.commands(now: now))
        let release = try #require(built.commands.last)
        #expect(release.kind == .requestRelease)
        #expect(try #require(release.effectiveAt) >= now.addingTimeInterval(86_400))
        try lockIn(plan, on: try backend(), at: now)
    }

    // MARK: The end shown is the end enforced (release-headroom boundary)

    @Test func oneDayOfDailyHoursEndsExactlyWhenTheReviewSays() throws {
        let window = try #require(AllowedAccessWindow(startMinutes: 14 * 60, endMinutes: 20 * 60))
        let plan = LockInPlan(title: "X", domains: ["x.com"], access: .dailyHours(window), length: .lasting(86_400))
        // The service needs 24 h notice for a release, so "1 day" of daily hours is 24 h 5 min.
        let shown = try #require(plan.endDate(now: now))
        #expect(shown == now.addingTimeInterval(LockInPlan.releaseHeadroom))
        let item = LockInItem(target: .website("x.com"), access: .dailyHours(window))
        #expect(LockInPlan.summary(for: [item], plans: [plan], now: now, calendar: calendar)?
            .contains("stays locked until tomorrow at 10:05") == true)
        // The release the service holds is that same moment, to the second.
        let built = try #require(plan.commands(now: now))
        #expect(built.commands.last?.effectiveAt == shown)
        let backend = try backend()
        let id = try lockIn(plan, on: backend, at: now)
        #expect(try backend.snapshot(now: now, calendar: calendar).pendingReleases.first { $0.policyID == id }?
            .effectiveAt == shown)
        // 10 AM is outside the allowed hours: blocked until the shown end, then gone.
        #expect(try blocked(backend, at: shown.addingTimeInterval(-60)).contains("x.com"))
        #expect(try !blocked(backend, at: shown.addingTimeInterval(60)).contains("x.com"))
    }

    @Test func aChosenEndForDailyHoursIsKeptExactlyOrRefusedNeverMoved() throws {
        let window = try #require(AllowedAccessWindow(startMinutes: 14 * 60, endMinutes: 20 * 60))
        func plan(_ end: Date) -> LockInPlan {
            LockInPlan(title: "X", domains: ["x.com"], access: .dailyHours(window), length: .until(end))
        }
        // Exactly the service's minimum notice: accepted, released at that very second.
        let earliest = now.addingTimeInterval(LockInPlan.releaseHeadroom)
        #expect(plan(earliest).problem(now: now) == nil)
        #expect(plan(earliest).commands(now: now)?.commands.last?.effectiveAt == earliest)
        try lockIn(plan(earliest), on: try backend(), at: now)
        // A second short of it, or exactly 24 h: refused rather than silently moved later.
        for end in [earliest.addingTimeInterval(-1), now.addingTimeInterval(86_400)] {
            #expect(plan(end).problem(now: now) == "Daily hours need to last at least a day.")
            #expect(plan(end).commands(now: now) == nil)
        }
        // A later date is kept to the second.
        let later = now.addingTimeInterval(3 * 86_400 + 777)
        #expect(plan(later).commands(now: now)?.commands.last?.effectiveAt == later)
        #expect(plan(later).endDate(now: now) == later)
    }

    @Test func aOneDayBlockEndsExactlyOneDayOutWithNoReleaseRequest() throws {
        // Without daily hours a timed lock is one rule with its own end; no headroom applies.
        let plan = LockInPlan(title: "x", domains: ["x.com"], length: .lasting(86_400))
        #expect(plan.endDate(now: now) == now.addingTimeInterval(86_400))
        let built = try #require(plan.commands(now: now))
        #expect(built.commands.count == 1)
        #expect(LockInPlan.summary(for: [LockInItem(target: .website("x.com"))], plans: [plan], now: now,
                                   calendar: calendar)?.contains("until tomorrow at 10:00") == true)
    }

    @Test func unsupportedDailyHourShapesAreRefusedBeforeSubmitting() throws {
        let window = try #require(AllowedAccessWindow(startMinutes: 14 * 60, endMinutes: 20 * 60))
        let forever = LockInPlan(title: "x", domains: ["x.com"], access: .dailyHours(window), length: .forever)
        #expect(forever.problem(now: now) != nil && forever.commands(now: now) == nil)
        let short = LockInPlan(title: "x", domains: ["x.com"], access: .dailyHours(window), length: .lasting(14_400))
        #expect(short.problem(now: now) != nil)
    }

    @Test func anOvernightWindowIsStoredAsItsDaytimeComplement() throws {
        // Allowed 10 PM–2 AM is stored as blocked 2 AM → 10 PM, never inverted.
        let window = try #require(AllowedAccessWindow(startMinutes: 22 * 60, endMinutes: 2 * 60))
        let plan = LockInPlan(title: "Late", domains: ["late.example"], access: .dailyHours(window), length: .lasting(7 * 86_400))
        let schedule = try #require(plan.commands(now: now)?.commands.first?.schedule)
        #expect(schedule.startMinutes == 2 * 60 && schedule.endMinutes == 22 * 60)
        let backend = try backend()
        try lockIn(plan, on: backend, at: now)
        let at = { (hour: Int) in self.calendar.date(bySettingHour: hour, minute: 30, second: 0, of: self.now)! }
        #expect(try blocked(backend, at: at(15)).contains("late.example"))
        #expect(try !blocked(backend, at: at(23)).contains("late.example"))
    }

    @Test func dailyHoursKeepTheirWallClockAcrossTheFallDSTChange() throws {
        // Nov 1 2026 is the Eastern fall-back day: allowed 2–8 PM stays 2–8 PM local.
        let window = try #require(AllowedAccessWindow(startMinutes: 14 * 60, endMinutes: 20 * 60))
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 9))!
        let plan = LockInPlan(title: "X", domains: ["dst.example"], access: .dailyHours(window), length: .lasting(7 * 86_400))
        let backend = try backend(startingAt: start)
        try lockIn(plan, on: backend, at: start)
        let sunday = { (hour: Int) in self.calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: hour, minute: 30))! }
        #expect(try blocked(backend, at: sunday(13)).contains("dst.example"))
        #expect(try !blocked(backend, at: sunday(14)).contains("dst.example"))
        #expect(try blocked(backend, at: sunday(20)).contains("dst.example"))
    }

    @Test func anAppsOnlyLockGoesThroughTheEngine() throws {
        let chess = AppTarget(displayName: "Chess", bundleID: "com.apple.Chess", teamID: nil)
        let plan = LockInPlan(title: "Chess", domains: [], apps: [chess], length: .lasting(3_600))
        #expect(plan.problem(now: now) == nil)
        let backend = try backend()
        let id = try lockIn(plan, on: backend, at: now)
        let rule = try #require(try backend.snapshot(now: now, calendar: calendar).committedRestrictions
            .first { $0.policyID == id })
        #expect(rule.apps == [chess] && rule.owner == .commitment)
    }

    @Test func aTypedWWWAddressAlsoBlocksItsRoot() {
        #expect(WebsiteListParser.withWWW(["www.tumblr.com"]) == ["www.tumblr.com", "tumblr.com"])
        #expect(WebsiteListParser.withWWW(["tumblr.com"]) == ["www.tumblr.com", "tumblr.com"])
        // Deeper hosts stay exact.
        #expect(WebsiteListParser.withWWW(["www.i.redd.it"]) == ["www.i.redd.it"])
    }

    // MARK: Targets, limits, other rules

    // MARK: One Lock In, a rule per site

    @discardableResult
    private func submitAll(_ plans: [LockInPlan], on backend: FixtureBackend, at date: Date) throws -> [String] {
        var commands: [BackendCommand] = []
        var ids: [String] = []
        for plan in plans {
            let built = try #require(plan.commands(now: date))
            commands += built.commands
            ids.append(built.policyID)
        }
        // One atomic request, exactly as the view model sends it.
        let generation = try backend.snapshot(now: date, calendar: calendar).generation
        _ = try backend.apply(request(generation, commands, at: date), now: date, calendar: calendar)
        return ids
    }

    @Test func oneLockInCanBlockOneSiteAndGiveAnotherDailyHours() throws {
        let evening = try #require(AllowedAccessWindow(startMinutes: 18 * 60, endMinutes: 20 * 60))
        let items = [LockInItem(target: .website("reddit.com")),
                     LockInItem(target: .website("youtube.com"), access: .dailyHours(evening))]
        let plans = LockInPlan.plans(for: items, length: .lasting(86_400))
        #expect(plans.count == 2)
        let blockedPlan = try #require(plans.first { $0.access == .never })
        let hoursPlan = try #require(plans.first { $0.access == .dailyHours(evening) })
        #expect(blockedPlan.domains == ["reddit.com", "www.reddit.com"])
        #expect(hoursPlan.domains == ["youtube.com", "www.youtube.com"])
        // One end for the whole lock: the daily-hours minimum, shown and enforced.
        let end = now.addingTimeInterval(LockInPlan.releaseHeadroom)
        #expect(plans.allSatisfy { $0.endDate(now: now) == end })
        let summary = try #require(LockInPlan.summary(for: items, plans: plans, now: now, calendar: calendar))
        #expect(summary.hasPrefix("reddit.com is blocked all day. youtube.com is allowed only from 6 PM to 8 PM, " +
                                  "blocked the rest of the day. Both stay locked until tomorrow at 10:05"))
        #expect(summary.hasSuffix("and can't be ended early."))

        let backend = try backend()
        try submitAll(plans, on: backend, at: now)
        // 10 AM: both blocked. 7 PM: Reddit still blocked, YouTube in its allowed hours.
        let morning = try blocked(backend, at: now.addingTimeInterval(60))
        #expect(morning.isSuperset(of: ["reddit.com", "www.reddit.com", "youtube.com", "www.youtube.com"]))
        let sevenPM = try blocked(backend, at: now.addingTimeInterval(9 * 3_600))
        #expect(sevenPM.contains("reddit.com"))
        #expect(!sevenPM.contains("youtube.com"))
        // Both end at the one time shown, not before.
        #expect(try blocked(backend, at: end.addingTimeInterval(-60)).contains("reddit.com"))
        let after = try blocked(backend, at: end.addingTimeInterval(60))
        #expect(!after.contains("reddit.com") && !after.contains("youtube.com"))
    }

    @Test func sitesWithTheSameRuleShareOneRule() throws {
        let hours = try #require(AllowedAccessWindow(startMinutes: 14 * 60, endMinutes: 20 * 60))
        let items = [LockInItem(target: .website("a.example.com")), LockInItem(target: .website("b.com")),
                     LockInItem(target: .website("c.com"), access: .dailyHours(hours)),
                     LockInItem(target: .website("d.com"), access: .dailyHours(hours))]
        let plans = LockInPlan.plans(for: items, length: .lasting(7 * 86_400))
        #expect(plans.count == 2)
        #expect(plans[0].domains == ["a.example.com", "b.com", "www.b.com"])
        #expect(plans[1].domains == ["c.com", "www.c.com", "d.com", "www.d.com"])
        #expect(plans.allSatisfy { $0.endDate(now: now) == now.addingTimeInterval(7 * 86_400) })
        try submitAll(plans, on: try backend(), at: now)
    }

    @Test func dailyHoursUnderADayAreRefusedNotStretched() throws {
        let hours = try #require(AllowedAccessWindow(startMinutes: 14 * 60, endMinutes: 20 * 60))
        let items = [LockInItem(target: .website("a.com")), LockInItem(target: .website("b.com"), access: .dailyHours(hours))]
        let plans = LockInPlan.plans(for: items, length: .lasting(3_600))
        #expect(plans.contains { $0.problem(now: now) != nil })
        // Without daily hours, an hour is an hour.
        let plain = LockInPlan.plans(for: [items[0]], length: .lasting(3_600))
        #expect(plain.first?.endDate(now: now) == now.addingTimeInterval(3_600))
    }

    @Test func summarySaysWhatHappensToEachSiteAndWhenItEnds() throws {
        let one = [LockInItem(target: .website("a.com"))]
        let forever = LockInPlan.plans(for: one, length: .forever)
        #expect(LockInPlan.summary(for: one, plans: forever, now: now, calendar: calendar) ==
                "a.com is blocked all day. It is locked forever. A mistake can be fixed within 72 hours.")
        #expect(LockInPlan.summary(for: one, plans: forever, now: now, calendar: calendar, removalWait: 259_200) ==
                "a.com is blocked all day. It is locked until you remove it, which takes 3 days. "
                + "A mistake can be undone within 10 minutes.")
        let hours = try #require(AllowedAccessWindow(startMinutes: 22 * 60, endMinutes: 2 * 60))
        let many = ["a.com", "b.com", "c.com", "d.com"].map { LockInItem(target: .website($0)) } +
            [LockInItem(target: .website("e.com"), access: .dailyHours(hours))]
        let week = LockInPlan.plans(for: many, length: .lasting(7 * 86_400))
        let text = try #require(LockInPlan.summary(for: many, plans: week, now: now, calendar: calendar))
        #expect(text.hasPrefix("a.com, b.com and 2 more are blocked all day. " +
                               "e.com is allowed only from 10 PM to 2 AM, blocked the rest of the day. All 5 stay locked until "))
        #expect(LockInPlan.summary(for: [], plans: [], now: now, calendar: calendar) == nil)
        #expect(LockInPlan.listed(["a", "b", "c"]) == "a, b and c")
    }

    @Test func limitsAndEmptyPlans() throws {
        #expect(LockInPlan(title: "x", domains: []).problem(now: now) != nil)
        let many = Set((0..<101).map { "site\($0).example" })
        #expect(LockInPlan(title: "x", domains: many).problem(now: now) != nil)
        #expect(LockInPlan(title: "x", domains: Set(many.prefix(100))).problem(now: now) == nil)
    }

    @Test func aLockNeverChangesOtherRules() throws {
        let backend = try backend()
        let hours = DailySchedule(id: "social-afternoon", title: "X / Reddit", domains: ["x.com", "t.co"],
                                  startMinutes: 1200, endMinutes: 840, isRequested: true)
        let permanent = DomainRestriction(owner: .permanent, policyID: "owner-plan-custom-1", title: "Custom",
                                          domains: ["jumpstream.com"], startsAt: now)
        let generation = try backend.snapshot(now: now, calendar: calendar).generation
        _ = try backend.apply(request(generation, [.add(hours), .add(permanent)], at: now), now: now,
                              calendar: calendar)
        let before = try backend.snapshot(now: now, calendar: calendar)
        try lockIn(LockInPlan(title: "X", domains: ["x.com", "t.co"], length: .lasting(7 * 86_400)),
                   on: backend, at: now)
        let after = try backend.snapshot(now: now, calendar: calendar)
        #expect(after.committedSchedules == before.committedSchedules)
        #expect(after.committedRestrictions.contains(permanent))
        #expect(after.pendingReleases == before.pendingReleases)
        // During the base schedule's allowed hours, the stricter lock wins.
        let afternoon = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: now)!
        #expect(try blocked(backend, at: afternoon).contains("t.co"))
    }
}
