import Foundation
import Network

// Download egress broker (docs/download-egress-threat-model.md). The only
// process in a download job with real network access. It listens on 127.0.0.1
// only, for a bounded lifetime, and applies EgressPolicy to every CONNECT.
// Allowlisted names are resolved with DNS-over-HTTPS
// to fixed resolver IPs (SHIELD_BROKER_RESOLVER=doh), never the system resolver,
// so system hosts blocking stays in force for every other process. Without that
// flag every allowed CONNECT is answered 502. Test mode maps *.shield.test names
// to loopback upstreams for adversarial integration tests.

struct BrokerConfiguration {
    let listenPort: UInt16
    let policy: EgressPolicy
    let testUpstreams: [String: String]   // host -> IPv4 loopback address
    let resolver: DoHResolver?
    let maximumTunnels = 8
    let maximumTunnelBytes: Int64 = 3_000_000_000
    let idleTimeout: TimeInterval = 60

    static func fromEnvironment() throws -> BrokerConfiguration {
        let env = ProcessInfo.processInfo.environment
        func fail(_ message: String) -> NSError {
            NSError(domain: "EgressBroker", code: 64, userInfo: [NSLocalizedDescriptionKey: message])
        }
        guard let port = env["SHIELD_BROKER_PORT"].flatMap(UInt16.init), port > 1024 else {
            throw fail("SHIELD_BROKER_PORT must be an unprivileged port")
        }
        guard let credential = env["SHIELD_BROKER_CREDENTIAL"], credential.count >= 24 else {
            throw fail("SHIELD_BROKER_CREDENTIAL must be a high-entropy Proxy-Authorization value")
        }
        guard let lifetime = env["SHIELD_BROKER_SECONDS"].flatMap(TimeInterval.init),
              lifetime > 0, lifetime <= 3_900 else {
            throw fail("SHIELD_BROKER_SECONDS must be within one download job (<= 3900)")
        }
        let ports = Set((env["SHIELD_BROKER_PORTS"] ?? "443").split(separator: ",").compactMap { UInt16($0) })
        var upstreams: [String: String] = [:]
        for pair in (env["SHIELD_BROKER_TEST_UPSTREAMS"] ?? "").split(separator: ",") {
            let parts = pair.split(separator: "=")
            guard parts.count == 2, parts[0].hasSuffix(".shield.test"), parts[1] == "127.0.0.1" else {
                throw fail("Test upstreams must map *.shield.test to 127.0.0.1")
            }
            upstreams[String(parts[0])] = String(parts[1])
        }
        // Test mode allowlists exactly the test names; production allowlist
        // is the (unmeasured) YouTube candidate, whose resolver is absent.
        let allowlist = upstreams.isEmpty ? EgressAllowlist.youtubeDownloadCandidate
            : EgressAllowlist(exactHosts: Set(upstreams.keys), subdomainSuffixes: [])
        let policy = EgressPolicy(allowlist: allowlist, allowedPorts: ports.isEmpty ? [443] : ports,
                                  credential: credential, expiresAt: Date().addingTimeInterval(lifetime),
                                  requireTLS: env["SHIELD_BROKER_REQUIRE_TLS"] != "0")
        let resolver: DoHResolver?
        switch env["SHIELD_BROKER_RESOLVER"] ?? "none" {
        case "none": resolver = nil
        case "doh" where upstreams.isEmpty: resolver = DoHResolver()
        default: throw fail("SHIELD_BROKER_RESOLVER must be none, or doh outside test mode")
        }
        return BrokerConfiguration(listenPort: port, policy: policy, testUpstreams: upstreams, resolver: resolver)
    }
}

