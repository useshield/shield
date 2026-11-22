import Foundation
import Testing
@testable import Shield

struct StudyContainmentTests {
    @Test func toolProfileAllowsOnlyTheBrokerPortAndStagingWrites() throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let profile = try StudyContainment.toolProfile(stagingDirectory: staging, brokerPort: 41_234)
        let lines = profile.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(lines.filter { $0.hasPrefix("(allow network") } == [#"(allow network-outbound (remote ip "localhost:41234"))"#])
        #expect(lines.contains("(deny network-outbound)"))
        #expect(lines.contains("(deny file-write*)"))
        #expect(lines.contains(#"(deny mach-lookup (global-name "com.apple.mDNSResponder"))"#))
        // Denials precede the narrow allows (Seatbelt applies the last match).
        let deny = try #require(lines.firstIndex(of: "(deny network-outbound)"))
        let allow = try #require(lines.firstIndex { $0.hasPrefix("(allow network-outbound") })
        #expect(deny < allow)
        // The kernel's canonical path: temporary folders live under /private/var.
        let canonical = try #require(realpath(staging.path, nil).map { p in defer { free(p) }; return String(cString: p) })
        #expect(profile.contains(#"(subpath ""# + canonical + #"")"#))
        if staging.path.hasPrefix("/var/") { #expect(canonical.hasPrefix("/private/var/")) }
        // Nothing can be handed outside the sandbox, and home-folder files stay unreadable.
        #expect(lines.contains("(deny appleevent-send)") && lines.contains("(deny lsopen)"))
        #expect(lines.contains { $0.hasPrefix("(deny file-read-data (subpath ") })
        #expect(!lines.contains("(deny process-exec)"))
    }

    @Test func toolProfileRunsOnlyTheGivenPrograms() throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let tool = URL(fileURLWithPath: "/bin/echo")
        let profile = try StudyContainment.toolProfile(stagingDirectory: staging, brokerPort: 41_234, executables: [tool])
        let lines = profile.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let deny = try #require(lines.firstIndex(of: "(deny process-exec)"))
        let allow = try #require(lines.firstIndex(of: #"(allow process-exec (literal "/bin/echo"))"#))
        #expect(deny < allow)
        #expect(lines.contains { $0.hasPrefix("(allow file-read-data") && $0.contains(#"(literal "/bin/echo")"#) })
    }

    @Test func toolProfileRejectsPathsThatCouldEscapeTheProfileString() {
        for path in ["/tmp/a\"b", "/tmp/a\\b", "/tmp/a\nb"] {
            #expect(throws: (any Error).self) {
                try StudyContainment.toolProfile(stagingDirectory: URL(fileURLWithPath: path), brokerPort: 40_000)
            }
        }
    }

    @Test func resolverAcceptsOnlyPublicUnicastIPv4() {
        for address in ["142.251.156.4", "8.8.8.8", "172.32.0.1"] { #expect(EgressResolverAnswer.isPublicIPv4(address)) }
        for address in ["0.0.0.0", "127.0.0.1", "10.1.2.3", "192.168.1.1", "172.16.0.1", "169.254.1.1",
                        "100.64.0.1", "224.0.0.1", "255.255.255.255", "01.2.3.4", "1.2.3", "1.2.3.4.5",
                        "::1", "1.2.3.256", "a.b.c.d", "1.2.3.-4"] {
            #expect(!EgressResolverAnswer.isPublicIPv4(address), "\(address)")
        }
    }

    @Test func resolverSkipsPoisonedAnswersAndFailedStatuses() throws {
        let poisoned = #"{"Status":0,"Answer":[{"type":5,"data":"x.example."},{"type":1,"data":"127.0.0.1","TTL":9},{"type":1,"data":"142.250.1.1","TTL":120}]}"#
        let answer = try #require(EgressResolverAnswer.firstPublicAddress(in: Data(poisoned.utf8)))
        #expect(answer.address == "142.250.1.1")
        #expect(answer.ttl == 120)
        #expect(EgressResolverAnswer.firstPublicAddress(in: Data(#"{"Status":3,"Answer":[{"type":1,"data":"1.1.1.1"}]}"#.utf8)) == nil)
        #expect(EgressResolverAnswer.firstPublicAddress(in: Data(#"{"Status":0,"Answer":[{"type":1,"data":"0.0.0.0"}]}"#.utf8)) == nil)
        #expect(EgressResolverAnswer.firstPublicAddress(in: Data("not json".utf8)) == nil)
    }
}

struct StudyToolDiscoveryLinkTests {
    // Homebrew installs bin/ffmpeg as a link into its Cellar; the safety checks
    // apply to the file the link resolves to.
    @Test func linkedToolsResolveAndUnsafeTargetsAreRefused() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tools-\(UUID().uuidString)")
        let bin = home.appendingPathComponent(".local/bin"), cellar = home.appendingPathComponent("Cellar")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cellar, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        for name in ["yt-dlp", "deno", "ffmpeg", "ffprobe"] {
            let target = (name.hasPrefix("ff") ? cellar : bin).appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            if name.hasPrefix("ff") {
                try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent(name), withDestinationURL: target)
            }
        }
        let tools = try StudyTools.discover(home: home, searchRoots: [], contained: true)
        #expect(tools.ffmpeg.lastPathComponent == "ffmpeg" && tools.ffmpeg.path.contains("/Cellar/"))
        try FileManager.default.setAttributes([.posixPermissions: 0o777],
                                              ofItemAtPath: cellar.appendingPathComponent("ffprobe").path)
        #expect(throws: (any Error).self) { try StudyTools.discover(home: home, searchRoots: [], contained: true) }
    }
}

