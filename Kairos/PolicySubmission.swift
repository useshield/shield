import Foundation
import Darwin

enum PolicySubmissionState: Equatable {
    case idle
    case submitting(UUID)
    case confirmed(UUID)
    case unconfirmed(UUID)
    case failed(UUID)
}

// This is a local record of intent, never authority. Keep the exact UUID and
// payload when a reply is lost; retrying must not create another commitment.
struct PendingPolicySubmission: Codable {
    let version: Int
    let request: BackendRequest
    /// No longer written or read: the old schedule-draft preferences. Kept
    /// optional so a pending record saved by an earlier release still loads.
    let schedulePreferences: PolicyRequest?
    /// What a "Keep Current Rules" cancel keeps, as it was when sent. A pending
    /// replacement that comes due also leaves nothing pending, so the cancel is
    /// recognized only if these are still exactly in place.
    var keptSchedules: [DailySchedule]? = nil
    var keptPlaces: [RulePlace]? = nil

    init(version: Int, request: BackendRequest, schedulePreferences: PolicyRequest? = nil,
         before snapshot: BackendSnapshot? = nil) {
        self.version = version
        self.request = request
        self.schedulePreferences = schedulePreferences
        let cancelled = Set(request.commands.filter { $0.kind == .cancelPendingRelease }.compactMap(\.policyID))
        guard let snapshot, !cancelled.isEmpty else { return }
        keptSchedules = snapshot.committedSchedules.filter { cancelled.contains($0.id) }
        keptPlaces = snapshot.conditions?.places.filter { cancelled.contains(ConditionalPolicy.pendingID(place: $0.id)) }
    }

