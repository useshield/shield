import Foundation
import Testing
@testable import Shield

// Import Website List: find the websites in pasted text or a file,
// leave out prose, single pages and services the Mac relies on, and split
// lists bigger than one rule.
struct BulkImportTests {
    @Test func findsBareAddressesLinksAndNamedLinks() {
        let found = WebsiteListImport.parse("""
            Shield website blocklist
            Copy the domain lines below into Shield.app before tonight.
            DOMAINS (3)
            imdb.com
            WWW.Example.COM., foo.org bar.net
            https://jumpstream.com/
            TV.Jest\thttps://tv.jest.one/
            foo.com:8080
            e.g. 1.2.3.4 localhost
            """)
        #expect(found.sites == ["bar.net", "example.com", "foo.com", "foo.org", "imdb.com", "jumpstream.com", "tv.jest.one"])
        #expect(!found.sites.contains("shield.app"), "a sentence isn't a list entry")
        #expect(!found.sites.contains("tv.jest"), "a link's name isn't a website")
        #expect(found.ignoredLines >= 3)
    }

    @Test func pagesOnBigSitesAreLeftOutUnlessTheSiteIsListed() {
        let found = WebsiteListImport.parse("""
            Some page\thttps://www.reddit.com/r/streaming/
            1337x Movies\thttps://1337x.to/movie-library/1/
            1337x.to
            """)
        #expect(found.sites == ["1337x.to"])
        #expect(found.pageLinks == ["reddit.com"], "blocking reddit.com would block every page there")
    }

    @Test func servicesTheMacReliesOnAreNeverImportedInBulk() {
        let found = WebsiteListImport.parse("github.com\nhttps://github.com/user/tool\napple.com\nuser.github.io")
        #expect(found.sites == ["user.github.io"])
        #expect(found.leftOutServices == ["apple.com", "github.com"])
    }

    @Test func wwwTwinsAreAddedAndBigListsSplit() {
        #expect(WebsiteListImport.lists(["a.com", "app.b.tv"]) == [["a.com", "www.a.com", "app.b.tv"]])
        // Country endings like .co.uk: a whole site, so it gets its www. twin too (Nov 13 review).
        #expect(WebsiteListParser.withWWW(["bbc.co.uk"]) == ["bbc.co.uk", "www.bbc.co.uk"])
        #expect(WebsiteListParser.withWWW(["www.bbc.co.uk"]) == ["bbc.co.uk", "www.bbc.co.uk"])
        #expect(WebsiteListParser.withWWW(["news.bbc.co.uk"]) == ["news.bbc.co.uk"])
        let many = (0..<1_500).map { "site\($0).example" }
        let lists = WebsiteListImport.lists(many)
        #expect(lists.count == 2)
        #expect(lists.allSatisfy { $0.count <= PolicyValidation.maximumDomains })
        #expect(lists.reduce(into: Set<String>()) { $0.formUnion($1) } == WebsiteListParser.withWWW(Set(many)))
        for list in lists {
            for site in list where !site.hasPrefix("www.") { #expect(list.contains("www." + site), "a twin stays with its site") }
        }
        #expect(WebsiteListImport.title("Streaming sites", part: 1, of: 2) == "Streaming sites")
        #expect(WebsiteListImport.title("Streaming sites", part: 2, of: 2) == "Streaming sites (2)")
        #expect(WebsiteListImport.title(String(repeating: "x", count: 80), part: 3, of: 3).count == 64)
    }

    @Test func aWholeImportedListIsOneValidRule() {
        let sites = (0..<900).map { "site\($0).example" }
        let lists = WebsiteListImport.lists(sites)
        #expect(lists.count == 1)
        #expect(PolicyValidation.validTargets(domains: lists[0], apps: []))
        #expect(!PolicyValidation.validTargets(domains: Set((0...PolicyValidation.maximumDomains).map { "s\($0).example" }),
                                               apps: []), "the per-rule limit still holds")
    }

    @Test func domainCheckIsUnchanged() {
        for good in ["a.co", "x-y.example", "a.b.c.d", String(repeating: "a", count: 63) + ".com", "1.2.3.4"] {
            #expect(PolicyValidation.validDomain(good), "\(good)")
        }
        for bad in ["", ".a.com", "a.com.", "a..com", "-a.com", "a-.com", "A.com", "a_b.com", "a com", "é.com",
                    String(repeating: "a", count: 64) + ".com",
                    (0..<130).map { _ in "a" }.joined(separator: ".")] {
            #expect(!PolicyValidation.validDomain(bad), "\(bad)")
        }
    }
}
