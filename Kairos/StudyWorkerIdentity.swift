import Foundation
import Security

enum StudyWorkerIdentity {
    static let identifier = "com.kairos.ShieldDevelopment.StudyWorker"
    static func clientRequirement(in bundle: URL) throws -> String {
        let file = bundle.appendingPathComponent("Contents/Resources/client-certificate.sha1")
        let bytes = try StudyBoundedFile.read(file, limit: 41)
        guard let text = String(data: bytes, encoding: .utf8) else { throw StudyDownloadError.unsafePath }
        return try clientRequirement(certificateSHA1: text.trimmingCharacters(in: .newlines))
    }

    static func clientRequirement(certificateSHA1 digest: String) throws -> String {
        guard digest.utf8.count == 40, digest.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw StudyDownloadError.invalidManifest("Missing pinned Development signing certificate.")
        }
        return "identifier \"com.kairos.ShieldDevelopment\" and certificate leaf = H\"\(digest)\""
    }
    static func requirement(for url: URL, identifier: String, requireSandbox: Bool = false) throws -> String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
            throw StudyDownloadError.invalidManifest("Worker or host signature is invalid.")
        }
        var metadata: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &metadata) == errSecSuccess,
              let info = metadata as? [String: Any], info[kSecCodeInfoIdentifier as String] as? String == identifier,
              let digest = info[kSecCodeInfoUnique as String] as? Data, digest.count == 20 else {
            throw StudyDownloadError.invalidManifest("Worker or host signing identity is unavailable.")
        }
        if requireSandbox {
            guard let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
                  Set(entitlements.keys) == ["com.apple.security.app-sandbox", "com.apple.security.network.client"],
                  entitlements.values.allSatisfy({ ($0 as? Bool) == true }) else {
                throw StudyDownloadError.invalidManifest("Worker sandbox entitlements are missing or broader than expected.")
            }
        }
        return "identifier \"\(identifier)\" and cdhash H\"\(digest.map { String(format: "%02x", $0) }.joined())\""
    }
}
