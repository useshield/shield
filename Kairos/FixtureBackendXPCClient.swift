import Foundation

// Every operation uses a fresh connection. A dead service cannot leave a
// previously exported proxy or cached snapshot looking like live authority.
final class FixtureBackendXPCClient: @unchecked Sendable {
    let serviceName: String
    let privileged: Bool
    private let timeout: TimeInterval
    private let serviceRequirement: String?

    init(serviceName: String = ShieldRuntime.serviceName, privileged: Bool = false,
         timeout: TimeInterval = 10,
         serviceRequirement: String? = ShieldRuntime.serviceSigningRequirement) {
        self.serviceName = serviceName
        self.privileged = privileged
        self.timeout = timeout
        self.serviceRequirement = serviceRequirement
    }

    /// A full snapshot carries every list about twice (as committed, and as
    /// in effect), plus the observed blocked set.
    static let maximumReplyBytes = 3 * StateFileLimits.maximumBytes

    func submit(_ request: BackendRequest) throws -> BackendAcknowledgment {
        let bytes = try JSONEncoder().encode(request)
        guard bytes.count <= StateFileLimits.maximumBytes else {
            throw FixtureBackendError.invalidRequest("XPC request is too large.")
        }
        let result = try call { $0.submit(bytes as NSData, reply: $1) }
        let acknowledgment = try JSONDecoder().decode(BackendAcknowledgment.self, from: result)
        guard acknowledgment.version == 1,
              acknowledgment.receipt.payload.version == 1,
              acknowledgment.receipt.payload.requestID == request.id,
              acknowledgment.receipt.payload.generation > request.expectedGeneration,
              [.applied, .alreadyApplied].contains(acknowledgment.status) else {
            throw FixtureBackendError.invalidReceipt
        }
        return acknowledgment
    }

    /// The lists last received, with the digest of their observed blocked
    /// set. A poll sends only what identifies them; while they are unchanged
    /// the service answers with fresh evidence alone (big block lists then
    /// cost nothing per poll). Every poll is still a live call: a dead or
    /// silent service fails it exactly as before.
    private let heldLock = NSLock()
    private var held: (snapshot: BackendSnapshot, digest: String)?
    /// An older service has no `snapshotUpdate`; ask it the long way for a while.
    private var updatesUnsupportedUntil = Date.distantPast

    func snapshot() throws -> BackendSnapshot {
        heldLock.lock()
        let current = Date() >= updatesUnsupportedUntil ? held : nil
        heldLock.unlock()
        guard let current else { return try fullSnapshot() }
        let known = try JSONEncoder().encode(SnapshotKnown(generation: current.snapshot.generation,
                                                           blockedDigest: current.digest))
        let result: Data
        do {
            result = try call { $0.snapshotUpdate(known as NSData, reply: $1) }
        } catch {
            let value = try fullSnapshot()
            heldLock.lock(); updatesUnsupportedUntil = Date().addingTimeInterval(600); heldLock.unlock()
            return value
        }
        let answer = try JSONDecoder().decode(FixtureSnapshotReply.self, from: result)
        if let full = answer.full { return try accept(full) }
        guard let update = answer.update, update.generation == current.snapshot.generation,
              update.blockedDigest == current.digest, update.receipt.payload.generation == update.generation else {
            throw FixtureBackendError.invalidReceipt
        }
        let held = current.snapshot
        let enforcement = EnforcementSnapshot(observedAt: update.observedAt,
                                              blockedDomains: held.enforcement.blockedDomains,
                                              managedSectionPresent: update.managedSectionPresent,
                                              resolution: update.resolution, blockedApps: update.blockedApps)
        let value = BackendSnapshot(generation: held.generation,
                                    committedRestrictions: held.committedRestrictions,
                                    committedSchedules: held.committedSchedules,
                                    pendingReleases: held.pendingReleases,
                                    authority: held.authority,
                                    enforcement: enforcement,
                                    enforcementSource: held.enforcementSource,
                                    receipt: update.receipt,
                                    nextTransition: update.nextTransition,
                                    timeZoneIdentifier: held.timeZoneIdentifier,
                                    serviceGaps: update.serviceGaps ?? [], conditions: held.conditions,
                                    supportsPlaces: held.supportsPlaces, supportsGoDays: held.supportsGoDays,
                                    supportsBrowserPolicy: held.supportsBrowserPolicy,
                                    verifiedAt: update.verifiedAt, permanentRemoval: held.permanentRemoval,
                                    scheduleZone: held.scheduleZone)
        try Self.checkLive(value)
        return value
    }

    private func fullSnapshot() throws -> BackendSnapshot {
        let result = try call { $0.snapshot(reply: $1) }
        return try accept(JSONDecoder().decode(FixtureSnapshotEnvelope.self, from: result))
    }

    /// The same evidence checks for a full reply and an update.
    private static func checkLive(_ value: BackendSnapshot) throws {
        guard value.generation > 0, value.generation == value.receipt.payload.generation,
              value.receipt.payload.version == 1,
              abs(Date().timeIntervalSince(value.enforcement.observedAt)) <= 30,
              value.verifiedAt.map({ abs(Date().timeIntervalSince($0)) <= 30 }) ?? true else {
            throw FixtureBackendError.invalidReceipt
        }
        if let resolution = value.enforcement.resolution {
            guard resolution.generation == value.generation,
                  abs(Date().timeIntervalSince(resolution.observedAt)) <= 30 else {
                throw FixtureBackendError.invalidReceipt
            }
        }
    }

