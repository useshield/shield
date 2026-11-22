import Foundation

struct LegacyAuthorityInspection: Codable, Sendable {
    let classification: String
    let reason: String
    let mayMigrateAutomatically: Bool
}

struct LegacyAuthorityInspector: Sendable {
    // A read-only rehearsal. Even a parseable schema-1 file is not evidence
    // that every historical commitment was recovered independently.
    func inspect(_ url: URL, now: Date = .now) -> LegacyAuthorityInspection {
        let result = AuthorityStateReader(fileURL: url, maximumAge: .infinity).read(now: now)
        switch result {
        case .valid(let state):
            return LegacyAuthorityInspection(
                classification: "readable-untrusted",
                reason: "Schema \(state.schemaVersion), generation \(state.generation) parses; historical commitment provenance remains unknown.",
                mayMigrateAutomatically: false)
        case .unavailable(let error):
            return LegacyAuthorityInspection(classification: "unknown",
                                             reason: error.localizedDescription,
                                             mayMigrateAutomatically: false)
        }
    }
}
