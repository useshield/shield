import Darwin
import Foundation

// Browser layer 2 (hardening): a SECONDARY mitigation. It reads
// the launch arguments of the user's browsers and recognizes switches that
// route around /etc/hosts:
//   --host-resolver-rules / --host-rules with a MAP that reaches a blocked host
//   --proxy-server (anything but direct://) and --proxy-pac-url, which let a
//     proxy resolve blocked hosts remotely.
// It is not network enforcement: a browser that doesn't take these switches,
// a proxy set inside an extension, or a system proxy is not seen here. The
// managed browser policy (layer 1) is what blocks those inside Chromium.
//
// Pure: no process access except `processArguments(pid:)`, which reads the
// arguments the same way `ps` does.

enum BrowserLaunchGuard {
    struct Finding: Codable, Equatable, Sendable {
        /// The switch name only. Its value is never stored (it can hold addresses).
        let switchName: String
        let reason: String
    }

    static let resolverSwitches: Set<String> = ["host-resolver-rules", "host-rules"]
    static let proxySwitches: Set<String> = ["proxy-server", "proxy-pac-url"]

    /// Chromium switches as (name, value). Both "--" and "-" prefixes count;
    /// a bare "--" ends the switches. Only "--name=value" carries a value.
    static func switches(_ arguments: [String]) -> [(name: String, value: String?)] {
        var found: [(String, String?)] = []
        for argument in arguments.dropFirst() {
            if argument == "--" { break }
            let body: Substring
            if argument.hasPrefix("--") { body = argument.dropFirst(2) }
            else if argument.hasPrefix("-") { body = argument.dropFirst() }
            else { continue }
            if let equals = body.firstIndex(of: "=") {
                found.append((body[..<equals].lowercased(), String(body[body.index(after: equals)...])))
            } else {
                found.append((body.lowercased(), nil))
            }
        }
        return found
    }

    /// A helper (renderer, GPU, network service) of a browser: it dies with
    /// the browser, so only the main process is ever acted on.
    static func isHelper(_ arguments: [String]) -> Bool {
        switches(arguments).contains { $0.name == "type" }
    }

    /// The host patterns that MAP rules redirect ("MAP <pattern> <target>").
    /// "~NOTFOUND" targets make a host fail, which never unblocks anything.
    static func mappedPatterns(_ rules: String) -> [String] {
        rules.split(separator: ",").compactMap { rule in
            let words = rule.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard words.count >= 3, words[0].uppercased() == "MAP", words[2].uppercased() != "~NOTFOUND" else { return nil }
            return words[1].lowercased()
        }
    }

    /// Chromium's host pattern match: "*" matches any run of characters
    /// (dots included); an optional ":port" on the pattern is ignored here.
    static func pattern(_ pattern: String, matches host: String) -> Bool {
        var pattern = Substring(pattern)
        if let colon = pattern.lastIndex(of: ":"), pattern[pattern.index(after: colon)...].allSatisfy(\.isNumber) {
            pattern = pattern[..<colon]
        }
        return glob(Array(pattern), Array(host))
    }

    private static func glob(_ pattern: [Character], _ text: [Character]) -> Bool {
        var p = 0, t = 0, star = -1, mark = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "*" { star = p; mark = t; p += 1 }
            else if p < pattern.count, pattern[p] == text[t] { p += 1; t += 1 }
            else if star >= 0 { p = star + 1; mark += 1; t = mark }
            else { return false }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }

    /// What, in these arguments, routes around the blocked hosts right now.
    /// Nothing is a bypass while nothing is blocked; the service re-checks
    /// every pass, so a browser started in allowed hours is caught when a
    /// block begins.
    static func findings(arguments: [String], blockedHosts: Set<String>) -> [Finding] {
        guard !blockedHosts.isEmpty, !isHelper(arguments) else { return [] }
        var findings: [Finding] = []
        for (name, value) in switches(arguments) {
            if resolverSwitches.contains(name), let value {
                let patterns = mappedPatterns(value)
                if patterns.contains(where: { pattern in blockedHosts.contains { Self.pattern(pattern, matches: $0) } }) {
                    findings.append(Finding(switchName: name, reason: "redirects a blocked site around Shield"))
                }
            } else if proxySwitches.contains(name) {
                let target = (value ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                if name == "proxy-server", target.isEmpty || target == "direct://" { continue }
                findings.append(Finding(switchName: name, reason: "sends browsing through a proxy that ignores Shield"))
            }
        }
        return findings
    }

    /// Cheap pre-check before any parsing or signature reading.
    /// Same switch syntax as `switches(_:)`, but only names are looked at:
    /// browser helpers carry very long feature lists, and this runs for every
    /// app process on every pass.
    static func mentionsBypassSwitch(_ arguments: [String]) -> Bool {
        for argument in arguments.dropFirst() {
            if argument == "--" { break }
            guard argument.hasPrefix("-") else { continue }
            let body = argument.drop { $0 == "-" }
            let name = body.prefix { $0 != "=" }
            guard name.count <= longestBypassSwitch else { continue }
            if bypassSwitches.contains(name.lowercased()) { return true }
        }
        return false
    }
    static let bypassSwitches = resolverSwitches.union(proxySwitches)
    private static let longestBypassSwitch = bypassSwitches.map(\.count).max() ?? 0

    // MARK: Reading another process's arguments

    /// argv of `pid`, as `ps` reads it (KERN_PROCARGS2), or nil when the
    /// process is gone or not readable.
    static func processArguments(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argumentMax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argumentMax, &size, nil, 0) == 0, argumentMax > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argumentMax))
        size = buffer.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcessArguments(Array(buffer.prefix(size)))
    }

    /// Layout: Int32 argc, the executable path, NUL padding, then argc
    /// NUL-terminated arguments (the environment follows and is ignored).
    static func parseProcessArguments(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count >= 4 else { return nil }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        guard argc >= 0, argc <= 65_536 else { return nil }
        var index = 4
        while index < bytes.count, bytes[index] != 0 { index += 1 }   // executable path
        while index < bytes.count, bytes[index] == 0 { index += 1 }   // padding
        var arguments: [String] = []
        while arguments.count < argc, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == argc ? arguments : nil
    }
}