func log(_ event: String, _ fields: [String: String] = [:]) {
    var record = fields
    record["event"] = event
    if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

final class Tunnel {
    private let client: NWConnection
    private let configuration: BrokerConfiguration
    private let queue: DispatchQueue
    private let onClose: (Tunnel) -> Void
    private var upstream: NWConnection?
    private var header = Data()
    private var pending: [UInt8] = []
    private var host = ""
    private var transferred: Int64 = 0
    private var lastActivity = Date()
    private var closed = false

    init(client: NWConnection, configuration: BrokerConfiguration, queue: DispatchQueue,
         onClose: @escaping (Tunnel) -> Void) {
        self.client = client
        self.configuration = configuration
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        client.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.upstream == nil, !self.closed else { return }
            self.deny(.malformedRequest, status: "408 Request Timeout")
        }
        readHeader()
    }

    private func readHeader() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let data { self.header.append(data) }
            if let end = self.header.range(of: Data("\r\n\r\n".utf8)) {
                let request = self.header[..<end.upperBound]
                self.pending = Array(self.header[end.upperBound...])
                self.decide(Data(request))
            } else if self.header.count > EgressConnectRequest.maximumHeaderBytes {
                self.deny(.requestTooLarge, status: "431 Request Header Fields Too Large")
            } else if done || error != nil {
                self.close("client closed before request")
            } else {
                self.readHeader()
            }
        }
    }

    private func decide(_ request: Data) {
        switch configuration.policy.evaluate(request, now: Date()) {
        case .deny(let reason):
            // Record the requested name (never credentials) so the allowlist can be measured.
            if case .success(let parsed) = EgressConnectRequest.parse(request) { host = parsed.host }
            let status = switch reason {
            case .missingCredential, .wrongCredential: "407 Proxy Authentication Required"
            case .malformedRequest, .notConnect, .requestTooLarge: "400 Bad Request"
            default: "403 Forbidden"
            }
            deny(reason, status: status)
        case .allow(let host, let port):
            self.host = host
            if let address = configuration.testUpstreams[host] {
                connect(address: address, port: port)
            } else if let resolver = configuration.resolver {
                resolver.resolve(host) { [weak self] address in
                    self?.queue.async {
                        guard let self, !self.closed else { return }
                        guard let address else {
                            log("deny", ["reason": "resolutionFailed", "host": host])
                            self.respond("502 Bad Gateway") { self.close("resolution failed") }
                            return
                        }
                        self.connect(address: address, port: port)
                    }
                }
            } else {
                // No approved resolver: fail closed instead of using the
                // system resolver (hosts-blocked).
                log("deny", ["reason": "resolverNotApproved", "host": host])
                respond("502 Bad Gateway", then: { self.close("resolver not approved") })
            }
        }
    }

    private func connect(address: String, port: UInt16) {
            let host = self.host
            let target = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!,
                                      using: .tcp)
            upstream = target
            target.stateUpdateHandler = { [weak self] state in
                guard let self, !self.closed else { return }
                switch state {
                case .ready:
                    log("allow", ["host": host, "port": String(port), "address": address])
                    self.respond("200 Connection Established") { self.inspectFirstBytes() }
                case .failed, .cancelled:
                    self.respond("502 Bad Gateway") { self.close("upstream unavailable") }
                default: break
                }
            }
            target.start(queue: queue)
    }

    private func deny(_ reason: EgressDenial, status: String) {
        log("deny", ["reason": reason.rawValue, "host": host])
        respond(status) { self.close(reason.rawValue) }
    }

    private func respond(_ status: String, then next: @escaping () -> Void) {
        client.send(content: Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\n\r\n".utf8),
                    completion: .contentProcessed { _ in next() })
    }

    private func inspectFirstBytes() {
        let decision = configuration.policy.evaluateFirstBytes(pending, connectHost: host)
        if !configuration.policy.requireTLS {
            startPumping()
            return
        }
        switch decision {
        case .deny(let reason)?:
            log("deny", ["reason": reason.rawValue, "host": host])
            close(reason.rawValue)
        case .allow?:
            startPumping()
        case nil:
            guard pending.count < TLSServerName.maximumClientHelloBytes + 5 else {
                close("client hello too large"); return
            }
            client.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, done, error in
                guard let self, !self.closed else { return }
                if let data { self.pending += data }
                if (done || error != nil) && data == nil { self.close("client closed during hello"); return }
                self.inspectFirstBytes()
            }
        }
    }

    private func startPumping() {
        guard let upstream else { return }
        let first = Data(pending)
        pending = []
        upstream.send(content: first, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.pump(from: self.client, to: upstream)
            self.pump(from: upstream, to: self.client)
            self.watchIdle()
        })
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.transferred += Int64(data.count)
                self.lastActivity = Date()
                guard self.transferred <= self.configuration.maximumTunnelBytes else {
                    self.close("byte cap reached"); return
                }
                guard Date() < self.configuration.policy.expiresAt else { self.close("job expired"); return }
                destination.send(content: data, completion: .contentProcessed { _ in
                    if done || error != nil { self.close("peer finished") } else { self.pump(from: source, to: destination) }
                })
            } else if done || error != nil {
                self.close("peer finished")
            } else {
                self.pump(from: source, to: destination)
            }
        }
    }

    private func watchIdle() {
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.closed else { return }
            if Date().timeIntervalSince(self.lastActivity) > self.configuration.idleTimeout ||
                Date() >= self.configuration.policy.expiresAt {
                self.close("idle or expired")
            } else {
                self.watchIdle()
            }
        }
    }

    func close(_ reason: String) {
        guard !closed else { return }
        closed = true
        client.cancel()
        upstream?.cancel()
        log("close", ["host": host, "reason": reason, "bytes": String(transferred)])
        onClose(self)
    }
}

