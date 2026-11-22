import Foundation

/// This Mac's time zone as macOS has it: the zone `/etc/localtime` names, and
/// whether "Set time zone automatically using your current location" is on.
enum SystemTimeZone {
    static func observe() -> ObservedZone? {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/etc/localtime"),
              let range = target.range(of: "zoneinfo/") else { return nil }
        let identifier = String(target[range.upperBound...])
        guard TimeZone(identifier: identifier) != nil else { return nil }
        let automatic = NSDictionary(contentsOfFile: "/Library/Preferences/com.apple.timezone.auto.plist")?["Active"]
        return ObservedZone(identifier: identifier, automatic: (automatic as? Bool) == true)
    }
}
