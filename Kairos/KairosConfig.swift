import Foundation

enum KairosConfig {
    static let directoryURL = ShieldRuntime.supportDirectory

    static let fileURL =
        directoryURL.appendingPathComponent("config.plist")

    static func load() -> [String: Any] {
        guard ShieldRuntime.permitsStateRead(from: fileURL) else { return [:] }
        guard
            let data = try? Data(contentsOf: fileURL),
            let object = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ),
            let dictionary = object as? [String: Any]
        else {
            return [:]
        }

        return dictionary
    }

    static func save(
        youtubeEnabled: Bool,
        socialEnabled: Bool,
        updatedAt: Date = .now
    ) throws {
        try ShieldRuntime.requireIsolatedWrite(to: fileURL)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var config = load()

        // Remove obsolete test/V0 keys.
        config.removeValue(forKey: "Mode")
        config.removeValue(forKey: "SafeUntilEpoch")

        config["YouTubeEnabled"] = youtubeEnabled
        config["YouTubeStartMinutes"] = 840      // 2 PM
        config["YouTubeEndMinutes"] = 1080       // 6 PM

        config["SocialEnabled"] = socialEnabled
        config["SocialMorningStartMinutes"] = 420 // 7 AM
        config["SocialMorningEndMinutes"] = 780   // 1 PM
        config["SocialNightStartMinutes"] = 1200  // 8 PM
        config["SocialNightEndMinutes"] = 480     // 8 AM
        config["SchemaVersion"] = 1
        config["UpdatedAt"] = updatedAt

        let data = try PropertyListSerialization.data(
            fromPropertyList: config,
            format: .xml,
            options: 0
        )

        try AtomicFixtureStore(allowedRoot: directoryURL).write(data, to: fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
