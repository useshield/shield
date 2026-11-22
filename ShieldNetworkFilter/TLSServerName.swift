import Foundation

// Browser layer 3 (DESIGN + CORE ONLY): the decision core for a future
// network content filter (NEFilterDataProvider in a system extension).
// Not built into any target: the Network Extension entitlement needs the paid
// Apple Developer Program, and this Mac signs with a free Personal Team.
//
// Why it matters: a resolver override changes which ADDRESS the browser
// connects to, but the browser still names the real site in the TLS
// ClientHello (server_name). A socket filter that peeks the first outbound
// bytes sees "www.youtube.com" there even when DNS and /etc/hosts were skipped.
// Limits (honest): Encrypted Client Hello hides the real name behind the
// provider's public name; a proxy or VPN that wraps traffic inside its own TLS
// shows only the proxy's name; QUIC carries the name in an encrypted Initial
// packet (decryptable, but not parsed here: the filter drops browser UDP/443
// so the browser falls back to TCP).

enum TLSServerName {
    struct ClientHello: Equatable {
        /// server_name host, lowercased; nil when the hello names no host.
        let serverName: String?
        /// The hello carries the Encrypted Client Hello extension (0xfe0d).
        /// Chrome sends it on EVERY connection as GREASE (verified Nov 12 on a
        /// real Chrome hello), with the real name in server_name, so its
        /// presence alone means nothing; see `NetworkFlowDecision`.
        let offersEncryptedClientHello: Bool
    }

    enum Result: Equatable {
        case hello(ClientHello)
        /// Not enough bytes yet: ask the flow for more.
        case needMoreData
        /// Not a TLS ClientHello at all.
        case notTLS
    }

    /// Parses the first TLS record of a connection.
    static func parse(_ bytes: [UInt8]) -> Result {
        guard bytes.count >= 5 else { return bytes.first.map { $0 == 0x16 ? .needMoreData : .notTLS } ?? .needMoreData }
        guard bytes[0] == 0x16, bytes[1] == 0x03 else { return .notTLS }       // handshake record, TLS 1.x
        let recordLength = Int(bytes[3]) << 8 | Int(bytes[4])
        guard recordLength >= 4 else { return .notTLS }
        guard bytes.count >= 5 + recordLength else { return .needMoreData }
        var reader = Reader(Array(bytes[5..<(5 + recordLength)]))
        guard reader.u8() == 0x01 else { return .notTLS }                        // ClientHello
        guard let helloLength = reader.u24(), helloLength <= reader.remaining else {
            return .needMoreData   // hello spans several records; rare for real browsers
        }
        guard reader.skip(2 + 32),                                              // version, random
              let session = reader.u8(), reader.skip(Int(session)),
              let suites = reader.u16(), reader.skip(Int(suites)),
              let compression = reader.u8(), reader.skip(Int(compression)) else { return .notTLS }
        guard reader.remaining >= 2, let extensionsLength = reader.u16(), Int(extensionsLength) <= reader.remaining else {
            return .hello(ClientHello(serverName: nil, offersEncryptedClientHello: false))
        }
        var name: String?
        var ech = false
        var extensions = Reader(reader.take(Int(extensionsLength)) ?? [])
        while extensions.remaining >= 4 {
            guard let type = extensions.u16(), let length = extensions.u16(),
                  let body = extensions.take(Int(length)) else { return .notTLS }
            switch type {
            case 0x0000: name = serverName(in: body)
            case 0xfe0d: ech = true
            default: break
            }
        }
        return .hello(ClientHello(serverName: name, offersEncryptedClientHello: ech))
    }

    private static func serverName(in body: [UInt8]) -> String? {
        var reader = Reader(body)
        guard let listLength = reader.u16(), Int(listLength) <= reader.remaining else { return nil }
        var list = Reader(reader.take(Int(listLength)) ?? [])
        while list.remaining >= 3 {
            guard let kind = list.u8(), let length = list.u16(), let value = list.take(Int(length)) else { return nil }
            if kind == 0, let host = String(bytes: value, encoding: .ascii), !host.isEmpty, host.count <= 253 {
                var lower = host.lowercased()
                while lower.hasSuffix(".") { lower.removeLast() }
                return lower
            }
        }
        return nil
    }

    private struct Reader {
        private let bytes: [UInt8]
        private var index = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        var remaining: Int { bytes.count - index }
        mutating func u8() -> UInt8? { guard remaining >= 1 else { return nil }; defer { index += 1 }; return bytes[index] }
        mutating func u16() -> UInt16? {
            guard remaining >= 2 else { return nil }
            defer { index += 2 }
            return UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
        }
        mutating func u24() -> Int? {
            guard remaining >= 3 else { return nil }
            defer { index += 3 }
            return Int(bytes[index]) << 16 | Int(bytes[index + 1]) << 8 | Int(bytes[index + 2])
        }
        mutating func skip(_ count: Int) -> Bool { guard count >= 0, remaining >= count else { return false }; index += count; return true }
        mutating func take(_ count: Int) -> [UInt8]? {
            guard count >= 0, remaining >= count else { return nil }
            defer { index += count }
            return Array(bytes[index..<(index + count)])
        }
    }
}

/// What the filter does with one browser flow, from the same effective
/// blocked set as every other layer.
enum NetworkFlowDecision: Equatable {
    case allow
    case drop(reason: String)
    /// Peek more outbound bytes before deciding.
    case needMoreData

    /// `blockedHosts` block themselves and every subdomain (the browser-policy
    /// meaning). Only browsers are filtered; Shield's Downloads broker, system
    /// services and VPN clients such as Tailscale are allowed by identity
    /// before this is ever asked.
    /// Outer names that real (not GREASE) Encrypted Client Hello uses: the
    /// hello names the provider, and the real site is hidden inside.
    static let encryptedHelloPublicNames: Set<String> = ["cloudflare-ech.com"]

    static func decide(firstOutboundBytes bytes: [UInt8], remotePort: Int, isUDP: Bool,
                       blockedHosts: Set<String>, refuseHiddenNames: Bool = true) -> NetworkFlowDecision {
        guard !blockedHosts.isEmpty else { return .allow }
        // QUIC hides the name in an encrypted Initial; refusing it makes the browser use TCP.
        if isUDP { return remotePort == 443 ? .drop(reason: "QUIC is refused so the site name can be read") : .allow }
        switch TLSServerName.parse(bytes) {
        case .needMoreData: return .needMoreData
        case .notTLS: return .allow   // plain HTTP and other protocols: out of scope for this layer
        case .hello(let hello):
            if let name = hello.serverName, isBlocked(name, blockedHosts) {
                return .drop(reason: "names a blocked site")
            }
            // Real ECH: the outer name is the provider's public name (or none).
            // GREASE ECH names the real site and was decided above.
            let hidden = hello.offersEncryptedClientHello &&
                (hello.serverName.map { encryptedHelloPublicNames.contains($0) } ?? true)
            if hidden && refuseHiddenNames {
                return .drop(reason: "hides the site name (Encrypted Client Hello)")
            }
            return .allow
        }
    }

    static func isBlocked(_ host: String, _ blocked: Set<String>) -> Bool {
        var candidate = Substring(host)
        while true {
            if blocked.contains(String(candidate)) { return true }
            guard let dot = candidate.firstIndex(of: ".") else { return false }
            candidate = candidate[candidate.index(after: dot)...]
        }
    }
}
