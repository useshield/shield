import Darwin
import Foundation

// Pure decision logic for the download egress broker
// (docs/download-egress-threat-model.md). No sockets, no DNS, no state.

enum EgressDenial: String, Error, Equatable, Sendable {
    case malformedRequest
    case requestTooLarge
    case notConnect
    case missingCredential
    case wrongCredential
    case ipLiteral
    case invalidHost
    case hostNotAllowed
    case portNotAllowed
    case expired
    case notTLS
    case missingServerName
    case serverNameMismatch
}

enum EgressDecision: Equatable, Sendable {
    case allow(host: String, port: UInt16)
    case deny(EgressDenial)
}

struct EgressAllowlist: Equatable, Sendable {
    let exactHosts: Set<String>
    // Each suffix starts with "." and matches only strict subdomains.
    let subdomainSuffixes: Set<String>

    // Designed, NOT measured: the hosts a yt-dlp watch-page fetch needs must
    // be recorded from an approved run before this list is trusted.
    static let youtubeDownloadCandidate = EgressAllowlist(
        exactHosts: ["www.youtube.com", "youtubei.googleapis.com", "i.ytimg.com", "www.google.com"],
        subdomainSuffixes: [".googlevideo.com"])

    func permits(_ host: String) -> Bool {
        exactHosts.contains(host) || subdomainSuffixes.contains { suffix in
            host.hasSuffix(suffix) && host.count > suffix.count
        }
    }
}

struct EgressConnectRequest: Equatable, Sendable {
    let host: String
    let port: UInt16
    let proxyAuthorization: String?

    static let maximumHeaderBytes = 4_096

    // Accepts exactly `CONNECT host:port HTTP/1.1` followed by headers and a
    // blank line. Everything else (absolute-form GET, bodies, folded headers,
    // NUL bytes, oversized input) is rejected before any policy check.
    static func parse(_ data: Data) -> Result<EgressConnectRequest, EgressDenial> {
        guard data.count <= maximumHeaderBytes else { return .failure(.requestTooLarge) }
        // "\r\n" is one Swift Character, so slice by range rather than count.
        guard !data.contains(0), let text = String(data: data, encoding: .utf8),
              text.hasSuffix("\r\n\r\n"),
              let terminator = text.range(of: "\r\n\r\n", options: .backwards) else {
            return .failure(.malformedRequest)
        }
        let lines = text[..<terminator.lowerBound].components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0" else {
            return .failure(.malformedRequest)
        }
        guard request[0] == "CONNECT" else { return .failure(.notConnect) }
        guard let (host, port) = splitAuthority(String(request[1])) else { return .failure(.malformedRequest) }
        var authorization: String?
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                return .failure(.malformedRequest)
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "proxy-authorization" {
                guard authorization == nil else { return .failure(.malformedRequest) }
                authorization = value
            }
        }
        return .success(EgressConnectRequest(host: host, port: port, proxyAuthorization: authorization))
    }

    private static func splitAuthority(_ value: String) -> (String, UInt16)? {
        if value.hasPrefix("[") {
            // Bracketed IPv6 literal; returned as-is so policy denies it as a literal.
            guard let close = value.firstIndex(of: "]"),
                  value[value.index(after: close)...].hasPrefix(":"),
                  let port = UInt16(value[value.index(close, offsetBy: 2)...]), port > 0 else { return nil }
            return (String(value[value.index(after: value.startIndex)..<close]), port)
        }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let port = UInt16(parts[1]), port > 0,
              parts[1].allSatisfy(\.isASCII) else { return nil }
        return (String(parts[0]), port)
    }
}

enum EgressHost {
    // Lowercased, trailing-dot-free DNS name, or nil if not a plain hostname.
    static func normalized(_ host: String) -> String? {
        var value = host.lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        return PolicyValidation.validDomain(value) ? value : nil
    }

    // True for anything an OS resolver could treat as an address rather than
    // a name: dotted, decimal, octal or hex IPv4 forms (inet_aton grammar),
    // IPv6 (with or without zone), and all-numeric labels.
    static func isAddressLiteral(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_aton(host, &v4) != 0 || inet_pton(AF_INET6, host, &v6) == 1 { return true }
        if host.contains(":") { return true }
        let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
        if let last = trimmed.split(separator: ".").last,
           last.allSatisfy({ $0.isNumber }) || last.lowercased().hasPrefix("0x") { return true }
        return false
    }
}

enum TLSServerName: Equatable, Sendable {
    case needMoreData
    case notTLS
    case noServerName
    case name(String)

    static let maximumClientHelloBytes = 16_384