    private func accept(_ value: FixtureSnapshotEnvelope) throws -> BackendSnapshot {
        guard value.generation > 0,
              value.generation == value.authority.generation,
              value.generation == value.receipt.payload.generation,
              value.receipt.payload.version == 1,
              AuthorityState.supportedSchemaVersions.contains(value.authority.schemaVersion),
              abs(Date().timeIntervalSince(value.enforcement.observedAt)) <= 30 else {
            throw FixtureBackendError.invalidReceipt
        }
        if let resolution = value.enforcement.resolution {
            guard resolution.generation == value.generation,
                  abs(Date().timeIntervalSince(resolution.observedAt)) <= 30 else {
                throw FixtureBackendError.invalidReceipt
            }
        }
        let result = BackendSnapshot(generation: value.generation,
                               committedRestrictions: value.restrictions,
                               committedSchedules: value.schedules,
                               pendingReleases: value.pendingReleases,
                               authority: value.authority,
                               enforcement: value.enforcement,
                               enforcementSource: value.enforcementSource,
                               receipt: value.receipt,
                               nextTransition: value.nextTransition, timeZoneIdentifier: value.timeZoneIdentifier,
                               serviceGaps: value.serviceGaps ?? [], conditions: value.conditions,
                               supportsPlaces: value.features?.contains(BackendSnapshot.placesFeature) == true,
                               supportsGoDays: value.features?.contains(BackendSnapshot.goDaysFeature) == true,
                               supportsBrowserPolicy: value.features?.contains(BackendSnapshot.browserPolicyFeature) == true)
        var snapshot = result
        snapshot.verifiedAt = value.verifiedAt
        // Only a service that says it handles removable permanents gets them.
        if value.features?.contains(BackendSnapshot.permanentRemovalFeature) == true,
           let removal = value.permanentRemoval, removal.isWellFormed {
            snapshot.permanentRemoval = removal
        }
        if let zone = value.scheduleZone, zone.isWellFormed { snapshot.scheduleZone = zone }
        try Self.checkLive(snapshot)
        heldLock.lock()
        held = value.blockedDigest.map { (snapshot, $0) }
        heldLock.unlock()
        return snapshot
    }

    func reportPresence(_ report: PresenceReport) throws -> BackendAcknowledgment {
        let bytes = try JSONEncoder().encode(report)
        guard bytes.count <= 65_536 else {
            throw FixtureBackendError.invalidRequest("Presence report exceeds 64 KiB.")
        }
        let result = try call { $0.reportPresence(bytes as NSData, reply: $1) }
        let acknowledgment = try JSONDecoder().decode(BackendAcknowledgment.self, from: result)
        guard acknowledgment.version == 1,
              acknowledgment.receipt.payload.version == 1,
              [.applied, .unchanged].contains(acknowledgment.status) else {
            throw FixtureBackendError.invalidReceipt
        }
        return acknowledgment
    }

    func tick() throws -> BackendAcknowledgment {
        let result = try call { $0.tick(reply: $1) }
        let acknowledgment = try JSONDecoder().decode(BackendAcknowledgment.self, from: result)
        guard acknowledgment.version == 1,
              acknowledgment.receipt.payload.version == 1 else {
            throw FixtureBackendError.invalidReceipt
        }
        return acknowledgment
    }

    func recover() throws -> BackendAcknowledgment {
        let result = try call { $0.recover(reply: $1) }
        let acknowledgment = try JSONDecoder().decode(BackendAcknowledgment.self, from: result)
        guard acknowledgment.version == 1,
              acknowledgment.receipt.payload.version == 1 else {
            throw FixtureBackendError.invalidReceipt
        }
        return acknowledgment
    }

    private func call(_ send: (FixtureBackendXPCWire,
                             @escaping (NSData?, NSString?) -> Void) -> Void) throws -> Data {
        guard let serviceRequirement else {
            throw FixtureBackendError.uncertain("Service identity is not configured. Use the signed disposable service test procedure.")
        }
        try validateXPCSigningRequirement(serviceRequirement)
        let connection = privileged
            ? NSXPCConnection(machServiceName: serviceName, options: .privileged)
            : NSXPCConnection(machServiceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: FixtureBackendXPCWire.self)
        connection.setCodeSigningRequirement(serviceRequirement)
        connection.resume()
        defer { connection.invalidate() }

        let reply = Reply()
        guard let remote = connection.remoteObjectProxyWithErrorHandler({ error in
            reply.finish(nil, error.localizedDescription)
        }) as? FixtureBackendXPCWire else {
            throw FixtureBackendError.uncertain("The service did not provide an XPC proxy.")
        }
        send(remote) { bytes, message in
            reply.finish(bytes as Data?, message as String?)
        }
        guard reply.wait(timeout: timeout) else {
            throw FixtureBackendError.uncertain("The service disconnected or timed out.")
        }
        if let error = reply.error {
            throw FixtureBackendError.uncertain(error)
        }
        guard let bytes = reply.data, !bytes.isEmpty, bytes.count <= Self.maximumReplyBytes else {
            throw FixtureBackendError.uncertain("The service returned an empty or oversized reply.")
        }
        return bytes
    }

    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var completed = false
        private var payload: Data?
        private var detail: String?

        var data: Data? { lock.lock(); defer { lock.unlock() }; return payload }
        var error: String? { lock.lock(); defer { lock.unlock() }; return detail }

        func finish(_ data: Data?, _ error: String?) {
            lock.lock()
            guard !completed else { lock.unlock(); return }
            completed = true
            payload = data
            detail = error
            lock.unlock()
            semaphore.signal()
        }

        func wait(timeout: TimeInterval) -> Bool {
            semaphore.wait(timeout: .now() + timeout) == .success
        }
    }
}
