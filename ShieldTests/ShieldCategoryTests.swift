import Foundation
import Testing
@testable import Shield

struct ShieldCategoryLayoutTests {
    private func schedule(_ id: String, title: String) -> DailySchedule {
        DailySchedule(id: id, title: title, domains: ["\(id).example"], startMinutes: 1200, endMinutes: 840,
                      isRequested: true)
    }

    @Test func placementMovesRulesAndDeletedBuiltInsFallBackToOther() {
        var layout = ShieldCategoryLayout.default
        let games = ShieldCategory.new(name: "Games", symbol: "gamecontroller.fill", color: .purple)
        layout.upsert(games)
        let tumblr = DomainRestriction(owner: .permanent, policyID: "focus-tumblr", title: "Tumblr",
                                       domains: ["tumblr.com"], startsAt: .now)
        let instagram = schedule("instagram-afternoon", title: "Instagram")
        layout.place(["focus-tumblr"], in: games.id)
        var groups = ShieldGrouping.groups(schedules: [instagram], restrictions: [tumblr], pending: [], layout: layout)
        #expect(groups.map(\.id) == ["social", games.id])
        #expect(groups[1].restrictions.map(\.policyID) == ["focus-tumblr"])
        // Games sits before Other blocks, after the built-ins.
        #expect(layout.categories.map(\.id).suffix(2) == [games.id, "other"])

        layout.delete("social")
        groups = ShieldGrouping.groups(schedules: [instagram], restrictions: [tumblr], pending: [], layout: layout)
        #expect(groups.map(\.id) == [games.id, "other"])
        #expect(groups[1].schedules.map(\.id) == ["instagram-afternoon"], "A deleted category never hides a rule.")

        layout.delete(games.id)
        groups = ShieldGrouping.groups(schedules: [instagram], restrictions: [tumblr], pending: [], layout: layout)
        #expect(groups.map(\.id) == ["other"])
        #expect(groups[0].count == 2)
        layout.delete("other")
        #expect(layout.category("other") != nil, "Other blocks cannot be deleted.")
    }

    @Test func emptyOwnerCategoriesShowOnlyWhenRequestedAndNormalizationRepairs() {
        var layout = ShieldCategoryLayout.default
        let empty = ShieldCategory.new(name: "Later", symbol: "moon.fill", color: .indigo)
        layout.upsert(empty)
        #expect(ShieldGrouping.groups(schedules: [], restrictions: [], pending: [], layout: layout).isEmpty)
        let shown = ShieldGrouping.groups(schedules: [], restrictions: [], pending: [], layout: layout,
                                          includeEmpty: true)
        #expect(shown.map(\.id) == [empty.id])
        #expect(shown[0].summary == "No websites yet")

        let broken = ShieldCategoryLayout(categories: [
            ShieldCategory(id: "a", name: "  ", symbol: "not.a.symbol", color: .red, members: ["x", "x"]),
            ShieldCategory(id: "a", name: "Duplicate", symbol: "globe", color: .red, members: []),
            ShieldCategory(id: "b", name: String(repeating: "n", count: 90), symbol: "globe", color: .red, members: ["x"]),
        ]).normalized()
        #expect(broken.categories.map(\.id) == ["a", "b", "location", "other"])
        #expect(broken.categories[0].name == "Category")
        #expect(broken.categories[0].symbol == "square.stack.fill")
        #expect(broken.categories[0].members == ["x"])
        #expect(broken.categories[1].members.isEmpty, "A rule has one placement.")
        #expect(broken.categories[1].name.count == ShieldCategory.maximumNameLength)
    }

    @Test func blocksSetToAPlaceHaveTheirOwnCategory() {
        var layout = ShieldCategoryLayout.default
        let games = ShieldCategory.new(name: "Games", symbol: "gamecontroller.fill", color: .purple)
        layout.upsert(games)
        let atLibrary = DomainRestriction(owner: .commitment, policyID: "focus-library", title: "netflix.com",
                                          domains: ["netflix.com"], startsAt: .now, placeID: "library")
        let plain = DomainRestriction(owner: .commitment, policyID: "focus-plain", title: "jumpstream.com",
                                      domains: ["jumpstream.com"], startsAt: .now)
        #expect(ShieldGrouping.groups(schedules: [], restrictions: [plain], pending: [], layout: layout)
            .map(\.id) == ["other"], "Location blocks is hidden while it has no blocks")

