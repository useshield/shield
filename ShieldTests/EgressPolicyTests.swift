import Foundation
import Testing
@testable import Shield

// Adversarial tests for the prototype egress broker's pure policy. A passing
// suite is necessary, not sufficient: the OS sandbox and the broker process
// are exercised separately by scripts/test_egress_broker.sh.
struct EgressPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let credential = "Basic am9iOnNlY3JldA=="

    private func policy(requireTLS: Bool = true, expires: TimeInterval = 600) -> EgressPolicy {
        EgressPolicy(allowlist: .youtubeDownloadCandidate, allowedPorts: [443], credential: credential,
                     expiresAt: now.addingTimeInterval(expires), requireTLS: requireTLS)
    }

    private func connect(_ authority: String, auth: String? = "Basic am9iOnNlY3JldA==",
                         extra: String = "") -> Data {
        var text = "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\n"
        if let auth { text += "Proxy-Authorization: \(auth)\r\n" }
        return Data((text + extra + "\r\n").utf8)
    }

    @Test func allowlistedHostsOn443AreAllowed() {
        #expect(policy().evaluate(connect("www.youtube.com:443"), now: now) ==
                .allow(host: "www.youtube.com", port: 443))
        #expect(policy().evaluate(connect("rr3---sn-abc.googlevideo.com:443"), now: now) ==
                .allow(host: "rr3---sn-abc.googlevideo.com", port: 443))
        #expect(policy().evaluate(connect("WWW.YouTube.com.:443"), now: now) ==
                .allow(host: "www.youtube.com", port: 443))
    }

    @Test func nonAllowlistedAndLookalikeHostsAreDenied() {
        for host in ["example.com", "youtube.com", "m.youtube.com", "googlevideo.com",
                     "evilgooglevideo.com", "www.youtube.com.evil.example", "youtube.com.googlevideo.example",
                     "accounts.google.com"] {
            #expect(policy().evaluate(connect("\(host):443"), now: now) == .deny(.hostNotAllowed), "\(host)")
        }
    }

    @Test func everyAddressLiteralFormIsDenied() {
        for host in ["142.250.1.1", "2398766593", "0x8efa0101", "0216.0372.01.01", "142.250.257",
                     "127.1", "1.1.1.1.", "[2607:f8b0::200e]", "[::1]", "[::ffff:127.0.0.1]",
                     "[fe80::1%en0]"] {
            #expect(policy().evaluate(connect("\(host):443"), now: now) == .deny(.ipLiteral), "\(host)")
        }
    }

    @Test func otherPortsAreDenied() {
        for port in ["80", "8443", "22", "53"] {
            #expect(policy().evaluate(connect("www.youtube.com:\(port)"), now: now) == .deny(.portNotAllowed))
        }
    }

    @Test func credentialIsRequiredAndCompared() {
        #expect(policy().evaluate(connect("www.youtube.com:443", auth: nil), now: now) == .deny(.missingCredential))
        #expect(policy().evaluate(connect("www.youtube.com:443", auth: "Basic am9iOnNlY3JldB=="), now: now) ==
                .deny(.wrongCredential))
        #expect(policy().evaluate(connect("www.youtube.com:443", auth: credential + "x"), now: now) ==
                .deny(.wrongCredential))
        #expect(!EgressPolicy.constantTimeEqual("", "a"))
        #expect(EgressPolicy.constantTimeEqual("same", "same"))
    }

    @Test func expiredJobsRefuseEverything() {
        let expired = policy(expires: -1)
        #expect(expired.evaluate(connect("www.youtube.com:443"), now: now) == .deny(.expired))
    }

    @Test func malformedOversizedAndNonConnectRequestsAreDenied() {
        let cases: [(Data, EgressDenial)] = [
            (Data("GET http://www.youtube.com/ HTTP/1.1\r\n\r\n".utf8), .notConnect),
            (Data("CONNECT www.youtube.com:443 HTTP/1.1\r\n".utf8), .malformedRequest),     // no blank line
            (Data("CONNECT www.youtube.com HTTP/1.1\r\n\r\n".utf8), .malformedRequest),     // no port
            (Data("CONNECT www.youtube.com:0 HTTP/1.1\r\n\r\n".utf8), .malformedRequest),
            (Data("CONNECT www.youtube.com:443 HTTP/2\r\n\r\n".utf8), .malformedRequest),
            (Data("CONNECT  www.youtube.com:443 HTTP/1.1\r\n\r\n".utf8), .malformedRequest),
            (connect("www.youtube.com:443", extra: " folded: header\r\n"), .malformedRequest),
            (connect("www.youtube.com:443", extra: "Proxy-Authorization: Basic eA==\r\n"), .malformedRequest),
            (Data("CONNECT www.you\u{0}tube.com:443 HTTP/1.1\r\n\r\n".utf8), .malformedRequest),
            (Data(("CONNECT www.youtube.com:443 HTTP/1.1\r\nX: " +
                   String(repeating: "a", count: 5_000) + "\r\n\r\n").utf8), .requestTooLarge)
        ]
        for (data, denial) in cases {
            #expect(policy().evaluate(data, now: now) == .deny(denial))
        }
    }

    @Test func invalidHostnamesAreDenied() {
        for host in ["www..youtube.com", "-www.youtube.com", "www_youtube.com", "*.googlevideo.com"] {
            #expect(policy().evaluate(connect("\(host):443"), now: now) == .deny(.invalidHost), "\(host)")
        }
    }

    @Test func tunnelMustStartWithClientHelloNamingTheConnectHost() {
        let p = policy()
        #expect(p.evaluateFirstBytes(Self.clientHello(serverName: "www.youtube.com"),
                                     connectHost: "www.youtube.com") == .allow(host: "www.youtube.com", port: 0))
        // Domain fronting: CONNECT to an allowed host but TLS names another.
        #expect(p.evaluateFirstBytes(Self.clientHello(serverName: "www.example.com"),
                                     connectHost: "www.youtube.com") == .deny(.serverNameMismatch))
        #expect(p.evaluateFirstBytes(Self.clientHello(serverName: nil),
                                     connectHost: "www.youtube.com") == .deny(.missingServerName))
        #expect(p.evaluateFirstBytes(Array("GET / HTTP/1.1\r\n".utf8),
                                     connectHost: "www.youtube.com") == .deny(.notTLS))
        let partial = Array(Self.clientHello(serverName: "www.youtube.com").prefix(20))
        #expect(p.evaluateFirstBytes(partial, connectHost: "www.youtube.com") == nil)
        #expect(policy(requireTLS: false).evaluateFirstBytes(Array("GET".utf8), connectHost: "x") == nil)
    }

    @Test func malformedClientHellosAreNotTLS() {
        var duplicate = Self.clientHello(serverName: "www.youtube.com", duplicateSNI: true)
        #expect(TLSServerName.parse(duplicate) == .notTLS)
        duplicate[5] = 0x02   // ServerHello, not ClientHello
        #expect(TLSServerName.parse(duplicate) == .notTLS)
        var oversized = Self.clientHello(serverName: "www.youtube.com")
        oversized[3] = 0xFF; oversized[4] = 0xFF
        #expect(TLSServerName.parse(oversized) == .notTLS)
        #expect(TLSServerName.parse([]) == .needMoreData)
        #expect(TLSServerName.parse([0x16, 0x03]) == .needMoreData)
    }

    // Minimal, well-formed TLS 1.2-style ClientHello with optional SNI.
    static func clientHello(serverName: String?, duplicateSNI: Bool = false) -> [UInt8] {
        func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        var extensions: [UInt8] = []
        if let serverName {
            let name = Array(serverName.utf8)
            let entry: [UInt8] = [0x00] + u16(name.count) + name
            let sni = u16(0x0000) + u16(entry.count + 2) + u16(entry.count) + entry
            extensions += sni
            if duplicateSNI { extensions += sni }
        }
        extensions += u16(0x000b) + u16(2) + [0x01, 0x00]          // ec_point_formats
        var body: [UInt8] = [0x03, 0x03] + Array(repeating: 0x2A, count: 32)
        body += [0x00]                                              // session id
        body += u16(2) + [0x13, 0x01]                               // one cipher suite
        body += [0x01, 0x00]                                        // null compression
        body += u16(extensions.count) + extensions
        let handshake: [UInt8] = [0x01, 0x00] + u16(body.count) + body
        return [0x16, 0x03, 0x01] + u16(handshake.count) + handshake
    }
}
