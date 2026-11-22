import CryptoKit
import Foundation
import Testing
@testable import Shield

struct ShieldUpdaterTests {
    @Test func versionsCompareByNumberNotText() {
        #expect(ShieldUpdater.isNewer("1.10", than: "1.9"))
        #expect(ShieldUpdater.isNewer("v1.2", than: "1.1"))
        #expect(!ShieldUpdater.isNewer("1.1", than: "1.1.0"))
        #expect(!ShieldUpdater.isNewer("1.0.9", than: "1.1"))
    }

    @Test func onlyGitHubFilesFromAFinishedReleaseAreUsed() throws {
        func feed(_ host: String, prerelease: Bool = false) -> Data {
            Data("""
            {"tag_name":"v1.2","html_url":"https://github.com/example/shield/releases/tag/v1.2","prerelease":\(prerelease),
             "assets":[{"name":"Shield-1.2.pkg","browser_download_url":"https://\(host)/a/Shield-1.2.pkg"},
                       {"name":"Shield-1.2.pkg.sig","browser_download_url":"https://\(host)/a/Shield-1.2.pkg.sig"},
                       {"name":"SHA256SUMS","browser_download_url":"https://\(host)/a/SHA256SUMS"}]}
            """.utf8)
        }
        let release = try ShieldUpdater.parseLatest(feed("github.com"))
        #expect(release.version == "1.2" && release.packageName == "Shield-1.2.pkg")
        #expect(throws: ShieldUpdater.Failure.missingFiles) { try ShieldUpdater.parseLatest(feed("evil.example")) }
        #expect(throws: ShieldUpdater.Failure.unreadableFeed) {
            try ShieldUpdater.parseLatest(feed("github.com", prerelease: true))
        }
    }

    @Test func aDownloadNeedsBothTheChecksumAndShieldsSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        let package = Data("installer bytes".utf8)
        let digest = SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined()
        let sums = "\(digest)  Shield-1.2.pkg\n"
        let signature = try key.signature(for: Data(digest.utf8))
        try ShieldUpdater.verify(package: package, name: "Shield-1.2.pkg", sums: sums, signature: signature,
                                 key: key.publicKey)
        #expect(throws: ShieldUpdater.Failure.checksumMismatch) {
            try ShieldUpdater.verify(package: Data("changed".utf8), name: "Shield-1.2.pkg", sums: sums,
                                     signature: signature, key: key.publicKey)
        }
        let other = Curve25519.Signing.PrivateKey()
        #expect(throws: ShieldUpdater.Failure.badSignature) {
            try ShieldUpdater.verify(package: package, name: "Shield-1.2.pkg", sums: sums,
                                     signature: try other.signature(for: Data(digest.utf8)), key: key.publicKey)
        }
    }

    @Test func aBuildWithoutAFeedNeverChecks() {
        #expect(ShieldUpdater.Configuration.fromBundle(Bundle(for: BundleToken.self)) == nil)
    }
}

private final class BundleToken {}
