import Foundation
import Testing
@testable import Shield

// "Reopen Chrome": browsers read Shield's block list when they open, so a site
// that opens later stays blocked in a browser that was already running, and a
// newly blocked site can keep loading there.
struct BrowserReopenAdvisorTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aSiteThatOpensAfterTheBrowserLaunchedIsReported() {
        var advisor = BrowserReopenAdvisor()
        advisor.observe(blocked: ["youtube.com", "www.youtube.com", "x.com"], now: t0)
        #expect(advisor.openedAt.isEmpty, "the first observation has nothing to compare with")
        advisor.observe(blocked: ["x.com"], now: t0 + 600)   // left Home: YouTube opens
        #expect(advisor.openedSince(launch: t0 + 60) == ["youtube.com", "www.youtube.com"])
        #expect(advisor.openedSince(launch: t0 + 900).isEmpty, "a browser opened afterwards already has the new list")
    }

    @Test func newBlocksAreNotCountedAsOpened() {
        var advisor = BrowserReopenAdvisor()
        advisor.observe(blocked: ["x.com"], now: t0)
        advisor.observe(blocked: ["x.com", "youtube.com"], now: t0 + 600)
        #expect(advisor.openedSince(launch: t0 - 60).isEmpty)
    }

    // An imported list only reached an open Chrome after a restart.
    @Test func aSiteBlockedAfterTheBrowserLaunchedIsReported() {
        var advisor = BrowserReopenAdvisor()
        advisor.observe(blocked: ["x.com"], now: t0)
        #expect(advisor.blockedAt == nil, "the first observation has nothing to compare with")
        advisor.observe(blocked: ["x.com", "1337x.example", "www.1337x.example"], now: t0 + 600)
        #expect(advisor.blockedSince(launch: t0 + 60) == ["1337x.example", "www.1337x.example"])
        #expect(advisor.blockedSince(launch: t0 + 900).isEmpty, "a browser opened afterwards never had it open")
        advisor.observe(blocked: ["x.com"], now: t0 + 1_200)
        #expect(advisor.blockedSince(launch: t0 + 60).isEmpty, "open again: nothing to reopen for")
        #expect(advisor.blockedAt == nil)
    }

    @Test func notNowAndPruneCoverBlocksToo() {
        var advisor = BrowserReopenAdvisor()
        advisor.observe(blocked: [], now: t0)
        advisor.observe(blocked: ["a.example"], now: t0 + 60)
        advisor.dismissedAt = t0 + 90
        #expect(advisor.blockedSince(launch: t0).isEmpty)
        advisor.observe(blocked: ["a.example", "b.example"], now: t0 + 120)
        #expect(advisor.blockedSince(launch: t0) == ["b.example"])
        advisor.prune(earliestLaunch: t0 + 200)
        #expect(advisor.blockedAt == nil, "Chrome reopened since: it already has every block")
        advisor.observe(blocked: ["a.example", "b.example", "c.example"], now: t0 + 300)
        advisor.prune(earliestLaunch: nil)
        #expect(advisor.blockedAt == nil, "no browser running: nothing to reopen")
    }

    @Test func stateSavedByAnEarlierReleaseStillLoads() throws {
        let old = #"{"lastBlocked":["x.com"],"openedAt":{}}"#
        let decoded = try JSONDecoder().decode(BrowserReopenAdvisor.self, from: Data(old.utf8))
        #expect(decoded.lastBlocked == ["x.com"] && decoded.blockedAt == nil)
    }

    @Test func blockedWordingIsPlain() {
        #expect(BrowserReopenAdvisor.blockedHeadline(["Streaming sites"]) == "Now blocked: Streaming sites.")
        #expect(BrowserReopenAdvisor.blockedHeadline(["A", "B", "C", "D", "E"]) == "Now blocked: A, B and 3 more.")
        #expect(BrowserReopenAdvisor.detail(browser: "Chrome", opened: false, blocked: true, restoresTabs: true)
                == "If Chrome still opens it, reopen it. Your tabs come back.")
        #expect(BrowserReopenAdvisor.detail(browser: "Chrome", opened: true, blocked: false, restoresTabs: false)
                == "If Chrome still blocks it, reopen it.")
        #expect(BrowserReopenAdvisor.detail(browser: "Chrome", opened: true, blocked: true, restoresTabs: true)
                == "Reopen Chrome so it catches up. Your tabs come back.")
    }

    @Test func blockedAgainClearsIt() {
        var advisor = BrowserReopenAdvisor()
        advisor.observe(blocked: ["youtube.com"], now: t0)
        advisor.observe(blocked: [], now: t0 + 60)
        advisor.observe(blocked: ["youtube.com"], now: t0 + 120)
        #expect(advisor.openedSince(launch: t0 - 60).isEmpty)
    }

    @Test func notNowHidesUntilSomethingElseOpens() {
        var advisor = BrowserReopenAdvisor()
        advisor.observe(blocked: ["youtube.com", "reddit.com"], now: t0)
        advisor.observe(blocked: ["reddit.com"], now: t0 + 60)
        advisor.dismissedAt = t0 + 90
        #expect(advisor.openedSince(launch: t0).isEmpty)
        advisor.observe(blocked: [], now: t0 + 120)
        #expect(advisor.openedSince(launch: t0) == ["reddit.com"])
    }

    @Test func pruneForgetsOpensNoRunningBrowserPredates() {
        var advisor = BrowserReopenAdvisor()
        advisor.observe(blocked: ["youtube.com"], now: t0)
        advisor.observe(blocked: [], now: t0 + 60)
        advisor.prune(earliestLaunch: t0 + 120)
        #expect(advisor.openedAt.isEmpty)
        advisor.observe(blocked: ["x.com"], now: t0 + 180)
        advisor.observe(blocked: [], now: t0 + 240)
        advisor.prune(earliestLaunch: nil)
        #expect(advisor.openedAt.isEmpty, "no browser running: nothing to reopen")
    }

    /// The notice names categories, never "api.twitter.com + 9 more".
    @Test func namesAreTheCategoriesThatHoldTheSites() {
        let categories: [(title: String, domains: Set<String>)] = [
            ("Social media", ["x.com", "twitter.com", "reddit.com", "instagram.com"]),
            ("Video & streaming", ["youtube.com", "www.youtube.com", "youtu.be", "netflix.com"]),
            ("Food ordering", ["doordash.com"]),
        ]
        // Sites under a category's website count for it.
        let social = BrowserReopenAdvisor.names(for: ["api.twitter.com", "www.reddit.com", "i.instagram.com"],
                                                categories: categories)
        #expect(social == ["Social media"])
        let both = BrowserReopenAdvisor.names(for: ["netflix.com", "x.com"], categories: categories)
        #expect(both == ["Social media", "Video & streaming"], "In the categories' order")
        #expect(BrowserReopenAdvisor.names(for: ["youtube.com", "example.org"], categories: categories)
                == ["Video & streaming", "other websites"])
        #expect(BrowserReopenAdvisor.names(for: ["example.org"], categories: categories) == ["Some websites"])
        #expect(BrowserReopenAdvisor.names(for: ["notx.com"], categories: categories) == ["Some websites"],
                "Only whole labels count")
        #expect(BrowserReopenAdvisor.headline(["Social media"]) == "Social media is open now.")
        #expect(BrowserReopenAdvisor.headline(["Social media", "Video & streaming"])
                == "Social media and Video & streaming are open now.")
        #expect(BrowserReopenAdvisor.headline(["Some websites"]) == "Some websites are open now.")
    }

    @Test func savedStateRoundTrips() throws {
        var advisor = BrowserReopenAdvisor()
        advisor.observe(blocked: ["youtube.com"], now: t0)
        advisor.observe(blocked: [], now: t0 + 60)
        let decoded = try JSONDecoder().decode(BrowserReopenAdvisor.self, from: JSONEncoder().encode(advisor))
        #expect(decoded == advisor)
    }

    @Test func onlyAServiceThatWritesBrowserPolicySaysSo() {
        #expect(BackendSnapshot.browserPolicyFeature == "browser-policy")
    }
}