    func isConfirmed(by snapshot: BackendSnapshot) -> Bool {
        guard version == 1, snapshot.generation > request.expectedGeneration else { return false }
        if snapshot.receipt.payload.requestID == request.id { return true }
        // Maintenance or another approved client may have advanced the receipt.
        // Recognize only exact effects in authenticated state, never elapsed time
        // or a local preference. Missing/expired effects remain uncertain.
        return !request.commands.isEmpty && request.commands.allSatisfy { command in
            switch command.kind {
            case .addRestriction:
                return command.restriction.map { snapshot.committedRestrictions.contains($0) } ?? false
            case .addSchedule, .strengthenSchedule:
                return command.schedule.map { snapshot.committedSchedules.contains($0) } ?? false
            case .replaceScheduleAfterDelay:
                guard let schedule = command.schedule, let due = command.effectiveAt else { return false }
                return snapshot.pendingReleases.contains(.init(policyID: schedule.id, effectiveAt: due,
                                                               replacementSchedule: schedule))
            case .requestRelease:
                guard let id = command.policyID, let due = command.effectiveAt else { return false }
                return snapshot.pendingReleases.contains(.init(policyID: id, effectiveAt: due))
            case .cancelPendingRelease:
                guard let id = command.policyID else { return false }
                // Nothing pending and the rule still there. A release that came due
                // removes the rule, but a replacement that came due (new hours, a
                // moved place, a changed rule) also leaves nothing pending, so a
                // cancel of one of those is confirmed only by the receipt above.
                guard !snapshot.pendingReleases.contains(where: { $0.policyID == id }) else { return false }
                if let kept = keptSchedules?.first(where: { $0.id == id }) {
                    return snapshot.committedSchedules.contains(kept)
                }
                if let kept = keptPlaces?.first(where: { ConditionalPolicy.pendingID(place: $0.id) == id }) {
                    return snapshot.conditions?.places.contains(kept) == true
                }
                return (snapshot.committedRestrictions.contains { $0.policyID == id } ||
                     snapshot.committedSchedules.contains { $0.id == id } ||
                     snapshot.conditions?.places.contains { ConditionalPolicy.pendingID(place: $0.id) == id } == true ||
                     snapshot.conditions?.rules.contains { ConditionalPolicy.pendingID(rule: $0.id) == id } == true)
            case .withdrawGoDay:
                guard let id = command.policyID else { return false }
                return !snapshot.committedRestrictions.contains { $0.policyID == id }
            case .undoNewBlock:
                guard let id = command.policyID else { return false }
                return !snapshot.committedRestrictions.contains { $0.policyID == id }
            case .setPermanentRemovalWait:
                guard let seconds = command.waitSeconds, let removal = snapshot.permanentRemoval else { return false }
                return removal.wait == seconds || removal.pendingWait == seconds
            case .requestUninstall:
                guard let due = command.effectiveAt else { return false }
                return snapshot.permanentRemoval?.uninstallAt.map { $0 >= due } == true
            case .cancelUninstall:
                return snapshot.permanentRemoval.map { $0.uninstallAt == nil } == true
            case .correctRecentPermanent:
                guard let id = command.policyID, let due = command.effectiveAt else { return false }
                return snapshot.pendingReleases.contains { $0.policyID == id && $0.effectiveAt == due } &&
                    snapshot.committedRestrictions.contains { $0.policyID == id && $0.owner == .commitment }
            // A place or rule change with no date applied at once; with a date it
            // waits as a pending change. The service dates rules itself, so rules
            // match by content, never by their commit time.
            case .addPlace, .replacePlace:
                guard let place = command.place else { return false }
                guard let due = command.effectiveAt else { return snapshot.conditions?.places.contains(place) == true }
                return snapshot.pendingReleases.contains { $0.policyID == ConditionalPolicy.pendingID(place: place.id) &&
                    $0.effectiveAt == due && $0.replacementPlace == place }
            case .removePlace:
                guard let id = command.policyID, let due = command.effectiveAt else { return false }
                return snapshot.pendingReleases.contains { $0.policyID == ConditionalPolicy.pendingID(place: id) &&
                    $0.effectiveAt == due && $0.replacementPlace == nil }
            case .addConditionalRule, .replaceConditionalRule:
                guard let rule = command.conditionalRule else { return false }
                guard let due = command.effectiveAt else {
                    return snapshot.conditions?.rules.contains { $0.sameContent(as: rule) } == true
                }
                return snapshot.pendingReleases.contains { $0.policyID == ConditionalPolicy.pendingID(rule: rule.id) &&
                    $0.effectiveAt == due && $0.replacementRule?.sameContent(as: rule) == true }
            case .removeConditionalRule:
                guard let id = command.policyID else { return false }
                guard let due = command.effectiveAt else {
                    return snapshot.conditions?.rules.contains { $0.id == id } != true &&
                        !snapshot.pendingReleases.contains { $0.policyID == ConditionalPolicy.pendingID(rule: id) }
                }
                return snapshot.pendingReleases.contains { $0.policyID == ConditionalPolicy.pendingID(rule: id) &&
                    $0.effectiveAt == due && $0.replacementRule == nil }
            }
        }
    }
}

struct PolicySubmissionStore {
    let root: URL
    var file: URL { root.appendingPathComponent("pending-policy-request.json") }
    func load() throws -> PendingPolicySubmission? {
        // A dangling alias or inaccessible record is not an absent intent.
        // Preserve it and block new submissions, just like corrupt JSON.
        var metadata = stat()
        if lstat(file.path, &metadata) != 0 {
            guard errno == ENOENT else { throw CocoaError(.fileReadNoPermission) }
            return nil
        }
        let value = try JSONDecoder().decode(PendingPolicySubmission.self,
            from: AtomicFixtureStore(allowedRoot: root).read(file))
        guard value.version == 1, value.request.version == BackendRequest.schemaVersion,
              !value.request.commands.isEmpty else { throw FixtureBackendError.invalidReceipt }
        return value
    }
    func save(_ value: PendingPolicySubmission) throws {
        try ShieldRuntime.requireIsolatedWrite(to: file)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try AtomicFixtureStore(allowedRoot: root).write(JSONEncoder().encode(value), to: file)
    }
    func remove() throws { try AtomicFixtureStore(allowedRoot: root).remove(file) }
    func archiveUnreadable() throws {
        let bytes = try AtomicFixtureStore(allowedRoot: root).read(file)
        let archive = root.appendingPathComponent("unreadable-policy-request-\(UUID()).json")
        try AtomicFixtureStore(allowedRoot: root).write(bytes, to: archive)
        try remove()
    }
}