        // An old placement can't pull a place block out, and nothing else can be put in.
        layout.place(["focus-library"], in: games.id)
        layout.place(["focus-plain"], in: ShieldCategoryLayout.locationID)
        let groups = ShieldGrouping.groups(schedules: [], restrictions: [atLibrary, plain], pending: [], layout: layout)
        #expect(groups.map(\.id) == ["location", "other"])
        #expect(groups[0].restrictions == [atLibrary])
        #expect(groups[0].kind == .location && groups[0].title == "Location blocks")

        layout.delete(ShieldCategoryLayout.locationID)
        #expect(layout.category("location") != nil, "Location blocks cannot be deleted.")

        // A layout saved before Location blocks existed gets it just before Other.
        let saved = ShieldCategoryLayout(categories: [.builtIn(.social), games, .builtIn(.other)]).normalized()
        #expect(saved.categories.map(\.id) == ["social", games.id, "location", "other"])
    }

    @Test func storeRoundTripsAndIgnoresUnreadableFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldCategories-\(UUID())")
        let store = ShieldCategoryStore(fileURL: root.appendingPathComponent("categories.json"))
        #expect(store.load() == .default)
        var layout = ShieldCategoryLayout.default
        layout.upsert(.new(name: "Shopping", symbol: "cart.fill", color: .orange))
        try store.save(layout)
        #expect(store.load() == layout.normalized())
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.load() == .default)
    }

    @Test func websiteListAcceptsCommasSpacesAndPastedAddresses() {
        #expect(WebsiteListParser.domains("Tumblr.com, www.tumblr.com\nhttps://m.tumblr.com/dashboard")
                == ["tumblr.com", "www.tumblr.com", "m.tumblr.com"])
        #expect(WebsiteListParser.domains("") == nil)
        #expect(WebsiteListParser.domains("not a domain!") == nil)
    }
}

@MainActor
struct ShieldCategoryActionTests {
    /// `beforeOnePointOne`: the blocks were made by a Shield older than 1.1,
    /// then the model runs on 1.1.
    private func makeModel(_ commands: [BackendCommand], at now: Date,
                           beforeOnePointOne: Bool = false) throws -> (ShieldViewModel, FixtureBackend, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldCategoryActions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try Data("127.0.0.1 localhost\n".utf8).write(to: root.appendingPathComponent("hosts"))
        var seeding = try FixtureBackend(root: root)
        seeding.writesPreRemovalDocuments = beforeOnePointOne
        _ = try seeding.apply(BackendRequest(version: 1, id: UUID(), expectedGeneration: 0, submittedAt: now,
                                             commands: commands), now: now, calendar: .current)
        let backend = try FixtureBackend(root: root)
        let model = ShieldViewModel(authorityReader: AuthorityStateReader(fileURL: backend.paths.authority),
                                    enforcementReader: HostsEnforcementReader(fileURL: backend.paths.hosts),
                                    studyLibraryRoot: root.appendingPathComponent("study"),
                                    fixtureBackend: backend)
        model.refresh(now: now)
        return (model, backend, root)
    }

