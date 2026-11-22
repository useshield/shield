import Darwin
import Foundation

// Tamper evidence: the authority records when it was not running while the Mac
// was awake (for example, stopped with launchctl, or frozen with SIGSTOP). It
// cannot prevent an administrator from stopping the service; it makes that
// visible afterwards. Evidence never gates or weakens enforcement.
struct ServiceGap: Codable, Sendable, Equatable, Identifiable {
    let silentFrom: Date
    let resumedAt: Date
    // Awake time inside the gap, from the system's sleep-excluding clock.
    let awakeSeconds: TimeInterval
    let macSlept: Bool
    var id: Date { resumedAt }
}

// Wall time is for display only. Classification uses the kernel's monotonic
// clocks, so changing the system clock neither hides nor invents a gap.
struct AuthorityHeartbeat: Codable, Sendable, Equatable {
    let wallClock: Date
    let bootTime: Date
    let awakeNanoseconds: UInt64
    let elapsedNanoseconds: UInt64

    static func now() -> AuthorityHeartbeat? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0,
              size == MemoryLayout<timeval>.size, boot.tv_sec > 0 else { return nil }
        return AuthorityHeartbeat(wallClock: Date(),
            bootTime: Date(timeIntervalSince1970: TimeInterval(boot.tv_sec)),
            awakeNanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
            elapsedNanoseconds: clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW))
    }
}

enum ServiceGapClassifier {
    // The maintenance timer fires every 2 s and the heartbeat is persisted
    // every 30 s; anything under this much awake time is scheduling noise.
    static let tolerance: TimeInterval = 90
    static let persistInterval: TimeInterval = 30
    static let retainedGaps = 200

    static func gap(from previous: AuthorityHeartbeat, to current: AuthorityHeartbeat) -> ServiceGap? {
        // A restart resets the monotonic clocks. Whether the Mac was awake
        // before it went down is not knowable here, so restarts are not classified.
        guard abs(previous.bootTime.timeIntervalSince(current.bootTime)) < 2,
              current.awakeNanoseconds >= previous.awakeNanoseconds,
              current.elapsedNanoseconds >= previous.elapsedNanoseconds else { return nil }
        let awake = TimeInterval(current.awakeNanoseconds - previous.awakeNanoseconds) / 1_000_000_000
        let elapsed = TimeInterval(current.elapsedNanoseconds - previous.elapsedNanoseconds) / 1_000_000_000
        guard awake > tolerance else { return nil }
        return ServiceGap(silentFrom: current.wallClock.addingTimeInterval(-elapsed),
                          resumedAt: current.wallClock, awakeSeconds: awake,
                          macSlept: elapsed - awake > 60)
    }
}

// Owned by the long-running service and called under its operation lock.
final class ServiceGapMonitor: @unchecked Sendable {
    private let backend: FixtureBackend
    private var last: AuthorityHeartbeat?
    private var lastPersisted: AuthorityHeartbeat?

    init(backend: FixtureBackend) { self.backend = backend }

    // At service start: compare against the heartbeat the previous run persisted.
    func start() {
        guard let now = AuthorityHeartbeat.now() else { return }
        if let previous = backend.loadHeartbeat(),
           let gap = ServiceGapClassifier.gap(from: previous, to: now) {
            record(gap)
        }
        last = now
        persist(now)
    }

    // Each maintenance tick: a frozen (SIGSTOP) service resumes with a gap.
    func beat() {
        guard let now = AuthorityHeartbeat.now() else { return }
        if let last, let gap = ServiceGapClassifier.gap(from: last, to: now) { record(gap) }
        last = now
        let since = lastPersisted.map { TimeInterval(now.elapsedNanoseconds &- $0.elapsedNanoseconds) / 1_000_000_000 }
        if since.map({ $0 >= ServiceGapClassifier.persistInterval }) ?? true { persist(now) }
    }

    private func persist(_ beat: AuthorityHeartbeat) {
        do { try backend.recordHeartbeat(beat); lastPersisted = beat }
        catch { fputs("fixture-xpc: heartbeat not recorded: \(error.localizedDescription)\n", stderr) }
    }

    private func record(_ gap: ServiceGap) {
        do { try backend.appendServiceGap(gap) }
        catch { fputs("fixture-xpc: service gap not recorded: \(error.localizedDescription)\n", stderr) }
    }
}

enum ServiceGapPresentation {
    static func summary(_ gap: ServiceGap, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                    timeZone: calendar.timeZone)
        let day = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar,
                                   timeZone: calendar.timeZone)
        let sameDay = calendar.isDate(gap.silentFrom, inSameDayAs: gap.resumedAt)
        let range = sameDay
            ? "\(gap.silentFrom.formatted(day)), \(gap.silentFrom.formatted(time))–\(gap.resumedAt.formatted(time))"
            : "\(gap.silentFrom.formatted(day)) \(gap.silentFrom.formatted(time)) – \(gap.resumedAt.formatted(day)) \(gap.resumedAt.formatted(time))"
        let awake = duration(gap.awakeSeconds)
        return gap.macSlept
            ? "\(range): not running for \(awake) while this Mac was awake (it also slept)."
            : "\(range): not running for \(awake) while this Mac was awake."
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        guard minutes >= 60 else { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
