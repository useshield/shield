import Foundation

// Browser layer 1 (hardening): admin-managed browser policy,
// generated from the SAME effective blocked set that the hosts section gets
// (when that is over Chrome's 1,000-entry limit, the whole rules that fit,
// smallest first; see `fitting`).
// It is never a second rule system: no schedules, places or owners live here,
// only "which hosts are blocked right now", rewritten whenever that changes.
//
// Why: a separate Chrome profile started with --host-resolver-rules (or a
// proxy) never asks the system resolver, so /etc/hosts can't stop it.
// URLBlocklist is checked on the URL before any lookup, in every profile,
// Incognito and Guest, whatever resolver or proxy the browser uses. Chrome
// only honors it at the MANDATORY level, which on macOS means a forced value
// from /Library/Managed Preferences (verified: a user-level default is
// ignored).
//
// Pure: no file access. `InstalledBrowserPolicyWriter` writes the documents.

enum BrowserManagedPolicy {
    /// Preference domains that Chromium-family browsers read Chrome's policy
    /// names from (every Chrome channel reads com.google.Chrome; every Edge
    /// channel reads com.microsoft.Edge; Chrome for Testing reads its own).
    static let chromiumDomains: [String] = [
        "com.google.Chrome", "com.google.ChromeForTesting", "org.chromium.Chromium",
        "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
        "com.microsoft.Edge", "com.vivaldi.Vivaldi",
    ]
    /// Firefox reads its enterprise policies from this domain.
    static let firefoxDomain = "org.mozilla.firefox"
    static var allDomains: [String] { chromiumDomains + [firefoxDomain] }

    /// Chrome's own limit for URLBlocklist.
    static let maximumPatterns = 1_000

    /// Parents shared by unrelated services (study tools live under them).
    /// If the authority ever lists one of these bare, only that exact host is
    /// blocked here, never every subdomain, so no study site is caught by accident.
    static let sharedParents: Set<String> = [
        "google.com", "googleapis.com", "gstatic.com", "googleusercontent.com", "apple.com", "icloud.com",
        "microsoft.com", "live.com", "office.com", "amazonaws.com", "cloudfront.net", "akamaihd.net",
        "akamaized.net", "fastly.net", "github.com", "githubusercontent.com", "cloudflare.com", "azureedge.net",
    ]

    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")

    /// Normalized, valid host names; anything odd is dropped rather than guessed at.
    static func hosts(_ domains: Set<String>) -> Set<String> {
        Set(domains.compactMap { raw in
            var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while host.hasSuffix(".") { host.removeLast() }
            guard !host.isEmpty, host.count <= 253, host.contains("."), !host.hasPrefix("."),
                  host.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                  !host.contains("..") else { return nil }
            return host
        })
    }

    /// The hosts that cover `domains`: a listed host blocks itself and its
    /// subdomains, so a host already under a listed parent is dropped.
    /// Shared parents cover only themselves.
    static func coveringHosts(_ domains: Set<String>) -> [String] {
        let all = hosts(domains)
        let parents = all.subtracting(sharedParents)
        // Checks each parent label suffix of a host (a.b.c → b.c → c): linear
        // in the list, so lists of thousands of sites stay cheap.
        return all.filter { host in
            var rest = Substring(host)
            while let dot = rest.firstIndex(of: ".") {
                rest = rest[rest.index(after: dot)...]
                if parents.contains(String(rest)) { return false }
            }
            return true
        }.sorted()
    }

    /// The part of the blocked set that browser policy carries, given each
    /// rule's websites. Everything when it fits Chrome's limit. Otherwise
    /// whole rules, smallest first (hand-made blocks before big imported
    /// lists), so one large list never pushes the rest out of the browser
    /// layer. Left-out rules are still blocked by hosts. Deterministic for a
    /// given set of rules.
    static func fitting(_ groups: [Set<String>]) -> (domains: Set<String>, leftOut: Int) {
        let all = groups.reduce(into: Set<String>()) { $0.formUnion($1) }
        if chromiumPatterns(all).count <= maximumPatterns { return (all, 0) }
        let ordered = groups.filter { !$0.isEmpty }.map { group in
            (group: group, size: chromiumPatterns(group).count, first: group.min() ?? "", last: group.max() ?? "")
        }.sorted { ($0.size, $0.first, $0.last) < ($1.size, $1.first, $1.last) }
        var chosen = Set<String>()
        var leftOut = Set<String>()
        for entry in ordered {
            let candidate = chosen.union(entry.group)
            if chromiumPatterns(candidate).count <= maximumPatterns {
                chosen = candidate
            } else {
                leftOut.formUnion(entry.group)
            }
        }
        return (chosen, coveringHosts(leftOut.subtracting(chosen)).count)
    }

    /// Chrome URLBlocklist patterns. "example.com" blocks the host and every
    /// subdomain on any scheme and port; ".example.com" blocks the exact host.
    static func chromiumPatterns(_ domains: Set<String>) -> [String] {
        coveringHosts(domains).map { sharedParents.contains($0) ? "." + $0 : $0 }
    }

    /// Firefox WebsiteFilter match patterns.
    static func firefoxPatterns(_ domains: Set<String>) -> [String] {
        coveringHosts(domains).flatMap { host in
            sharedParents.contains(host) ? ["*://\(host)/*"] : ["*://\(host)/*", "*://*.\(host)/*"]
        }
    }

    enum Problem: Error, Equatable {
        case tooManyPatterns(Int)
    }

    /// One managed-preferences document per browser domain, or a problem.
    /// The documents hold ONLY the block list: nothing else in the browser is
    /// restricted, so studying, extensions, profiles and Incognito keep working.
    static func documents(for domains: Set<String>) -> Result<[String: [String: Any]], Problem> {
        let chromium = chromiumPatterns(domains)
        guard chromium.count <= maximumPatterns else { return .failure(.tooManyPatterns(chromium.count)) }
        var documents: [String: [String: Any]] = [:]
        for domain in chromiumDomains { documents[domain] = ["URLBlocklist": chromium] }
        documents[firefoxDomain] = [
            "EnterprisePoliciesEnabled": true,
            "WebsiteFilter": ["Block": firefoxPatterns(domains), "Exceptions": [String]()],
        ]
        return .success(documents)
    }

    /// Deterministic XML property list bytes (sorted keys), so an unchanged
    /// policy is never rewritten and a hash comparison is exact.
    static func propertyList(_ document: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: document, format: .xml, options: 0)
    }

    /// The blocked hosts a written Chromium document really carries, for verification.
    static func blockedPatterns(inPropertyList data: Data) -> [String]? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        if let list = plist["URLBlocklist"] as? [String] { return list }
        if let filter = plist["WebsiteFilter"] as? [String: Any] { return filter["Block"] as? [String] }
        return nil
    }
}
