// Run once, by the user: xcrun swift scripts/make_update_key.swift <new-key-file>
// Makes Shield's update-signing key. Keep the key file offline with the
// .p12 certificate backup; anyone holding it can sign Shield updates.
// Prints the public key to put in the release build (ShieldUpdatePublicKey).
import CryptoKit
import Foundation
guard CommandLine.arguments.count == 2 else { print("Usage: make_update_key.swift <new-key-file>"); exit(64) }
let path = CommandLine.arguments[1]
guard !FileManager.default.fileExists(atPath: path) else { print("Refusing to overwrite \(path)"); exit(1) }
let key = Curve25519.Signing.PrivateKey()
guard FileManager.default.createFile(atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
                                     attributes: [.posixPermissions: 0o600]) else { print("Couldn't write \(path)"); exit(1) }
print("Public key (safe to publish): \(key.publicKey.rawRepresentation.base64EncodedString())")
