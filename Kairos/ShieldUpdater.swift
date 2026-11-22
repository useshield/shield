import AppKit
import CryptoKit
import Foundation

/// Shield 1.1 updates without Apple: Shield asks the public
/// GitHub Releases page for a newer version, downloads the installer itself,
/// checks its SHA-256 and Shield's own update signature (Ed25519, key kept
/// offline by the user), then opens it in Installer. Nothing installs
/// without the person's admin password, and blocks are never touched.
///
/// Off unless the build names a release feed and an update key
/// (`ShieldUpdateFeed`, `ShieldUpdatePublicKey` in Info.plist), so private and
/// test builds never reach the network.
enum ShieldUpdater {
    struct Release: Equatable, Sendable {
        let version: String
        let notesURL: URL
        let package: URL
        let packageName: String
        let checksums: URL
        let signature: URL
    }

    enum Failure: Error, Equatable, LocalizedError {
        case notConfigured
        case unreadableFeed
        case missingFiles
        case checksumMismatch
        case badSignature
        case download(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Updates aren't set up in this copy of Shield."
            case .unreadableFeed: "Shield couldn't read the release page. Try again later."
            case .missingFiles: "The newest release is missing its installer or its checks."
            case .checksumMismatch: "The download didn't match its checksum, so Shield deleted it."
            case .badSignature: "The download isn't signed by Shield's release key, so Shield deleted it."
            case .download(let reason): "The download failed: \(reason)"
            }
        }
    }

    struct Configuration: Sendable {
        let feed: URL
        let publicKey: Curve25519.Signing.PublicKey
        let currentVersion: String

        static func fromBundle(_ bundle: Bundle = .main) -> Configuration? {
            guard let feedText = bundle.object(forInfoDictionaryKey: "ShieldUpdateFeed") as? String,
                  let feed = URL(string: feedText), feed.scheme == "https", feed.host == "api.github.com",
                  let keyText = bundle.object(forInfoDictionaryKey: "ShieldUpdatePublicKey") as? String,
                  let keyData = Data(base64Encoded: keyText),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
                  let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
                return nil
            }
            return Configuration(feed: feed, publicKey: key, currentVersion: version)
        }
    }

    /// "1.10" is newer than "1.9"; missing parts count as 0.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            text.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Reads GitHub's "latest release" JSON. Only files on github.com are used.
    static func parseLatest(_ data: Data) throws -> Release {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Payload: Decodable { let tag_name: String; let html_url: URL; let draft: Bool?; let prerelease: Bool?; let assets: [Asset] }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.draft != true, payload.prerelease != true else { throw Failure.unreadableFeed }
        func asset(_ match: (String) -> Bool) -> Asset? {
            payload.assets.first { match($0.name) && $0.browser_download_url.scheme == "https" &&
                $0.browser_download_url.host == "github.com" }
        }
        let version = payload.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard let package = asset({ $0.hasPrefix("Shield-") && $0.hasSuffix(".pkg") }),
              let sums = asset({ $0 == "SHA256SUMS" }),
              let signature = asset({ $0 == package.name + ".sig" }) else { throw Failure.missingFiles }
        return Release(version: version, notesURL: payload.html_url, package: package.browser_download_url,
                       packageName: package.name, checksums: sums.browser_download_url,
                       signature: signature.browser_download_url)
    }

    /// The SHA-256 listed for `name` in a `shasum -a 256` file.
    static func expectedDigest(for name: String, in sums: String) -> String? {
        for line in sums.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2, fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == name,
                  fields[0].count == 64 else { continue }
            return fields[0].lowercased()
        }
        return nil
    }

    /// Both checks must pass: the published checksum, and Shield's signature
    /// over that same digest (so a changed release page alone can't pass).
    static func verify(package: Data, name: String, sums: String, signature: Data,
                       key: Curve25519.Signing.PublicKey) throws {
        let digest = SHA256.hash(data: package).map { String(format: "%02x", $0) }.joined()
        guard expectedDigest(for: name, in: sums) == digest else { throw Failure.checksumMismatch }
        guard key.isValidSignature(signature, for: Data(digest.utf8)) else { throw Failure.badSignature }
    }

    static func latest(_ configuration: Configuration, session: URLSession = .shared) async throws -> Release? {
        var request = URLRequest(url: configuration.feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Shield-Updater", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_048_576 else {
            throw Failure.unreadableFeed
        }
        let release = try parseLatest(data)
        return isNewer(release.version, than: configuration.currentVersion) ? release : nil
    }

    /// Downloads, checks, and returns the verified installer's location.
    static func download(_ release: Release, configuration: Configuration,
                         session: URLSession = .shared) async throws -> URL {
        func fetch(_ url: URL, limit: Int) async throws -> Data {
            do {
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= limit else {
                    throw Failure.download("The server answered unexpectedly.")
                }
                return data
            } catch let failure as Failure { throw failure }
            catch { throw Failure.download(error.localizedDescription) }
        }
        let sums = try await fetch(release.checksums, limit: 65_536)
        let signature = try await fetch(release.signature, limit: 4_096)
        let package = try await fetch(release.package, limit: 512 * 1_048_576)
        let signatureBytes = Data(base64Encoded: String(decoding: signature, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? signature
        try verify(package: package, name: release.packageName, sums: String(decoding: sums, as: UTF8.self),
                   signature: signatureBytes, key: configuration.publicKey)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShieldUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(release.packageName)
        try package.write(to: file, options: .atomic)
        return file
    }
}