struct StudyContainedTitleTests {
    @Test func titleComesFromInfoFileAsOnePlainLine() {
        func title(_ object: Any) -> String? {
            StudyContainedFetcher.title(fromInfoJSON: try! JSONSerialization.data(withJSONObject: object))
        }
        #expect(title(["title": "  Algebra Lesson #1\n"]) == "Algebra Lesson #1")
        #expect(title(["title": "a\u{0}b\u{7}c"]) == "abc")
        #expect(title(["title": String(repeating: "x", count: 400)])?.count == 160)
        #expect(title(["title": "   "]) == nil)
        #expect(title(["id": "lessonVid01"]) == nil)
        #expect(StudyContainedFetcher.title(fromInfoJSON: Data("not json".utf8)) == nil)
    }
}

struct StudyCookiesTests {
    private let export = """
    # Netscape HTTP Cookie File
    .youtube.com\tTRUE\t/\tTRUE\t1893456000\tSID\tyt
    #HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t1893456000\t__Secure-3PSID\tyt2
    .google.com\tTRUE\t/\tTRUE\t1893456000\tNID\tg
    .bank.example\tTRUE\t/\tTRUE\t1893456000\tsession\tsecret
    .notyoutube.com\tTRUE\t/\tTRUE\t1893456000\tx\ty
    """

    @Test func keepsOnlyYouTubeAndGoogleCookies() throws {
        let filtered = try #require(StudyCookies.filtered(export))
        #expect(filtered.contains("\tSID\tyt") && filtered.contains("__Secure-3PSID") && filtered.contains("\tNID\tg"))
        #expect(!filtered.contains("bank.example") && !filtered.contains("notyoutube"))
        #expect(StudyCookies.filtered("# Netscape HTTP Cookie File\n.google.com\tTRUE\t/\tTRUE\t1\tNID\tg\n") == nil)
        #expect(StudyCookies.filtered("not a cookie file") == nil)
    }

    @Test func stagedCopyIsPrivateAndAbsentFileMeansNoSignIn() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cookies-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try StudyCookies.stagedCopy(from: root.appendingPathComponent("missing.txt"), into: root) == nil)
        let source = root.appendingPathComponent("youtube-cookies.txt")
        try Data(export.utf8).write(to: source)
        let copy = try #require(try StudyCookies.stagedCopy(from: source, into: root))
        let mode = try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(!(try String(contentsOf: copy, encoding: .utf8)).contains("bank.example"))
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: (any Error).self) { try StudyCookies.stagedCopy(from: link, into: root) }
    }
}

// Live, opt-in only (TEST_RUNNER_SHIELD_LIVE_DOWNLOAD=1 and TEST_RUNNER_SHIELD_CONTAINED_DOWNLOADS=1):
// the app's real contained fetcher inside the app process, no window. One owner-authorized video.
struct StudyLiveContainedFetchTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHIELD_LIVE_DOWNLOAD"] == "1"))
    func containedFetcherDownloadsOneAuthorizedVideo() async throws {
        let containment = try #require(StudyContainment.bundled)
        let tools = try #require(StudyContainment.discoveredTools)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldLive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let video = StudyVideo(id: "lessonVid01", title: "Algebra Lesson 1", expectedDuration: nil, transcriptRequested: true)
        final class TitleBox: @unchecked Sendable { var value: String? }
        let title = TitleBox()
        var fetcher = StudyContainedFetcher(tools: tools, containment: containment)
        fetcher.onMetadata = { _, value in title.value = value }
        let output = try await fetcher.fetch(video: video, stagingDirectory: root.appendingPathComponent("stage"))
        print("live-fetch title=\(title.value ?? "nil")")
        #expect(title.value != nil)
        let validation = try await NativeLocalMediaValidator().validate(mediaURL: output, expectedDuration: nil, transcriptURL: nil)
        print("live-fetch output=\(output.lastPathComponent) validation=\(validation)")
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("stage/.cookies.txt").path))
    }
}
