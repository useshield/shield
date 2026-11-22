// xcrun swift scripts/sign_update.swift <key-file> <Shield-x.y.pkg>
// Writes <Shield-x.y.pkg>.sig: Shield's signature over the package's SHA-256,
// which the app checks together with SHA256SUMS before opening an update.
import CryptoKit
import Foundation
guard CommandLine.arguments.count == 3 else { print("Usage: sign_update.swift <key-file> <package>"); exit(64) }
let keyText = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
guard let raw = Data(base64Encoded: keyText), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    print("Not a Shield update key."); exit(1)
}
let package = CommandLine.arguments[2]
let digest = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: package))).map { String(format: "%02x", $0) }.joined()
let signature = try key.signature(for: Data(digest.utf8)).base64EncodedString()
try Data((signature + "\n").utf8).write(to: URL(fileURLWithPath: package + ".sig"))
print("Signed \(package) (sha256 \(digest))")
