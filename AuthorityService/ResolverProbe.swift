import Darwin
import Foundation

enum ResolverProbe {
    // Executed in a bounded child so a resolver stall cannot wedge authority.
    static func run(generation: UInt64, total: Int, domains: [String]) throws -> ResolverObservation {
        guard domains.count <= 8, total >= domains.count,
              domains.allSatisfy(PolicyValidation.validDomain) else {
            throw FixtureBackendError.invalidRequest("Invalid resolver sample.")
        }
        let results = domains.map { domain -> ResolverObservation.Result in
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var first: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(domain, nil, &hints, &first)
            guard status == 0, let first else {
                return .init(domain: domain, addresses: [], usesBlockingAddresses: false,
                             error: "Resolver error \(status)")
            }
            defer { freeaddrinfo(first) }
            var addresses = Set<String>()
            var entry: UnsafeMutablePointer<addrinfo>? = first
            while let value = entry {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(value.pointee.ai_addr, value.pointee.ai_addrlen,
                               &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    addresses.insert(String(cString: hostname))
                }
                entry = value.pointee.ai_next
            }
            return .init(domain: domain, addresses: Array(addresses.sorted().prefix(8)),
                usesBlockingAddresses: !addresses.isEmpty && addresses.isSubset(of: ["0.0.0.0", "127.0.0.1", "::1"]),
                error: nil)
        }
        return ResolverObservation(generation: generation, observedAt: .now, totalDomains: total,
                                   results: results, problem: nil)
    }

    /// `Array(domains.sorted().prefix(count))` without sorting the whole set.
    static func firstSorted(_ domains: Set<String>, _ count: Int) -> [String] {
        var smallest: [String] = []
        for domain in domains {
            if smallest.count < count {
                smallest.insert(domain, at: smallest.firstIndex { domain < $0 } ?? smallest.count)
            } else if let last = smallest.last, domain < last {
                smallest.removeLast()
                smallest.insert(domain, at: smallest.firstIndex { domain < $0 } ?? smallest.count)
            }
        }
        return smallest
    }

    static func childObservation(generation: UInt64, domains: Set<String>) -> ResolverObservation {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: AuthorityInstallation.executable)
            process.arguments = ["resolve", String(generation), String(domains.count)] + firstSorted(domains, 8)
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let done = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in done.signal() }
            try process.run()
            guard done.wait(timeout: .now() + 5) == .success else {
                kill(process.processIdentifier, SIGKILL)
                throw FixtureBackendError.uncertain("Resolver probe timed out.")
            }
            guard process.terminationStatus == 0 else {
                throw FixtureBackendError.uncertain("Resolver probe failed.")
            }
            let data = try output.fileHandleForReading.read(upToCount: 16_385) ?? Data()
            guard data.count <= 16_384 else { throw FixtureBackendError.uncertain("Resolver probe exceeded output limit.") }
            let observation = try JSONDecoder().decode(ResolverObservation.self, from: data)
            guard observation.generation == generation,
                  Set(observation.results.map(\.domain)) == Set(domains.sorted().prefix(8)) else {
                throw FixtureBackendError.uncertain("Resolver observation does not match current policy.")
            }
            return observation
        } catch {
            return ResolverObservation(generation: generation, observedAt: .now, totalDomains: domains.count,
                results: [], problem: error.localizedDescription)
        }
    }
}
