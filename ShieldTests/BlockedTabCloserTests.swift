import Foundation
import Testing
@testable import Shield

// Closing tabs on newly blocked sites: only those tabs,
// never others.
struct BlockedTabCloserTests {
    private func tab(_ url: String, window: String = "1") -> BlockedTabCloser.Tab { .init(windowID: window, url: url) }

    @Test func onlyTabsOnANewlyBlockedSiteAreChosen() {
        let tabs = [
            tab("https://www.youtube.com/watch?v=abc"), tab("https://m.youtube.com/"),
            tab("https://notyoutube.com/"), tab("https://docs.google.com/document/d/1"),
            tab("chrome://settings/"), tab("about:blank"), tab("file:///Users/me/notes.html"),
            tab("https://YOUTUBE.com./feed", window: "2"),
        ]
        let chosen = BlockedTabCloser.tabsToClose(tabs, newlyBlocked: ["youtube.com", "www.youtube.com"])
        // Hosts blocking is exact: m.youtube.com still loads, so its tab stays.
        #expect(chosen == [tabs[0], tabs[7]])
        #expect(BlockedTabCloser.tabsToClose(tabs, newlyBlocked: []).isEmpty, "no new block, nothing closes")
    }

    @Test func subdomainsOfABlockedSiteStayOpen() {
        let tabs = [tab("https://docs.google.com/a"), tab("https://google.com/search?q=x"),
                    tab("https://docs.example.com/"), tab("https://example.com/")]
        #expect(BlockedTabCloser.tabsToClose(tabs, newlyBlocked: ["google.com", "example.com"]) == [tabs[1], tabs[3]])
    }

    @Test func listingIsParsedStrictly() {
        let output = "12\thttps://a.example/x\n\n13\thttps://b.example/\tstill url\nnot-a-window\thttps://c.example/\n14\t\n"
        #expect(BlockedTabCloser.parseListing(output) ==
                [tab("https://a.example/x", window: "12"), tab("https://b.example/\tstill url", window: "13")])
    }

    @Test func scriptsNeverLaunchABrowserAndQuoteAddresses() {
        let listing = BlockedTabCloser.listingScript(bundleID: "com.google.Chrome")
        #expect(listing.hasPrefix(#"if application id "com.google.Chrome" is not running then return """#))
        let closing = BlockedTabCloser.closingScript(bundleID: "com.google.Chrome",
                                                     tabs: [tab(#"https://a.example/?q="x"\y"#, window: "7")])
        #expect(closing.hasPrefix(#"if application id "com.google.Chrome" is not running then return """#))
        #expect(closing.contains(#"set targets to {"https://a.example/?q=\"x\"\\y"}"#))
        #expect(closing.contains("set w to window id 7"), "windows are found by ID, never by position")
        #expect(!closing.contains("repeat with w in windows"))
        #expect(!closing.contains("quit"), "a browser is never quit")
        #expect(!closing.contains("close w") && !closing.contains("close window"), "a window is never closed")
        #expect(closing.contains("if hits > 0 and hits = total then make new tab"),
                "a window whose every tab closes gets a blank tab first")
        for bad in ["7 or true", "", "٣"] {
            #expect(BlockedTabCloser.closingScript(bundleID: "com.google.Chrome", tabs: [tab("https://a.example/", window: bad)])
                        .contains("set targets") == false, "a window ID that isn't a plain number is dropped: \(bad)")
        }
    }

    @Test func aCloseThatStoppedPartWayStillRecordsWhatClosed() {
        let a = tab("https://a.example/"), a2 = tab("https://a.example/"), b = tab("https://b.example/", window: "2")
        let keep = tab("https://keep.example/")
        let before = [a, a2, b, keep]
        // One of the two a.example tabs and the b.example tab closed before it stopped.
        let closed = BlockedTabCloser.closedTabs(chosen: [a, a2, b], before: before, after: [a, keep])
        #expect(closed == [a, b])
        #expect(BlockedTabCloser.closedTabs(chosen: [a, a2, b], before: before, after: before).isEmpty)
    }

    @Test func firefoxIsNotScripted() {
        #expect(BlockedTabCloser.scriptableBrowsers["org.mozilla.firefox"] == nil)
        #expect(BlockedTabCloser.scriptableBrowsers["com.google.Chrome"] != nil)
    }

    @Test func closingTabsHidesTheReopenNoticeForThoseBlocksOnly() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var advisor = BrowserReopenAdvisor()
        advisor.observe(blocked: ["x.com"], now: t0)
        advisor.observe(blocked: [], now: t0 + 30)               // x.com opens
        advisor.observe(blocked: ["a.example"], now: t0 + 60)    // a.example blocked
        advisor.markHandled(["a.example"])
        #expect(advisor.blockedSince(launch: t0 - 60).isEmpty)
        #expect(advisor.openedSince(launch: t0 - 60) == ["x.com"], "closing tabs never hides a site that opened")
        advisor.observe(blocked: ["a.example", "b.example"], now: t0 + 120)
        #expect(advisor.blockedSince(launch: t0 - 60) == ["b.example"], "a later block still shows")
    }

    @Test func anEarlierUnhandledBlockStillShowsAfterALaterOneIsHandled() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var advisor = BrowserReopenAdvisor()
        advisor.observe(blocked: [], now: t0)
        advisor.observe(blocked: ["pinterest.com"], now: t0 + 60)                 // closing was off
        advisor.observe(blocked: ["pinterest.com", "x.com"], now: t0 + 120)       // closing on, x.com handled
        advisor.markHandled(["x.com"])
        #expect(advisor.blockedSince(launch: t0 - 60) == ["pinterest.com"])
        // Saved by release 293: its single moment no longer hides anything.
        advisor.blockedHandledAt = t0 + 500
        #expect(advisor.blockedSince(launch: t0 - 60) == ["pinterest.com"])
    }
}