// DNS-over-HTTPS (RFC 8484 JSON form) to fixed resolver addresses. Only names
// the policy already allowed reach here. Answers must be public unicast IPv4,
// so a hostile or poisoned answer cannot point the tunnel at loopback or LAN.
final class DoHResolver: @unchecked Sendable {
    static let endpoints = ["https://1.1.1.1/dns-query", "https://1.0.0.1/dns-query"]
    private let session: URLSession
    private let lock = NSLock()
    private var cache: [String: (address: String, expires: Date)] = [:]

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 8
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    func resolve(_ host: String, completion: @escaping @Sendable (String?) -> Void) {
        lock.lock()
        if let hit = cache[host], hit.expires > Date() { lock.unlock(); completion(hit.address); return }
        lock.unlock()
        query(host, endpoints: Self.endpoints[...], completion: completion)
    }

    private func query(_ host: String, endpoints: ArraySlice<String>, completion: @escaping @Sendable (String?) -> Void) {
        guard let endpoint = endpoints.first,
              var components = URLComponents(string: endpoint) else { completion(nil); return }
        components.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: "A")]
        var request = URLRequest(url: components.url!)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { [weak self] data, response, _ in
            guard let self else { completion(nil); return }
            if let data, (response as? HTTPURLResponse)?.statusCode == 200,
               let answer = EgressResolverAnswer.firstPublicAddress(in: data) {
                self.lock.lock()
                self.cache[host] = (answer.address, Date().addingTimeInterval(min(max(answer.ttl, 30), 300)))
                self.lock.unlock()
                completion(answer.address)
            } else {
                self.query(host, endpoints: endpoints.dropFirst(), completion: completion)
            }
        }.resume()
    }

}

let configuration: BrokerConfiguration
do {
    configuration = try BrokerConfiguration.fromEnvironment()
} catch {
    FileHandle.standardError.write(Data("egress broker: \(error.localizedDescription)\n".utf8))
    exit(64)
}
let queue = DispatchQueue(label: "shield.egress-broker")
var tunnels: [ObjectIdentifier: Tunnel] = [:]
let parameters = NWParameters.tcp
parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1",
                                             port: NWEndpoint.Port(rawValue: configuration.listenPort)!)
let listener = try NWListener(using: parameters)
listener.newConnectionHandler = { connection in
    guard tunnels.count < configuration.maximumTunnels, Date() < configuration.policy.expiresAt else {
        log("deny", ["reason": tunnels.count >= configuration.maximumTunnels ? "tooManyTunnels" : "expired"])
        connection.cancel()
        return
    }
    let tunnel = Tunnel(client: connection, configuration: configuration, queue: queue) { finished in
        tunnels[ObjectIdentifier(finished)] = nil
    }
    tunnels[ObjectIdentifier(tunnel)] = tunnel
    tunnel.start()
}
listener.stateUpdateHandler = { state in
    switch state {
    case .ready: log("listening", ["port": String(configuration.listenPort),
                                   "mode": !configuration.testUpstreams.isEmpty ? "test"
                                       : configuration.resolver == nil ? "noResolver" : "doh"])
    case .failed(let error): log("listenerFailed", ["error": "\(error)"]); exit(1)
    default: break
    }
}
listener.start(queue: queue)
// Hard lifetime: the broker exits when its job window ends.
queue.asyncAfter(deadline: .now() + configuration.policy.expiresAt.timeIntervalSinceNow) {
    log("expired")
    exit(0)
}
// And with Shield: if Shield quits or crashes mid-download, nothing is left
// listening for up to an hour (audit).
let parent = getppid()
if parent <= 1 { log("parentGone"); exit(0) }
let parentWatch = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: queue)
parentWatch.setEventHandler {
    log("parentGone")
    exit(0)
}
parentWatch.resume()
if getppid() != parent { log("parentGone"); exit(0) }
dispatchMain()
