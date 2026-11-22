import Foundation
import Testing
@testable import Shield

// lists and schedules can be renamed and combined in Shield's window.
// Both are display only; the service's rules never change.
struct NamesAndCombineTests {
    @Test func namesNeverShowGaps() {
        #expect(ShieldCategoryLayout.cleanName("Streaming sites   removed\tgeneral sites") ==
                "Streaming sites removed general sites")
        #expect(ImportListEditor.name(fromFile: URL(fileURLWithPath: "/x/Streaming sites - removed general sites.txt")) ==
                "Streaming sites \u{2013} removed general sites")
        #expect(ImportListEditor.name(fromFile: URL(fileURLWithPath: "/x/adult-sites_all.txt")) == "adult sites all")
        let layout = ShieldCategoryLayout.default
        #expect(layout.displayName(for: "focus-1", title: "Streaming sites   removed") == "Streaming sites removed")
        #expect(layout.displayName(for: "social-afternoon", title: "Social feeds") == "X / Reddit")
    }

    @Test func renamingIsDisplayOnlyAndCanBeUndone() {
        var layout = ShieldCategoryLayout.default
        layout.rename("focus-1", to: "  My   list ")
        #expect(layout.displayName(for: "focus-1", title: "Original") == "My list")
        layout.rename("focus-1", to: "   ")
        #expect(layout.displayName(for: "focus-1", title: "Original") == "Original")
    }

    @Test func combinedListsMoveTogetherAndSeparate() {
        var layout = ShieldCategoryLayout.default
        layout.combine(["a", "b", "c"], name: "Adult", in: ShieldGroupKind.adult.rawValue)
        #expect(layout.combination(containing: "b") == ["a", "b", "c"])
        #expect(["a", "b", "c"].allSatisfy { layout.categoryID(for: $0, defaultKind: .other) == ShieldGroupKind.adult.rawValue })
        #expect(layout.displayName(for: "a", title: "x") == "Adult")
        // A list joins only one card at a time.
        layout.combine(["c", "d"], name: "Other", in: ShieldGroupKind.adult.rawValue)
        #expect(layout.combination(containing: "a") == ["a", "b"])
        #expect(layout.combination(containing: "c") == ["c", "d"])
        layout.separate(["a"])
        #expect(layout.combination(containing: "b") == nil)
    }

    @Test func layoutsSavedBeforeNamesStillLoad() throws {
        let old = #"{"version":1,"categories":[{"id":"other","name":"Other","symbol":"square.stack.fill","color":"gray","members":["x"]}]}"#
        let layout = try JSONDecoder().decode(ShieldCategoryLayout.self, from: Data(old.utf8)).normalized()
        #expect(layout.names.isEmpty && layout.combined.isEmpty)
        #expect(layout.categoryID(for: "x", defaultKind: .adult) == "other")
        var renamed = layout
        renamed.rename("x", to: "Kept")
        let again = try JSONDecoder().decode(ShieldCategoryLayout.self, from: JSONEncoder().encode(renamed))
        #expect(again.normalized().displayName(for: "x", title: "y") == "Kept")
    }

    @Test func ownerPlanPartsShowAsOneCard() {
        let parts = (1...2).map {
            DomainRestriction(owner: .permanent, policyID: "owner-plan-adult-\($0)", title: "Adult content",
                              domains: ["a\($0).example"])
        }
        let other = DomainRestriction(owner: .permanent, policyID: "focus-x", title: "X", domains: ["x.example"])
        let cards = RuleGroupDetailPage.cards(parts + [other], layout: .default)
        #expect(cards.map { $0.map(\.policyID) } == [["owner-plan-adult-1", "owner-plan-adult-2"], ["focus-x"]])
    }

    @Test func refusedMediaLinksAreRetriedWithOtherClients() {
        #expect(YTDLPRestrictedFetcher.isRetryable(.toolReported("yt-dlp", "unable to download video data: HTTP Error 403: Forbidden")))
        #expect(!YTDLPRestrictedFetcher.isRetryable(.toolReported("yt-dlp", "Video unavailable")))
        #expect(!YTDLPRestrictedFetcher.isRetryable(.cancelled))
        #expect(YTDLPRestrictedFetcher.isRetryable(.toolReported("yt-dlp", "Sign in to confirm you’re not a bot")))
        #expect(!YTDLPRestrictedFetcher.isRetryable(.toolReported("yt-dlp", "Private video. Sign in if you've been granted access")))
        #expect(YTDLPRestrictedFetcher.playerClientFallbacks.first == [])
        // Without a sign-in: three clients. With one: a plain
        // try first (whole files, fast), then a signed-in way, alternating, so
        // a connection YouTube refuses plain downloads for reaches the sign-in
        // on the second try instead of the last.
        #expect(YTDLPRestrictedFetcher.attempts(hasSignIn: false).count == 3)
        #expect(!YTDLPRestrictedFetcher.attempts(hasSignIn: false).contains { $0.signIn })
        let signedIn = YTDLPRestrictedFetcher.attempts(hasSignIn: true)
        #expect(signedIn.count == 5 && signedIn.filter(\.signIn).count == 2)
        #expect(signedIn.map(\.signIn) == [false, true, false, true, false])
        #expect(signedIn.first == .init(clients: [], signIn: false))
        // web_embedded's files are refused without a token since Nov 2026
        // (yt-dlp issue 17989): no way asks for it, and the signed-in default
        // (which includes it) leaves it out.
        for way in signedIn {
            let clients = way.clients.joined(separator: " ")
            #expect(!clients.contains("web_embedded") || clients.contains("-web_embedded"))
            if way.signIn { #expect(!way.clients.isEmpty, "The signed-in default would use web_embedded") }
        }
        #expect(YTDLPRestrictedFetcher.asksForSignIn(.toolReported("yt-dlp", "Sign in to confirm you’re not a bot")))
        #expect(!YTDLPRestrictedFetcher.asksForSignIn(.toolReported("yt-dlp", "HTTP Error 403: Forbidden")))
        // The chosen height (Settings › Video quality): H.264/AAC first, then
        // other codecs up to that height, and the smallest version only when
        // nothing fits. Checked against yt-dlp's own selection.
        for height in YTDLPRestrictedFetcher.qualities {
            let selector = YTDLPRestrictedFetcher.formatSelector(maxHeight: height)
            #expect(selector.hasPrefix("bv*[height<=\(height)][vcodec^=avc1]+ba[acodec^=mp4a]/"))
            #expect(selector.contains("/b[height<=\(height)][vcodec^=avc1][acodec^=mp4a]/"))
            #expect(selector.contains("/bv*[height<=\(height)]+ba/b[height<=\(height)]/wv*+ba/w/"))
            #expect(selector.hasSuffix("/b"))
        }
        #expect(YTDLPRestrictedFetcher.formatSelector(maxHeight: 4320)
                == YTDLPRestrictedFetcher.formatSelector(maxHeight: YTDLPRestrictedFetcher.defaultQuality))
        #expect(YTDLPRestrictedFetcher(ytdlpURL: URL(fileURLWithPath: "/x"), denoURL: URL(fileURLWithPath: "/x"),
                                       ffmpegLocation: URL(fileURLWithPath: "/x")).maxHeight == 1080)
        #expect(StudyDownloadCoordinator.parallelDownloads == 3)
    }

    @Test func conversionRunsWithoutNetwork() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("offline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let profile = try StudyContainment.offlineProfile(stagingDirectory: folder)
        #expect(profile.contains("(deny network-outbound)"))
        #expect(!profile.contains("allow network-outbound"))
        #expect(profile.contains("(deny file-write*)"))
    }

    /// Nov 15 speed-up: the faster tint and count give the same answers as before.
    @MainActor @Test func fasterTintAndCountMatchTheOldWay() {
        var domains: Set<String> = ["www.reddit.com", "reddit.com", "zeta.example", "alpha.example"]
        for n in 0..<400 { domains.insert("site\(n).example") }
        #expect(RowTint.color(name: "Feeds", domains: domains) ==
                RowTint.color(name: "Feeds", domains: Array(domains.sorted().prefix(8))))
        let small: Set<String> = ["netflix.com", "www.netflix.com", "nflxvideo.net"]
        #expect(RowTint.color(name: "N", domains: small) == RowTint.color(name: "N", domains: small.sorted()))
        #expect(WebsiteListParser.count(domains) == "\(WebsiteListParser.roots(domains).count) websites")
        #expect(WebsiteListParser.count(["www.a.com", "a.com"]) == "1 website")
        #expect(WebsiteListParser.count(["www.a.com"]) == "1 website")
    }
}