    @Test func removingSitesKeepsTheRestAtOnceAndReleasesAfterADay() throws {
        let now = Date()
        let rule = DomainRestriction(owner: .commitment, policyID: "focus-a", title: "Feeds",
                                     domains: ["a.example", "b.example"], startsAt: now)
        let (model, _, root) = try makeModel([.add(rule)], at: now)
        let games = ShieldCategory.new(name: "Games", symbol: "dice.fill", color: .green)
        model.saveCategory(games)
        model.placeRule("focus-a", in: games.id)
        #expect(model.siteRemoval(for: rule, now: now) == .afterDelay)
        _ = model.removeSites(["a.example"], from: rule, now: now)
        let snapshot = try #require(model.backendSnapshot)
        let kept = try #require(snapshot.committedRestrictions.first { $0.policyID != "focus-a" })
        #expect(kept.domains == ["b.example"] && kept.owner == .commitment)
        #expect(snapshot.pendingReleases.map(\.policyID) == ["focus-a"])
        #expect(snapshot.pendingReleases[0].effectiveAt.timeIntervalSince(now) > 86_400)
        #expect(model.categoryLayout.categoryID(for: kept.policyID, defaultKind: .other) == games.id,
                "The kept websites stay in the same category.")
        // Category placement survives a relaunch.
        #expect(ShieldCategoryStore(fileURL: root.appendingPathComponent("categories.json")).load()
            .category(games.id)?.members.contains(kept.policyID) == true)
    }

    /// A block made before Shield 1.1 keeps the 24-hour Fix a Mistake.
    @Test func mistakenPermanentKeepsChosenSitesPermanentAndOthersReleaseAfterADay() throws {
        let now = Date()
        let mistake = DomainRestriction(owner: .permanent, policyID: "focus-mistake", title: "Social feeds",
                                        domains: ["x.com", "reddit.com", "tumblr.com"], startsAt: now)
        let plan = DomainRestriction(owner: .permanent, policyID: "owner-plan-food-1", title: "Food",
                                     domains: ["food.example"], startsAt: now)
        let (model, _, _) = try makeModel([.add(mistake), .add(plan)], at: now, beforeOnePointOne: true)
        #expect(model.siteRemoval(for: plan, now: now) == .unavailable("Permanent blocks cannot be released in Shield."))
        #expect(model.removeSites(["food.example"], from: plan, now: now) == nil)
        #expect(model.siteRemoval(for: mistake, now: now) == .correction)
        _ = model.removeSites(["x.com", "reddit.com"], from: mistake, now: now)
        let snapshot = try #require(model.backendSnapshot)
        // The original rule now releases after 24 hours; the kept site stays permanent.
        #expect(snapshot.committedRestrictions.first { $0.policyID == "focus-mistake" }?.owner == .commitment)
        #expect(snapshot.committedRestrictions.contains { $0.owner == .permanent && $0.domains == ["tumblr.com"] })
        #expect(snapshot.pendingReleases.map(\.policyID) == ["focus-mistake"])
        #expect(snapshot.pendingReleases.first.map { $0.effectiveAt >= now.addingTimeInterval(86_400) } == true)
        #expect(snapshot.authority.effectiveRestrictions.contains { $0.domains.contains("x.com") },
                "X stays blocked until the release is due.")
        let kept = try #require(snapshot.committedRestrictions.first { $0.domains == ["tumblr.com"] })
        #expect(kept.startsAt == now, "Kept sites keep the original correction deadline.")
        #expect(model.siteRemoval(for: kept, now: now) == .correction)
    }

    /// Shield 1.1: removing sites from a block made under 1.1 waits the full
    /// removal wait, even within its first 72 hours.
    @Test func mistakenOnePointOneBlockWaitsTheFullRemovalWait() throws {
        let now = Date()
        let mistake = DomainRestriction(owner: .permanent, policyID: "focus-mistake", title: "Social feeds",
                                        domains: ["x.com", "reddit.com", "tumblr.com"], startsAt: now)
        let (model, _, _) = try makeModel([.add(mistake)], at: now)
        #expect(model.siteRemoval(for: mistake, now: now) == .afterPermanentWait(259_200))
        _ = model.removeSites(["x.com", "reddit.com"], from: mistake, now: now)
        let snapshot = try #require(model.backendSnapshot)
        #expect(snapshot.committedRestrictions.contains { $0.owner == .permanent && $0.domains == ["tumblr.com"] })
        #expect(snapshot.pendingReleases.map(\.policyID) == ["focus-mistake"])
        #expect(snapshot.pendingReleases.first.map { $0.effectiveAt >= now.addingTimeInterval(259_200) } == true)
        #expect(snapshot.authority.effectiveRestrictions.contains { $0.domains.contains("x.com") })
    }

    @Test func dailyHoursNeverShortenTheCorrectionWait() throws {
        let now = Date()
        let hours = DailySchedule(id: "social-afternoon", title: "X / Reddit", domains: ["x.com", "reddit.com"],
                                  startMinutes: 1200, endMinutes: 840, isRequested: true)
        let mistake = DomainRestriction(owner: .permanent, policyID: "focus-mistake", title: "Tumblr",
                                        domains: ["x.com", "reddit.com", "tumblr.com"], startsAt: now)
        let (model, _, _) = try makeModel([.add(hours), .add(mistake)], at: now)
        _ = model.removeSites(["x.com", "reddit.com"], from: mistake, now: now)
        let snapshot = try #require(model.backendSnapshot)
        #expect(snapshot.pendingReleases.map(\.policyID) == ["focus-mistake"])
        #expect(snapshot.authority.effectiveRestrictions.contains { $0.domains.contains("x.com") && $0.owner != .recurring })
    }

    @Test func correctionNeverRestartsTheSeventyTwoHourWindow() throws {
        let now = Date()
        let created = now.addingTimeInterval(-2 * 3600)
        let mistake = DomainRestriction(owner: .permanent, policyID: "focus-mistake", title: "Social feeds",
                                        domains: ["x.com", "tumblr.com", "www.tumblr.com"], startsAt: created)
        let (model, _, _) = try makeModel([.add(mistake)], at: now)
        _ = model.removeSites(["x.com"], from: mistake, now: now)
        let snapshot = try #require(model.backendSnapshot)
        let kept = try #require(snapshot.committedRestrictions.first {
            $0.owner == .permanent && $0.domains == ["tumblr.com", "www.tumblr.com"] })
        #expect(kept.startsAt == created, "Kept sites keep the original correction deadline.")
        // Shield 1.1: a block made under 1.1 waits the full removal wait, before
        // and after its correction window alike.
        #expect(model.siteRemoval(for: kept, now: now) == .afterPermanentWait(259_200))
        let afterOriginalWindow = created.addingTimeInterval(DomainRestriction.permanentCorrectionWindow + 60)
        // Shield 1.1: past its correction window, a permanent block made under
        // 1.1 is removed only after the permanent wait (72 hours by default).
        #expect(model.siteRemoval(for: kept, now: afterOriginalWindow) == .afterPermanentWait(259_200))
    }

    @Test func schedulesStoreTheBlockedComplementAndSiteRemovalWaits() throws {
        let now = Date()
        let seed = DomainRestriction(owner: .permanent, policyID: "seed", title: "Seed", domains: ["seed.example"])
        let (model, _, _) = try makeModel([.add(seed)], at: now)
        let allowed = try #require(AllowedAccessWindow(startMinutes: 14 * 60, endMinutes: 20 * 60))
        _ = model.addSchedule(name: "Tumblr", domains: ["tumblr.com", "www.tumblr.com"], allowed: allowed,
                              categoryID: "social", now: now)
        let schedule = try #require(model.backendSnapshot?.committedSchedules.first)
        #expect((schedule.startMinutes, schedule.endMinutes) == (1200, 840), "Stored hours are the BLOCKED complement.")
        #expect(AllowedAccessWindow(blockedSchedule: schedule) == allowed)
        #expect(model.categoryLayout.categoryID(for: schedule.id, defaultKind: .other) == "social")

        _ = model.changeScheduleSites(scheduleID: schedule.id, to: schedule.domains.union(["m.tumblr.com"]), now: now)
        let added = try #require(model.backendSnapshot?.committedSchedules.first)
        #expect(added.domains.contains("m.tumblr.com"), "Adding websites applies at once.")
        #expect(model.backendSnapshot?.pendingReleases.isEmpty == true)

        _ = model.changeScheduleSites(scheduleID: schedule.id, to: ["tumblr.com"], now: now)
        #expect(model.backendSnapshot?.committedSchedules.first?.domains.count == 3, "Removing websites waits.")
        #expect(model.backendSnapshot?.pendingReleases.first?.replacementSchedule?.domains == ["tumblr.com"])
        #expect(model.removeSchedule(schedule.id, now: now) == nil, "Only one change can be pending.")
    }
}