    // Reads the SNI host_name from the first TLS record of a ClientHello.
    // Only a single handshake record is accepted; fragmented hellos are
    // treated as not-TLS rather than reassembled.
    static func parse(_ bytes: [UInt8]) -> TLSServerName {
        guard let first = bytes.first else { return .needMoreData }
        guard first == 0x16 else { return .notTLS }
        guard bytes.count >= 5 else { return .needMoreData }
        guard bytes[1] == 0x03 else { return .notTLS }
        let recordLength = Int(bytes[3]) << 8 | Int(bytes[4])
        guard recordLength >= 4, recordLength <= maximumClientHelloBytes else { return .notTLS }
        guard bytes.count >= 5 + recordLength else { return .needMoreData }
        var reader = Reader(bytes: Array(bytes[5..<(5 + recordLength)]))
        guard reader.u8() == 0x01, let length = reader.u24(), length <= reader.remaining,
              reader.skip(2 + 32),                          // legacy_version, random
              let session = reader.u8(), reader.skip(Int(session)),
              let suites = reader.u16(), suites % 2 == 0, reader.skip(Int(suites)),
              let methods = reader.u8(), reader.skip(Int(methods)) else { return .notTLS }
        guard reader.remaining > 0 else { return .noServerName }
        guard let extensionsLength = reader.u16(), Int(extensionsLength) <= reader.remaining else { return .notTLS }
        var extensions = Reader(bytes: reader.take(Int(extensionsLength)) ?? [])
        var found: String?
        while extensions.remaining > 0 {
            guard let type = extensions.u16(), let size = extensions.u16(),
                  let body = extensions.take(Int(size)) else { return .notTLS }
            guard type == 0 else { continue }
            guard found == nil else { return .notTLS }  // duplicate SNI extension
            var list = Reader(bytes: body)
            guard let listLength = list.u16(), Int(listLength) == list.remaining,
                  list.u8() == 0, let nameLength = list.u16(),
                  let name = list.take(Int(nameLength)), list.remaining == 0,
                  let text = String(bytes: name, encoding: .ascii) else { return .notTLS }
            found = text
        }
        return found.map(TLSServerName.name) ?? .noServerName
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        var remaining: Int { bytes.count - offset }
        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, count <= remaining else { return nil }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }
        mutating func skip(_ count: Int) -> Bool { take(count) != nil }
        mutating func u8() -> UInt8? { take(1)?[0] }
        mutating func u16() -> UInt16? { take(2).map { UInt16($0[0]) << 8 | UInt16($0[1]) } }
        mutating func u24() -> Int? { take(3).map { Int($0[0]) << 16 | Int($0[1]) << 8 | Int($0[2]) } }
    }
}

struct EgressPolicy: Sendable {
    let allowlist: EgressAllowlist
    let allowedPorts: Set<UInt16>
    // Expected `Proxy-Authorization` value, e.g. "Basic <base64(job:secret)>".
    let credential: String
    let expiresAt: Date
    let requireTLS: Bool

    func evaluate(_ header: Data, now: Date) -> EgressDecision {
        guard now < expiresAt else { return .deny(.expired) }
        let request: EgressConnectRequest
        switch EgressConnectRequest.parse(header) {
        case .failure(let denial): return .deny(denial)
        case .success(let value): request = value
        }
        guard let supplied = request.proxyAuthorization else { return .deny(.missingCredential) }
        guard Self.constantTimeEqual(supplied, credential) else { return .deny(.wrongCredential) }
        if EgressHost.isAddressLiteral(request.host) { return .deny(.ipLiteral) }
        guard let host = EgressHost.normalized(request.host) else { return .deny(.invalidHost) }
        guard allowlist.permits(host) else { return .deny(.hostNotAllowed) }
        guard allowedPorts.contains(request.port) else { return .deny(.portNotAllowed) }
        return .allow(host: host, port: request.port)
    }

    // Applied to the first bytes the client sends inside an allowed tunnel.
    func evaluateFirstBytes(_ bytes: [UInt8], connectHost: String) -> EgressDecision? {
        guard requireTLS else { return nil }
        switch TLSServerName.parse(bytes) {
        case .needMoreData: return nil
        case .notTLS: return .deny(.notTLS)
        case .noServerName: return .deny(.missingServerName)
        case .name(let name):
            return EgressHost.normalized(name) == connectHost ? .allow(host: connectHost, port: 0)
                : .deny(.serverNameMismatch)
        }
    }

    static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        var difference = UInt8(a.count == b.count ? 0 : 1)
        for index in 0..<max(a.count, b.count) {
            difference |= (index < a.count ? a[index] : 0) ^ (index < b.count ? b[index] : 0)
        }
        return difference == 0
    }
}

// DNS-over-HTTPS JSON answers for the broker. Only public unicast IPv4 is
// accepted, so a hostile or poisoned answer cannot aim a tunnel at loopback or LAN.
enum EgressResolverAnswer {
    static func firstPublicAddress(in data: Data) -> (address: String, ttl: TimeInterval)? {
        guard data.count <= 65_536,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["Status"] as? Int == 0,
              let answers = object["Answer"] as? [[String: Any]] else { return nil }
        for answer in answers where answer["type"] as? Int == 1 {
            guard let text = answer["data"] as? String, isPublicIPv4(text) else { continue }
            return (text, TimeInterval(answer["TTL"] as? Int ?? 60))
        }
        return nil
    }

    static func isPublicIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets: [Int] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let value = Int(part), value <= 255, part == "\(value)" else { return false }
            octets.append(value)
        }
        let (a, b) = (octets[0], octets[1])
        return !(a == 0 || a == 10 || a == 127 || a >= 224 ||
                 (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254) ||
                 (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) ||
                 (a == 192 && b == 0) || (a == 198 && (18...19).contains(b)))
    }
}
