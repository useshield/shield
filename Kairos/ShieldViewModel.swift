import AppKit
import Foundation
import Observation
import Darwin
import CryptoKit

/// New Block's lengths. Timed and forever locks are Lock In's (`LockInPlan`);
/// one hour remains for the development fixture's quick check.
enum NewBlockDuration {
    case oneHour
    case untilReleased

    var seconds: TimeInterval? {
        switch self {
        case .oneHour: 3_600
        case .untilReleased: nil
        }
    }
}

@MainActor
@Observable
final class ShieldViewModel {
    private(set) var health = BackendHealth(
        authority: .unavailable(.missing),
        enforcement: .unavailable("Enforcement has not been inspected."),
        reconcilerPresent: false,
        schedulerDefinitionPresent: false
    )
    private(set) var studyJobs: [StudyJob] = []
    private(set) var studyManifestTitle: String?
    private(set) var savedCourses: [StudyManifest] = []
    /// Saved-video counts of older per-course libraries, by selection key.
    private(set) var olderLibraryCounts: [String: Int] = [:]
    private(set) var collectionLayout = StudyCollectionLayout()
    private(set) var collectionNotice: String?
    private var collectionsUnreadable = false
    /// A menu command waiting for its page to open the right sheet.
    var command: ShieldCommand?
    /// The collection shown in Downloads; nil is All Videos.
    var selectedCollectionID: String?
    /// Collection sheet and delete confirmation, presented by the window so
    /// the sidebar and the Library page can both ask for them.
    var collectionEditor: CollectionEditorTarget?
    var collectionPendingDelete: StudyCollection?
    private var signInRevision = 0
    /// Checked at most every few seconds (rows ask often), and at once after
    /// Shield adds or removes the file.
    var signInFilePresent: Bool {
        let revision = signInRevision
        if let memo = signInPresentMemo, memo.revision == revision, memo.checkedAt.timeIntervalSinceNow > -5 {
            return memo.present
        }
        let present = FileManager.default.fileExists(atPath: StudyCookies.file.path)
        signInPresentMemo = (revision, .now, present)
        return present
    }
    @ObservationIgnored private var signInPresentMemo: (revision: Int, checkedAt: Date, present: Bool)?
    private(set) var signInMessage: String?

    /// Saves a cookies.txt export (YouTube and Google cookies only) as the
    /// download sign-in. Shield never sees a password.
    func importSignInFile(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= StudyCookies.maximumBytes,
                  let text = String(data: try Data(contentsOf: url), encoding: .utf8),
                  let filtered = StudyCookies.filtered(text) else {
                signInMessage = "That file isn't a YouTube cookies.txt export."
                return
            }
            try ShieldRuntime.requireIsolatedWrite(to: StudyCookies.file)
            try FileManager.default.createDirectory(at: StudyCookies.file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(filtered.utf8).write(to: StudyCookies.file, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: StudyCookies.file.path)
            signInMessage = "Sign-in saved."
        } catch { signInMessage = "The sign-in couldn't be saved." }
        signInRevision += 1
    }

    func removeSignInFile() {
        do {
            try ShieldRuntime.requireIsolatedWrite(to: StudyCookies.file)
            if FileManager.default.fileExists(atPath: StudyCookies.file.path) {
                try FileManager.default.removeItem(at: StudyCookies.file)
            }
            signInMessage = "Sign-in removed."
        } catch { signInMessage = "The sign-in couldn't be removed." }
        signInRevision += 1
    }
    private(set) var studyCourseApproved = false
    private(set) var isDownloading = false
    private(set) var isRestoringStudy = false
    private(set) var isImportingMedia = false
    private(set) var studyMessage: String? {
        didSet {
            guard let message = studyMessage, !isDownloading, !isRestoringStudy else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if self?.studyMessage == message { self?.studyMessage = nil }
            }
        }
    }
    func clearStudyMessage() { studyMessage = nil }
    private(set) var studyPersistenceError: String?
    private(set) var playbackPositions: [String: StudyPlaybackPosition] = [:]
    private(set) var pendingLibraryRecovery: StudyManifest?
    private(set) var toolVersions: [String: String] = [:]
    private(set) var lastRefresh: Date?
    private(set) var fixtureReceipt: BackendReceipt?
    private(set) var fixtureReceiptError: String?
    /// What the window shows. Between changes the 5 s polls only bring
    /// newer check times, so this is replaced when something on screen would
    /// change, or once a minute; `latestSnapshot` always has the newest poll.
    private(set) var backendSnapshot: BackendSnapshot? {
        didSet {
            latestSnapshot = backendSnapshot
            // The 5 s polls mostly bring fresh evidence only; keep the
            // groupings unless the lists they're built from changed.
            let old = oldValue, new = backendSnapshot
            if old?.committedRestrictions != new?.committedRestrictions ||
                old?.committedSchedules != new?.committedSchedules ||
                old?.pendingReleases != new?.pendingReleases ||
                old?.authority.effectiveRestrictions != new?.authority.effectiveRestrictions {
                rulePresentationMemo = .init()
            }
        }
    }
    /// Grouping and status inputs, worked out once per snapshot or layout
    /// change instead of on every redraw. Readers still observe the snapshot
    /// and layout themselves, so views update when either changes.
    @ObservationIgnored var rulePresentationMemo = RulePresentationMemo()
    /// The newest poll, for checks that need its times (health, downloads).
    @ObservationIgnored private(set) var latestSnapshot: BackendSnapshot?
    @ObservationIgnored private var snapshotShownAt: Date?

    /// Whether a poll changes anything the window shows, or the times it
    /// shows are a minute old.
    nonisolated static func pollNeedsRedraw(shown: BackendSnapshot?, incoming: BackendSnapshot,
                                shownAt: Date?, now: Date) -> Bool {
        guard let shown, let shownAt else { return true }
        let age = now.timeIntervalSince(shownAt)
        if age < 0 || age >= 60 { return true }
        let a = shown.enforcement, b = incoming.enforcement
        return shown.generation != incoming.generation
            || BookkeepingKey(shown) != BookkeepingKey(incoming)
            || shown.enforcementSource != incoming.enforcementSource
            || shown.nextTransition != incoming.nextTransition
            || shown.supportsPlaces != incoming.supportsPlaces
            || shown.supportsGoDays != incoming.supportsGoDays
            || shown.supportsBrowserPolicy != incoming.supportsBrowserPolicy
            || shown.receipt != incoming.receipt
            || a.blockedDomains != b.blockedDomains
            || a.managedSectionPresent != b.managedSectionPresent
            || a.blockedApps != b.blockedApps
            || a.resolution?.problem != b.resolution?.problem
            || a.resolution?.results.map(\.usesBlockingAddresses) != b.resolution?.results.map(\.usesBlockingAddresses)
    }
    /// Sites that opened while a browser was already running ("Reopen Chrome").
    private(set) var browserReopen: BrowserReopenAdvisor = {
        guard let data = UserDefaults.standard.data(forKey: ShieldViewModel.browserReopenKey),
              let saved = try? JSONDecoder().decode(BrowserReopenAdvisor.self, from: data) else { return .init() }
        return saved
    }()
    static let browserReopenKey = "Shield.BrowserReopen.v1"
    /// Owner setting: close tabs on sites that just became blocked (off by default).
    private(set) var closesBlockedTabs = UserDefaults.standard.bool(forKey: ShieldViewModel.closesBlockedTabsKey)
    static let closesBlockedTabsKey = "Shield.CloseBlockedTabs"
    /// Tabs Shield closed in the last day, newest first, so nothing is lost.
    private(set) var closedTabs: [BlockedTabCloser.ClosedTab] = {
        guard let data = UserDefaults.standard.data(forKey: ShieldViewModel.closedTabsKey),
              let saved = try? JSONDecoder().decode([BlockedTabCloser.ClosedTab].self, from: data) else { return [] }
        return saved.filter { $0.closedAt > Date.now.addingTimeInterval(-86_400) }
    }()
    static let closedTabsKey = "Shield.ClosedTabs.v1"
    /// Why the last tab check couldn't finish, if it couldn't.
    private(set) var tabClosingProblem: String?
    /// The problem is macOS's Automation permission, which only the user can grant.
    private(set) var tabClosingNeedsPermission = false

    /// Seconds a page note stays: 10 for outcomes, 60 when something failed.
    nonisolated static func actionMessageLifetime(_ message: String) -> Int {
        let lower = message.lowercased()
        let failed = ["didn't", "couldn't", "can't", "wasn't", "no reply", "not accepted", "failed", "could not", "refused"]
            .contains { lower.contains($0) }
        return failed ? 60 : 10
    }
    private(set) var backendActionMessage: String? {
        didSet {
            // Outcome notes fade; anything still pending keeps its own notice.
            // A failure stays long enough to be seen after looking away.
            guard let message = backendActionMessage else { return }
            let seconds = Self.actionMessageLifetime(message)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, self.backendActionMessage == message, !self.isSubmittingPolicy else { return }
                self.backendActionMessage = nil
            }
        }
    }
    private(set) var submissionState: PolicySubmissionState = .idle
    private(set) var pendingSubmission: PendingPolicySubmission?
    private(set) var submissionRecordError: String?
    private(set) var queue = StudyQueueDocument(items: []) { didSet { queueIndexMemo = nil } }
    /// The library's videos by ID, rebuilt only when the library changes, so
    /// long lists don't search it once per row.
    @ObservationIgnored private var queueIndexMemo: [String: StudyQueueItem]?
    private var queueIndex: [String: StudyQueueItem] {
        let items = queue.items // keeps views observing the library
        if let queueIndexMemo { return queueIndexMemo }
        let index = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        queueIndexMemo = index
        return index
    }
    /// The highest download attempt seen per video in this run.
    @ObservationIgnored private var downloadAttempts: [String: Int] = [:]
    private(set) var queueNotice: String? {
        didSet {
            // Notices are momentary: clear this one a few seconds later
            // unless a newer notice replaced it.
            queueNoticeIsProblem = nextNoticeIsProblem
            nextNoticeIsProblem = false
            guard let notice = queueNotice else { return }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if self?.queueNotice == notice { self?.queueNotice = nil }
            }
        }
    }
    /// Whether the current Library notice reports a problem (orange icon).
    private(set) var queueNoticeIsProblem = false
    @ObservationIgnored private var nextNoticeIsProblem = false
    #if DEBUG
    // Opt-in preview of app blocking: the development build closes the apps its
    // simulated policy blocks, for this user only. Off unless launched with
    // SHIELD_PREVIEW_APP_BLOCKING=1; never in UI Review or a release build.
    @ObservationIgnored private let previewAppEnforcer: AppEnforcer? =
        ProcessInfo.processInfo.environment["SHIELD_PREVIEW_APP_BLOCKING"] == "1" && !ShieldRuntime.isUIReview
            ? AppEnforcer(scanner: ProcessScanner(ownerUID: getuid())) : nil
    #endif
    private func queueProblem(_ text: String) { nextNoticeIsProblem = true; queueNotice = text }
    /// Videos in the download run under way, so waiting rows say so.
    private(set) var downloadBatchIDs: Set<String> = []
    /// Saved videos being downloaded again. They stay saved and playable
    /// throughout; only a new copy that checks out replaces the old one.
    private(set) var redownloadingIDs: Set<String> = []
    private(set) var queueReadError = false
    private var queueStore: StudyQueueStore { .init(root: studyLibraryRoot) }
    private var submissionStore: PolicySubmissionStore { .init(root: studyLibraryRoot) }
    var selectedSection: ShieldSection? = .protection
    private(set) var categoryLayout = ShieldCategoryLayout.default { didSet { rulePresentationMemo = .init() } }
    private(set) var categoryMessage: String?
    private var collectionStore: StudyCollectionStore {
        .init(fileURL: studyLibraryRoot.appendingPathComponent("collections.json"))
    }
    private var categoryStore: ShieldCategoryStore {
        .init(fileURL: studyLibraryRoot.deletingLastPathComponent().appendingPathComponent("categories.json"))
    }

    private let authorityReader: AuthorityStateReading
    private let enforcementReader: EnforcementStateReading
    private let installationInspector: BackendInstallationInspector
    private var refreshTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var studyManifest: StudyManifest?
    private var studyStore: StudyLibraryStore?
    private let studyLibraryRoot: URL
    private let fixtureBackend: FixtureBackend?
    private let xpcClient: FixtureBackendXPCClient?
    private(set) var locationSensor: LocationSensor?
    private(set) var locationReportProblem: String?
    @ObservationIgnored private var lastPresenceReport: Date?
    // A sensor change that arrived inside the 10 s throttle; sent on the next refresh.
    @ObservationIgnored private var presenceChangeWaiting = false
    // Development only: the in-process backend's presence state for this run.
    @ObservationIgnored private var presenceSession: PresenceSession?
    /// A practice Go day: the same arrival test, run here, blocking nothing.
    var goDayPractice: (gate: GoDayGate, endsAt: Date)?
    private var refreshSequence: UInt64 = 0
    /// When the periodic refresh now in flight started (one at a time: a slow
    /// reply is waited for, not superseded by the next 5 s refresh).
    @ObservationIgnored private var refreshStartedAt: Date?
    /// When the service last answered with a verified snapshot.
    @ObservationIgnored private var lastAnsweredAt: Date?
    /// True while the service briefly isn't answering (a busy Mac, sleep,
    /// a slow reply). The last verified rules stay on screen meanwhile;
    /// blocking itself never depends on the app.
    private(set) var isReconnecting = false
    /// How long a quiet service is ridden out before the window says so.
    /// One slow reply used to blank the whole page.
    nonisolated static let connectionGrace: TimeInterval = 60
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    /// What the per-change bookkeeping last ran for.
    @ObservationIgnored private var bookkept: BookkeepingKey?

    /// Rules change with the generation; which of them are in force also
    /// changes when a daily window opens or closes. The service normally
    /// commits a new generation then, but a snapshot showing the new set
    /// under the old generation must still count as a change.
    struct BookkeepingKey: Equatable {
        let generation: UInt64
        let inForce: Set<String>

        init(_ snapshot: BackendSnapshot) {
            generation = snapshot.generation
            inForce = Set(snapshot.authority.effectiveRestrictions.map(\.policyID))
        }
    }
    private var submissionInFlight = false
    private var highestObservedGeneration: UInt64 = 0
    private var courseLoadSequence: UInt64 = 0
    private var downloadOperationID: UUID?
    private let studyToolsOverride: StudyTools?

    init(
        authorityReader: AuthorityStateReading = AuthorityStateReader(),
        enforcementReader: EnforcementStateReading = HostsEnforcementReader(),
        installationInspector: BackendInstallationInspector = BackendInstallationInspector(),
        studyLibraryRoot: URL = KairosConfig.directoryURL.appendingPathComponent("StudyLibrary"),
        fixtureBackend: FixtureBackend? = nil,
        xpcClient: FixtureBackendXPCClient? = nil,
        studyToolsOverride: StudyTools? = nil
    ) {
        self.authorityReader = authorityReader
        self.enforcementReader = enforcementReader
        self.installationInspector = installationInspector
        self.studyLibraryRoot = studyLibraryRoot
        self.fixtureBackend = fixtureBackend
        self.xpcClient = xpcClient
        self.studyToolsOverride = studyToolsOverride
        categoryLayout = categoryStore.load()
        videoLibraryEnabled = Self.videoLibraryInitiallyEnabled(libraryRoot: studyLibraryRoot)
    }

    // MARK: Video Library add-on

    /// The main Shield is a blocker. Library, collections and downloads are an
    /// add-on, off for someone new and one click to add in Settings. Anyone
    /// who already has videos keeps it (never take away what they use).
    private(set) var videoLibraryEnabled = false
    static let videoLibraryKey = "Shield.VideoLibraryAddOn"

    nonisolated static func videoLibraryInitiallyEnabled(libraryRoot: URL,
                                                         defaults: UserDefaults = .standard) -> Bool {
        if let chosen = defaults.object(forKey: videoLibraryKey) as? Bool { return chosen }
        #if DEBUG
        // Development and UI Review builds keep the Library, as their tests expect.
        return true
        #else
        return hasVideoLibraryData(at: libraryRoot)
        #endif
    }

    /// Already used: a saved list, collections or the link queue on disk.
    nonisolated static func hasVideoLibraryData(at libraryRoot: URL) -> Bool {
        ["download-queue.json", "collections.json", ".link-queue-v1"].contains {
            FileManager.default.fileExists(atPath: libraryRoot.appendingPathComponent($0).path)
        }
    }

    /// Adding shows Library; removing hides it and stops downloads. Videos,
    /// collections and the sign-in file stay on this Mac either way.
    func setVideoLibraryEnabled(_ enabled: Bool) {
        guard enabled != videoLibraryEnabled else { return }
        if !enabled {
            if isDownloading { cancelDownloads() }
            experimentalDownloadsEnabled = false
            if selectedSection == .studyLibrary { selectedSection = .protection }
            selectedCollectionID = nil
        }
        videoLibraryEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.videoLibraryKey)
    }

    var authorityState: AuthorityState? {
        guard case .valid(let state) = health.authority else { return nil }
        return state
    }

    var isFixtureMode: Bool { fixtureBackend != nil || xpcClient != nil }
    var isServiceMode: Bool { xpcClient != nil }
    var isSubmittingPolicy: Bool { submissionInFlight }
    var canSubmitPolicy: Bool {
        ShieldRuntime.allowsSimulatedPolicyChanges && isFixtureMode &&
            backendSnapshot != nil && !submissionInFlight && pendingSubmission == nil && submissionRecordError == nil
    }
    var isPrivilegedDevelopmentMode: Bool {
        xpcClient?.privileged == true &&
            (backendSnapshot?.enforcementSource == .disposableSystemHosts ||
             backendSnapshot?.enforcementSource == .installedSystemHosts)
    }

    var authorityError: String? {
        guard case .unavailable(let error) = health.authority else { return nil }
        return error.localizedDescription
    }

    /// The schedule's calendar, rebuilt only when its time zone changes.
    var scheduleCalendar: Calendar {
        let identifier = backendSnapshot?.timeZoneIdentifier
        if let memo = scheduleCalendarMemo, memo.identifier == identifier,
           identifier != nil || memo.calendar.timeZone == .current { return memo.calendar }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = identifier.flatMap(TimeZone.init(identifier:)) ?? .current
        scheduleCalendarMemo = (identifier, calendar)
        return calendar
    }
    @ObservationIgnored private var scheduleCalendarMemo: (identifier: String?, calendar: Calendar)?

    var isShowingLinkQueue: Bool { studyManifest?.isLinkQueue == true }

    var listedStudyJobs: [StudyJob] {
        guard studyManifest?.isLinkQueue == true else { return studyJobs }
        let listed = queueIndex
        return studyJobs.filter { listed[$0.id] != nil || $0.isSaved }
    }
    var studyCompletedCount: Int { listedStudyJobs.count(where: \.isSaved) }

    private(set) var experimentalDownloadsEnabled = false
    private(set) var downloadActivities: [String: StudyWorkerStatus.Phase] = [:]
    var canEnableExperimentalDownloads: Bool {
        videoLibraryEnabled && StudyWorkerFetcher.isPackaged && !ShieldRuntime.isUIReview && !StudyInstalledAuthorityGuard.detected
    }
    var studyExecutionAvailable: Bool {
        containedDownloadsAvailable ||
        (StudyWorkerFetcher.isPackaged && experimentalDownloadsEnabled) || ShieldRuntime.allowsExternalTools
    }

    // Contained downloads: the bundled egress broker plus the
    // Seatbelt-confined tools. Approved IDs may download while YouTube itself
    // stays blocked for browsers and every other process.
    var containedDownloadsAvailable: Bool {
        videoLibraryEnabled && studyToolsOverride == nil && StudyContainment.bundled != nil && StudyContainment.discoveredTools != nil
    }

    func setExperimentalDownloadsEnabled(_ enabled: Bool) {
        experimentalDownloadsEnabled = enabled && canEnableExperimentalDownloads
        if !experimentalDownloadsEnabled && isDownloading { cancelDownloads() }
    }

    var canDownloadStudyCourse: Bool {
        studyExecutionAvailable && studyManifest != nil && studyCourseApproved
    }

    var studyFetchBlockReason: String? {
        if containedDownloadsAvailable { return studyPolicyBlockReason(now: .now, contained: true) }
        if StudyWorkerFetcher.isPackaged && StudyInstalledAuthorityGuard.detected {
            return "Installed Shield authority was detected. This Development app cannot authorize downloads against its commitments. Local imports remain available."
        }
        if !studyExecutionAvailable {
            if canEnableExperimentalDownloads {
                return "Experimental downloads require your approval for this session. The signed worker is sandboxed, but its outbound network access is not restricted to specific destinations by macOS."
            }
            return ShieldRuntime.isUIReview
                ? "UI review disables downloads and external tools."
                : "External tools are disabled until the downloader has OS-enforced filesystem and network containment."
        }
        return studyPolicyBlockReason(now: .now)
    }

    // Called again during worker polling and every bounded output transfer.
    // A stalled refresh cannot leave an old permission usable indefinitely.
    // The service's last confirmation must be recent: its `verifiedAt` (every
    // poll), or, from an older service, the authority's minute heartbeat.
    func studyPolicyBlockReason(now: Date, contained: Bool = false) -> String? {
        guard let authority = authorityState else {
            return "Policy authority is unavailable. Downloads are paused until committed restrictions can be verified."
        }
        guard let observed = lastRefresh,
              now.timeIntervalSince(observed) >= -5,
              now.timeIntervalSince(observed) <= 30,
              now.timeIntervalSince(latestSnapshot?.verifiedAt ?? authority.generatedAt) >= -5,
              now.timeIntervalSince(latestSnapshot?.verifiedAt ?? authority.generatedAt) <= 90 else {
            return "Shield's check of your blocks is out of date. Refresh in Settings, then download."
        }
        // Contained fetches never open YouTube to the rest of the Mac, so a
        // YouTube restriction does not pause them; fresh authority evidence
        // is still required above.
        if contained { return nil }
        let domains = Set(authority.effectiveRestrictions.flatMap(\.domains).map { $0.lowercased() })
        let videoServices = ["youtube.com", "youtu.be", "googlevideo.com", "ytimg.com", "youtube-nocookie.com"]
        return domains.contains(where: { domain in
            videoServices.contains { domain == $0 || domain.hasSuffix("." + $0) }
        })
            ? "Current protection blocks YouTube. Downloads cannot begin until the committed policy permits access."
            : nil
    }

    func approveStudyCourse() {
        guard studyExecutionAvailable, studyManifest != nil,
              !isDownloading, !isRestoringStudy else { return }
        studyCourseApproved = true
        studyMessage = "Downloads allowed for this folder. No blocking changed."
    }

    func start() {
        sweepLeftoverStaging()
        loadDownloadQueue()
        loadCollections()
        if !ShieldRuntime.isUIReview && studyManifest == nil { openLibrary() }
        loadSavedCourses()
        if !ShieldRuntime.isUIReview {
            do {
                pendingSubmission = try submissionStore.load()
                if let pendingSubmission {
                    submissionState = .unconfirmed(pendingSubmission.request.id)
                    backendActionMessage = "Checking the last request. Existing commitments are unchanged."
                }
            } catch {
                submissionRecordError = error.localizedDescription
                backendActionMessage = "The saved request could not be read: \(error.localizedDescription)"
                fixtureReceiptError = error.localizedDescription
            }
        }
        refresh()
        refreshTask?.cancel()
        if ShieldRuntime.isUIReview { return }
        // After sleep the last answer is old through no fault of the service.
        // Ask at once, and give the waking service the same short grace.
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.backendSnapshot != nil { self.lastAnsweredAt = .now }
                    self.refreshStartedAt = nil
                    self.refresh()
                }
            }
        }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func loadDownloadQueue() {
        do {
            if let saved = try queueStore.load() { queue = saved }
            else if (!isFixtureMode || isServiceMode),
                    let legacy = UserDefaults.standard.string(forKey: "Shield.VideoDownloadQueue"), !legacy.isEmpty {
                let ids = legacy.split(separator: ",").map(String.init)
                let migrated = try StudyQueueDocument(items: ids.map {
                    StudyQueueItem(id: $0, approvedAt: .now, title: nil)
                }).validated()
                try queueStore.save(migrated)
                queue = migrated // Keep the old preference as migration evidence.
            }
            queueReadError = false
        } catch { queueReadError = true; queueProblem(error.localizedDescription) }
    }

    @discardableResult
    func addVideoLinks(_ text: String) -> Bool {
        // Adding works during a download: new rows are appended without
        // touching the run. Only the saved-video check blocks it.
        guard !queueReadError, !isRestoringStudy else { return false }
        if isDownloading && !isShowingLinkQueue { return false }
        do {
            let parsed = StudyYouTubeLinks.parse(text)
            var updated = queue
            let added = try updated.append(parsed)
            try queueStore.save(updated)
            queue = updated
            let already = parsed.ids.count - added
            queueNotice = (["Added \(added)"] +
                (already > 0 ? ["\(already) already in your library"] : []) +
                (parsed.rejectedCount > 0 ? ["\(parsed.rejectedCount) not a YouTube link"] : []))
                .joined(separator: " · ")
            if !ShieldRuntime.isUIReview && !appendToOpenLibrary(parsed.ids) {
                openQueuedVideos(ids: queue.items.map(\.id))
            }
            return true
        } catch { queueProblem(error.localizedDescription); return false }
    }

    /// Adds rows for new library videos to the open library without
    /// re-checking every saved file. False when the library isn't open.
    private func appendToOpenLibrary(_ ids: [String]) -> Bool {
        guard isShowingLinkQueue, let manifest = studyManifest, let store = studyStore, !isRestoringStudy else {
            return false
        }
        let known = Set(manifest.videos.map(\.id))
        var seen = Set<String>()
        let listed = Set(queue.items.map(\.id))
        let added = ids.filter { !known.contains($0) && listed.contains($0) && seen.insert($0).inserted }
        guard !added.isEmpty else { return true }
        let newVideos = added.map {
            StudyVideo(id: $0, title: String(libraryTitle($0).prefix(160)), expectedDuration: nil, transcriptRequested: true)
        }
        do {
            let updated = try StudyManifest(schemaVersion: 1, courseTitle: manifest.courseTitle,
                                            videos: manifest.videos + newVideos, origin: .linkQueue).validated()
            let previous = try store.load()
            try store.save(StudyLibrarySnapshot(version: 1, manifest: updated,
                                                completedIDs: previous?.completedIDs ?? [],
                                                failures: previous?.failures ?? [:], updatedAt: .now,
                                                inFlightIDs: previous?.inFlightIDs))
            studyManifest = updated
            studyJobs += newVideos.map { StudyJob(id: $0.id, title: $0.title, state: .queued) }
            return true
        } catch { return false }
    }

    /// Drops a deleted video's row from the open library without re-checking.
    private func removeFromOpenLibrary(_ id: String) -> Bool {
        guard isShowingLinkQueue, let manifest = studyManifest, let store = studyStore, !isRestoringStudy else {
            return false
        }
        let videos = manifest.videos.filter { $0.id != id }
        guard !videos.isEmpty else { return false }
        do {
            let updated = try StudyManifest(schemaVersion: 1, courseTitle: manifest.courseTitle,
                                            videos: videos, origin: .linkQueue).validated()
            if var snapshot = try store.load() {
                snapshot.completedIDs.remove(id)
                snapshot.failures[id] = nil
                snapshot.inFlightIDs?.remove(id)
                try store.save(StudyLibrarySnapshot(version: 1, manifest: updated, completedIDs: snapshot.completedIDs,
                                                    failures: snapshot.failures, updatedAt: .now,
                                                    inFlightIDs: snapshot.inFlightIDs))
            }
            studyManifest = updated
            studyJobs.removeAll { $0.id == id }
            return true
        } catch { return false }
    }

    // MARK: Library and collections
    //
    // Downloads is one library (the saved link list) plus owner-made
    // collections over it. Every saved file lives once in the library folder.

    /// One run downloads at most the worker's per-request approval limit.
    static let downloadBatchLimit = 100
    private var libraryRoot: URL { studyLibraryRoot.appendingPathComponent(".link-queue-v1") }

    var libraryIDs: [String] { queue.items.map(\.id) }
    var isShowingOlderLibrary: Bool { studyManifest != nil && !isShowingLinkQueue }

    func libraryTitle(_ id: String) -> String {
        queueIndex[id]?.title ?? "YouTube video \(id)"
    }

    /// The name saved for a video, nil while YouTube's title isn't known yet.
    func savedTitle(_ id: String) -> String? { queueIndex[id]?.title }

    /// What the player and Up Next call a video: its library name, or its
    /// lesson title in an older course folder.
    func videoTitle(_ id: String) -> String {
        if isShowingLinkQueue { return libraryTitle(id) }
        return studyJobs.first { $0.id == id }?.title ?? libraryTitle(id)
    }

    /// The next saved video after `id` in the collection being viewed.
    func nextSavedVideo(after id: String) -> String? {
        let jobs = libraryJobs(in: selectedCollectionID)
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return nil }
        return jobs[(index + 1)...].first { if case .complete = $0.state { true } else { false } }?.id
    }

    /// The folder holding the saved files of the library being viewed.
    var savedFilesFolder: URL? {
        guard !ShieldRuntime.isUIReview, let studyManifest else { return nil }
        let folder = isShowingLinkQueue ? libraryRoot : libraryDirectory(for: studyManifest)
        return FileManager.default.fileExists(atPath: folder.path) ? folder : nil
    }

    /// The saved video and transcript files of `ids`, for Show in Finder.
    func savedFiles(for ids: [String]) -> [URL] {
        guard let folder = savedFilesFolder else { return [] }
        return ids.flatMap { id in ["mp4", "txt"].map { folder.appendingPathComponent("\(id).\($0)") } }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// All Videos (nil) or one collection, in that collection's order.
    func libraryJobs(in collectionID: String?) -> [StudyJob] {
        guard isShowingLinkQueue else { return listedStudyJobs }
        let ids = Set(libraryIDs)
        let listed = listedStudyJobs.filter { ids.contains($0.id) }
        guard let collectionID, let collection = collectionLayout.collection(collectionID) else { return listed }
        let byID = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return collection.videoIDs.compactMap { byID[$0] }
    }

    /// Shows the library, first adopting saved videos that an older version
    /// dropped from the list, so every saved file appears exactly once.
    func openLibrary() {
        guard !ShieldRuntime.isUIReview, !isDownloading, !isRestoringStudy, !queueReadError else { return }
        do {
            if let snapshot = try StudyLibraryStore(root: libraryRoot).load() {
                let known = Set(libraryIDs)
                let orphans = snapshot.manifest.videos.filter {
                    snapshot.completedIDs.contains($0.id) && !known.contains($0.id)
                }
                if !orphans.isEmpty, queue.items.count + orphans.count <= StudyQueueDocument.limit {
                    var updated = queue
                    updated.items += orphans.map {
                        StudyQueueItem(id: $0.id, approvedAt: .now,
                                       title: $0.title == "Video \($0.id)" ? nil : $0.title)
                    }
                    try queueStore.save(updated)
                    queue = updated
                }
            }
        } catch { studyPersistenceError = "Saved videos could not be checked: \(error.localizedDescription)" }
        guard !queue.items.isEmpty else {
            // An empty library still leaves any older folder: Library is empty.
            studyManifest = nil
            studyManifestTitle = nil
            studyStore = nil
            studyJobs = []
            return
        }
        openQueuedVideos(ids: libraryIDs)
    }

    /// Adds pasted links to the library and, optionally, to one collection.
    /// Links already in the library are only added to the collection.
    @discardableResult
    func addVideoLinks(_ text: String, toCollection collectionID: String?) -> Bool {
        let ids = StudyYouTubeLinks.parse(text).ids
        guard addVideoLinks(text) else { return false }
        if let collectionID, let collection = collectionLayout.collection(collectionID) {
            updateCollections { $0.add(ids, to: collectionID) }
            if let notice = queueNotice, notice.hasPrefix("Added ") {
                queueNotice = "Added to “\(collection.name)”: " + notice.dropFirst("Added ".count)
            }
        }
        return true
    }

    func loadCollections() {
        let loaded = collectionStore.load()
        collectionLayout = loaded.layout
        collectionsUnreadable = loaded.unreadable
        collectionNotice = loaded.unreadable
            ? "Saved collections could not be read. The file is kept, and your videos are unchanged." : nil
        if let selectedCollectionID, collectionLayout.collection(selectedCollectionID) == nil {
            self.selectedCollectionID = nil
        }
    }

    private func updateCollections(_ change: (inout StudyCollectionLayout) -> Void) {
        var updated = collectionLayout
        change(&updated)
        // Never prune members here: an empty or recovering list must not empty
        // every collection. Deleting a video removes it from collections itself.
        updated = updated.normalized()
        do {
            if collectionsUnreadable {
                try collectionStore.preserveUnreadable()
                collectionsUnreadable = false
            }
            try collectionStore.save(updated)
            collectionLayout = updated
            collectionNotice = nil
        } catch { collectionNotice = "Collections could not be saved: \(error.localizedDescription)" }
    }

    var canAddCollection: Bool {
        !queueReadError && collectionLayout.collections.count < StudyCollection.maximumCount
    }

    /// True once `collection` is saved (a new one is refused at the limit).
    @discardableResult
    func saveCollection(_ collection: StudyCollection) -> Bool {
        updateCollections { $0.upsert(collection) }
        return collectionNotice == nil && collectionLayout.collection(collection.id) != nil
    }

    func deleteCollection(_ id: String) {
        updateCollections { $0.delete(id) }
        if selectedCollectionID == id { selectedCollectionID = nil }
    }

    func moveCollection(_ id: String, by offset: Int) { updateCollections { $0.move(id, by: offset) } }
    func moveCollection(_ id: String, to targetID: String) { updateCollections { $0.move(id, to: targetID) } }
    func moveCollections(fromOffsets source: IndexSet, toOffset destination: Int) {
        updateCollections { $0.move(fromOffsets: source, toOffset: destination) }
    }

    func addVideos(_ ids: [String], toCollection id: String) { updateCollections { $0.add(ids, to: id) } }

    func removeVideo(_ id: String, fromCollection collectionID: String) {
        updateCollections { $0.remove(id, from: collectionID) }
    }

    func renameVideo(_ id: String, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !queueReadError, !trimmed.isEmpty, trimmed.count <= 160,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let index = queue.items.firstIndex(where: { $0.id == id }) else {
            queueProblem("Enter a name of up to 160 characters.")
            return
        }
        var updated = queue
        updated.items[index].title = trimmed
        do { try queueStore.save(updated); queue = updated; queueNotice = nil }
        catch { queueProblem("The name couldn't be saved.") }
    }

    /// Removes a video from the library and every collection, and deletes its
    /// saved video, transcript and playback position.
    func deleteVideo(_ id: String) {
        guard !ShieldRuntime.isUIReview, !isDownloading, !isRestoringStudy, !queueReadError,
              StudyYouTubeLinks.isValidID(id), queue.items.contains(where: { $0.id == id }) else { return }
        do {
            let store = StudyLibraryStore(root: libraryRoot)
            // Forget the saved status first: a failed file removal must never
            // leave an entry that claims media which is gone.
            if var snapshot = try store.load() {
                snapshot.completedIDs.remove(id)
                snapshot.failures[id] = nil
                snapshot.inFlightIDs?.remove(id)
                snapshot.updatedAt = .now
                try store.save(snapshot)
            }
            try ShieldRuntime.requireIsolatedWrite(to: libraryRoot)
            for suffix in ["mp4", "txt", "cues.json", "playback.json"] {
                let file = libraryRoot.appendingPathComponent("\(id).\(suffix)")
                var info = stat()
                if lstat(file.path, &info) == 0 { try FileManager.default.removeItem(at: file) }
            }
            playbackPositions[id] = nil
            VideoThumbnailCache.shared.forget(id)
            var updated = queue
            updated.items.removeAll { $0.id == id }
            try queueStore.save(updated)
            queue = updated
            updateCollections { $0.removeEverywhere(id) }
            queueNotice = "Video deleted."
            if !removeFromOpenLibrary(id) { openLibrary() }
        } catch {
            // Its saved status was cleared first, so the row shows it as not saved.
            openLibrary()
            queueProblem("The video couldn't be fully deleted. It's still in your library; try again.")
        }
    }

    func collectionID(forCourse manifest: StudyManifest) -> String {
        "course-" + SHA256.hash(data: Data(manifest.courseTitle.precomposedStringWithCanonicalMapping.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func isCourseInLibrary(_ manifest: StudyManifest) -> Bool {
        collectionLayout.collection(collectionID(forCourse: manifest)) != nil
    }

    /// Adds a course's videos (with their titles) to the library and gathers
    /// them in a collection named after the course.
    func addCourseToLibrary(_ manifest: StudyManifest, symbol: String = "graduationcap.fill",
                            color: ShieldCategoryColor = .blue) {
        guard !ShieldRuntime.isUIReview, !queueReadError, !isDownloading, !isRestoringStudy else { return }
        do {
            var updated = queue
            let known = Set(updated.items.map(\.id))
            let additions = manifest.videos.filter { !known.contains($0.id) }
            guard updated.items.count + additions.count <= StudyQueueDocument.limit else {
                throw StudyDownloadError.invalidManifest("The library holds at most \(StudyQueueDocument.limit) videos.")
            }
            updated.items += additions.map { StudyQueueItem(id: $0.id, approvedAt: .now, title: $0.title) }
            for video in manifest.videos {
                if let index = updated.items.firstIndex(where: { $0.id == video.id }), updated.items[index].title == nil {
                    updated.items[index].title = video.title
                }
            }
            try queueStore.save(updated)
            queue = updated
            let id = collectionID(forCourse: manifest)
            var collection = collectionLayout.collection(id) ?? StudyCollection(
                // "Publisher — Course Name" reads as "Course Name" in the sidebar.
                id: id, name: String((manifest.courseTitle.components(separatedBy: " — ").last ?? manifest.courseTitle)
                    .prefix(StudyCollection.maximumNameLength)),
                symbol: symbol, color: color, videoIDs: [])
            for video in manifest.videos where !collection.videoIDs.contains(video.id) {
                collection.videoIDs.append(video.id)
            }
            updateCollections { $0.upsert(collection) }
            selectedCollectionID = id
            queueNotice = "Added \(additions.count) video\(additions.count == 1 ? "" : "s") to your library in “\(collection.name)”."
            if !appendToOpenLibrary(manifest.videos.map(\.id)) { openLibrary() }
        } catch { queueProblem(error.localizedDescription) }
    }

    /// Downloads what is not saved yet in All Videos or one collection.
    func downloadVideos(in collectionID: String?) {
        guard isShowingLinkQueue else { startDownloads(); return }
        guard studyExecutionAvailable else {
            studyMessage = "External tools are disabled in this build. No process was started."
            return
        }
        guard !isDownloading, !isRestoringStudy, let manifest = studyManifest, canDownloadStudyCourse else { return }
        if let reason = studyFetchBlockReason { studyMessage = reason; return }
        let waiting = libraryJobs(in: collectionID).filter(isDownloadable)
        let batch = Set(waiting.prefix(Self.downloadBatchLimit).map(\.id))
        runDownloads(manifest: StudyManifest(schemaVersion: 1, courseTitle: manifest.courseTitle,
                                             videos: manifest.videos.filter { batch.contains($0.id) }))
        if waiting.count > batch.count {
            studyMessage = "Downloading the first \(batch.count). Start again afterwards for the other \(waiting.count - batch.count)."
        }
    }

    /// Adding works while downloading (new rows are appended); only the
    /// saved-video check or an unreadable list blocks it.
    var canAddVideoLinks: Bool { !queueReadError && !isRestoringStudy && !ShieldRuntime.isUIReview }

    /// Not saved yet, and a new try could save it (a private or removed video can't).
    func isDownloadable(_ job: StudyJob) -> Bool {
        switch job.state {
        case .complete: return false
        case .failed(let raw):
            let action = StudyFailureText.describe(raw, signInFilePresent: signInFilePresent).action
            return action == .retry || action == .downloadAgain
        default: return true
        }
    }

    /// Retries only failures that a new attempt can fix (not private videos).
    func retryFailedVideos(in collectionID: String?) {
        guard studyExecutionAvailable, !isDownloading, !isRestoringStudy, let manifest = studyManifest,
              canDownloadStudyCourse else { return }
        if let reason = studyFetchBlockReason { studyMessage = reason; return }
        let ids = Set(libraryJobs(in: collectionID).compactMap { job -> String? in
            guard case .failed(let raw) = job.state else { return nil }
            let action = StudyFailureText.describe(raw, signInFilePresent: signInFilePresent).action
            return action == .retry || action == .downloadAgain ? job.id : nil
        }.prefix(Self.downloadBatchLimit))
        runDownloads(manifest: StudyManifest(schemaVersion: 1, courseTitle: manifest.courseTitle,
                                             videos: manifest.videos.filter { ids.contains($0.id) }))
    }

    /// Downloads one video that is not saved yet, or retries one that failed.
    func downloadVideo(id: String) {
        guard let job = studyJobs.first(where: { $0.id == id }) else { return }
        if case .failed = job.state { retryDownload(id: id); return }
        guard case .queued = job.state, studyExecutionAvailable, !isDownloading, !isRestoringStudy,
              let manifest = studyManifest, canDownloadStudyCourse,
              let video = manifest.videos.first(where: { $0.id == id }) else { return }
        if let reason = studyFetchBlockReason { studyMessage = reason; return }
        runDownloads(manifest: StudyManifest(schemaVersion: 1, courseTitle: manifest.courseTitle, videos: [video]))
    }

    func recoverDownloadQueue() {
        guard queueReadError, !isDownloading, !isRestoringStudy else { return }
        do {
            try queueStore.recoverEmptyQueue(legacy: UserDefaults.standard.string(forKey: "Shield.VideoDownloadQueue"))
            queue = StudyQueueDocument(items: [])
            queueReadError = false
            queueNotice = "Started a fresh video list. The old one is kept as a backup; saved files are unchanged."
            // Saved videos come back into the list (and their collections) here.
            openLibrary()
        } catch { queueProblem("Couldn't start a fresh list. The original was kept.") }
    }

    // Turns approved exact IDs into a normal local collection. This is a
    // library/import bridge, NOT online fetching or implicit download consent.
    func openQueuedVideos(ids: [String]) {
        guard !ShieldRuntime.isUIReview, !isDownloading, !isRestoringStudy,
              !ids.isEmpty, ids.count <= StudyQueueDocument.limit,
              ids.allSatisfy(StudyYouTubeLinks.isValidID),
              Set(ids).count == ids.count else {
            studyMessage = "The link queue cannot be opened right now."
            return
        }
        let manifest = StudyManifest(schemaVersion: 1, courseTitle: "Downloads",
            videos: ids.map { id in
                StudyVideo(id: id, title: String((queue.items.first(where: { $0.id == id })?.title ?? "Video \(id)").prefix(160)),
                           expectedDuration: nil, transcriptRequested: true)
            }, origin: .linkQueue)
        do {
            let directory = libraryDirectory(for: manifest)
            let existing = try StudyLibraryStore(root: directory).load()
            // Removing a queued ID never removes a validated saved item.
            let kept = existing?.manifest.videos.filter { existing?.completedIDs.contains($0.id) == true && !ids.contains($0.id) } ?? []
            openStudyManifest(try StudyManifest(schemaVersion: 1, courseTitle: "Downloads",
                videos: manifest.videos + kept, origin: .linkQueue).validated(), approved: true, replacingQueue: true)
        } catch { studyMessage = error.localizedDescription }
    }

    func openSavedCourse(_ manifest: StudyManifest) {
        openStudyManifest(manifest, approved: manifest.isLinkQueue)
    }

    func loadSavedCourses() {
        let root = studyLibraryRoot
        courseLoadSequence &+= 1
        let sequence = courseLoadSequence
        Task { [weak self] in
            let (courses, counts, problem) = await Task.detached { () -> ([StudyManifest], [String: Int], String?) in
                guard ShieldRuntime.permitsStateRead(from: root) else {
                    return ([], [:], "This build cannot read that library.")
                }
                guard FileManager.default.fileExists(atPath: root.path) else { return ([], [:], nil) }
                do {
                    var directories = try FileManager.default.contentsOfDirectory(
                        at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                    let queueDirectory = root.appendingPathComponent(".link-queue-v1")
                    if FileManager.default.fileExists(atPath: queueDirectory.path) { directories.append(queueDirectory) }
                    var courses: [StudyManifest] = []
                    var counts: [String: Int] = [:]
                    var unreadable = 0
                    for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                        guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                        do {
                            if let state = try StudyLibraryStore(root: directory).load() {
                                courses.append(state.manifest)
                                counts[state.manifest.selectionKey] = state.completedIDs.count
                            }
                        } catch { unreadable += 1 }
                    }
                    return (courses, counts, unreadable == 0 ? nil : "\(unreadable) saved courses could not be read. Their files were preserved; re-import the original manifests after checking the library.")
                } catch { return ([], [:], "Library could not be opened: \(error.localizedDescription)") }
            }.value
            guard let self, self.courseLoadSequence == sequence else { return }
            self.savedCourses = courses
            self.olderLibraryCounts = counts
            if let problem { self.studyPersistenceError = problem }
            // The library opens on its own; older folders open only from
            // Library ▸ More ▸ Older Downloads.
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        retryTask?.cancel()
        retryTask = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        locationSensor?.stop()
        courseLoadSequence &+= 1
        importTask?.cancel()
        restoreTask?.cancel()
        downloadTask?.cancel()
    }

    // Development fixture interaction. Production submission requires an
    // authenticated privileged service; this method never writes live rules.
    func commitFixtureFocus(domains: Set<String> = ["example.com"],
                            untilReleased: Bool = false, now: Date = .now) {
        commitBlock(domains: domains, duration: untilReleased ? .untilReleased : .oneHour, now: now)
    }

    @discardableResult
    func commitBlock(domains: Set<String>, duration: NewBlockDuration, now: Date = .now, groupName: String? = nil,
                     categoryID: String? = nil, apps: Set<AppTarget> = [], placeID: String? = nil,
                     permanent: Bool = false) -> UUID? {
        guard ShieldRuntime.allowsSimulatedPolicyChanges else {
            backendActionMessage = "UI review cannot change even simulated committed policy."
            return nil
        }
        guard canSubmitPolicy, let snapshot = backendSnapshot else {
            backendActionMessage = "Shield's service isn't available. Nothing changed."
            return nil
        }
        guard domains.count <= 20, PolicyValidation.validTargets(domains: domains, apps: apps) else {
            backendActionMessage = apps.isEmpty ? "Enter valid website domains." : "Choose websites or apps that can be blocked."
            return nil
        }
        // A place block lasts until released, like the default duration.
        guard placeID == nil || (duration == .untilReleased && availablePlaces.contains { $0.id == placeID }) else {
            backendActionMessage = "Choose a saved place."
            return nil
        }
        // Permanent is Lock In Forever's rule: everywhere, no end, and the
        // same 72-hour correction ("focus-" owner).
        guard !permanent || (placeID == nil && duration == .untilReleased) else {
            backendActionMessage = "A permanent block applies everywhere."
            return nil
        }
        let rule = DomainRestriction(owner: permanent ? .permanent : .commitment,
                                     policyID: "focus-\(UUID().uuidString)",
                                     title: groupName.map(ShieldCategoryLayout.cleanName).flatMap { $0.isEmpty ? nil : $0 } ?? "Custom block",
                                     domains: domains, startsAt: now,
                                     endsAt: duration.seconds.map { now.addingTimeInterval($0) }, apps: apps,
                                     placeID: placeID)
        backendActionMessage = "Submitting block request…"
        // Placement is presentation only; an unconfirmed rule ID is simply never shown.
        if let categoryID { updateCategories { $0.place([rule.policyID], in: categoryID) } }
        return submitFixture([.add(rule)], generation: snapshot.generation, now: now)
    }

    /// New Block "For a set time": one Lock In plan, shown in the chosen
    /// category. The service decides the end exactly as for a Lock In.
    func commitTimedBlock(_ plan: LockInPlan, categoryID: String, now: Date = .now) -> UUID? {
        guard ShieldRuntime.allowsSimulatedPolicyChanges else {
            backendActionMessage = "UI review cannot change even simulated committed policy."
            return nil
        }
        guard canSubmitPolicy, let snapshot = backendSnapshot else {
            backendActionMessage = "Shield's service isn't available. Nothing changed."
            return nil
        }
        if let problem = plan.problem(now: now) {
            backendActionMessage = problem
            return nil
        }
        guard let built = plan.commands(now: now) else {
            backendActionMessage = "This block can't be made."
            return nil
        }
        updateCategories { $0.place([built.policyID], in: categoryID) }
        backendActionMessage = "Submitting block request…"
        return submitFixture(built.commands, generation: snapshot.generation, now: now)
    }

    /// Submits every rule of one Lock In (one per "when it's allowed") as a
    /// single atomic request: all of them are confirmed together, or none. The
    /// plans build only release-242 commands; the service still decides every
    /// delay and refusal. The rules show under their usual category (Other).
    func lockIn(plans: [LockInPlan], now: Date = .now) -> UUID? {
        guard ShieldRuntime.allowsSimulatedPolicyChanges else {
            backendActionMessage = "UI review cannot change even simulated committed policy."
            return nil
        }
        guard canSubmitPolicy, let snapshot = backendSnapshot else {
            backendActionMessage = "Shield's service isn't available. Nothing changed."
            return nil
        }
        guard !plans.isEmpty else {
            backendActionMessage = "Choose websites or apps."
            return nil
        }
        var commands: [BackendCommand] = []
        for plan in plans {
            if let problem = plan.problem(now: now) {
                backendActionMessage = problem
                return nil
            }
            guard let built = plan.commands(now: now) else {
                backendActionMessage = "This lock can't be made."
                return nil
            }
            commands += built.commands
        }
        backendActionMessage = "Submitting lock…"
        return submitFixture(commands, generation: snapshot.generation, now: now)
    }

    // MARK: Category editing (presentation only, never submitted)

    func saveCategory(_ category: ShieldCategory) {
        updateCategories { $0.upsert(category) }
    }

    func placeRule(_ ruleID: String, in categoryID: String) {
        // A combined card moves as one.
        let ids = categoryLayout.combination(containing: ruleID) ?? [ruleID]
        updateCategories { $0.place(ids, in: categoryID) }
    }

    /// The name a list or schedule is shown with everywhere.
    func displayName(for ruleID: String, title: String) -> String {
        categoryLayout.displayName(for: ruleID, title: title)
    }

    /// Renames a list or schedule in Shield's window. Display only: blocking
    /// doesn't change, so it applies at once. An empty name restores the original.
    func renameRule(_ ruleID: String, to name: String) {
        updateCategories { $0.rename(ruleID, to: name) }
    }

    /// Shows several lists as one card. Display only: each list keeps its own
    /// terms and websites, and they can be separated again at any time.
    func combineRules(_ ruleIDs: [String], name: String, in categoryID: String) {
        updateCategories { $0.combine(ruleIDs, name: name, in: categoryID) }
    }

    func separateRules(_ ruleIDs: [String]) {
        updateCategories { $0.separate(ruleIDs) }
    }

    /// Removes the category only. Its rules keep blocking and show in their
    /// default category or Other blocks. Use `releaseRules` to also ask the
    /// service to remove them.
    func deleteCategory(_ categoryID: String) {
        updateCategories { $0.delete(categoryID) }
    }

    private func updateCategories(_ change: (inout ShieldCategoryLayout) -> Void) {
        var next = categoryLayout
        change(&next)
        next = next.normalized()
        guard next != categoryLayout else { return }
        categoryLayout = next
        do {
            try categoryStore.save(next)
            categoryMessage = nil
        } catch {
            categoryMessage = "Category changes apply until Shield quits but were not saved: \(error.localizedDescription)"
        }
    }

    // MARK: Website and schedule changes (service-confirmed)

    /// What removing sites from a rule would do, or why it cannot.
    enum SiteRemoval: Equatable {
        case afterDelay       // ordinary commitment or schedule: 24 hours
        case correction       // Lock In "Forever" within its 72-hour correction window
        case afterPermanentWait(TimeInterval) // 1.1 permanent block: the removal wait
        case unavailable(String)
    }

    /// The service's removal wait and never-removable list; nil from an older service.
    var permanentRemoval: PermanentRemovalPolicy? { backendSnapshot?.permanentRemoval }

    /// The checkbox before a permanent block.
    var permanentAcknowledgement: String {
        guard let removal = permanentRemoval else { return "I understand this never ends" }
        return "I understand removing it takes \(PermanentRemovalPolicy.describe(removal.currentWait(at: .now)))"
    }

    /// A permanent or "until released" block added in the last 10 minutes.
    func canUndoNewBlock(_ restriction: DomainRestriction, now: Date = .now) -> Bool {
        guard let snapshot = backendSnapshot, let removal = snapshot.permanentRemoval,
              snapshot.committedRestrictions.contains(restriction) else { return false }
        return removal.canUndo(restriction, pending: snapshot.pendingReleases, at: now)
    }

    func undoNewBlock(_ restriction: DomainRestriction, now: Date = .now) -> UUID? {
        guard canSubmitPolicy, let snapshot = backendSnapshot, canUndoNewBlock(restriction, now: now) else {
            backendActionMessage = "The 10 minutes to undo this block have passed."
            return nil
        }
        backendActionMessage = "Undoing \(restriction.title)."
        return submitFixture([.undoNew(restriction.policyID)], generation: snapshot.generation, now: now)
    }

    /// Longer applies at once; shorter only after the current wait passes.
    func setPermanentRemovalWait(_ seconds: TimeInterval, now: Date = .now) -> UUID? {
        guard canSubmitPolicy, let snapshot = backendSnapshot, snapshot.permanentRemoval != nil,
              PermanentRemovalPolicy.validWait(seconds) else {
            backendActionMessage = "Shield's service isn't available. Nothing changed."
            return nil
        }
        return submitFixture([.setPermanentRemovalWait(seconds)], generation: snapshot.generation, now: now)
    }

    // MARK: Remove Shield (1.1)

    enum ShieldRemovalState: Equatable {
        /// An older service, or no service: removal isn't offered here.
        case unsupported
        /// A never-removable block keeps Shield installed.
        case blocked
        case available(wait: TimeInterval)
        /// Asked for; runs at `due` (later if a timed block is still running).
        case pending(due: Date)
    }

    func shieldRemovalState(now: Date = .now) -> ShieldRemovalState {
        guard let snapshot = backendSnapshot, let removal = snapshot.permanentRemoval else { return .unsupported }
        if let due = removal.uninstallDue(restrictions: snapshot.committedRestrictions,
                                          pending: snapshot.pendingReleases) {
            return .pending(due: due)
        }
        if snapshot.committedRestrictions.contains(where: removal.blocksUninstall) { return .blocked }
        return .available(wait: removal.uninstallWait(at: now))
    }

    /// The earliest Shield could be gone if asked now: the wait, or later if a
    /// timed block or pending change runs past it.
    func shieldRemovalDate(now: Date = .now) -> Date? {
        guard case .available(let wait) = shieldRemovalState(now: now), let snapshot = backendSnapshot else { return nil }
        let asked = now.addingTimeInterval(wait + 300)
        return (snapshot.committedRestrictions.compactMap(\.endsAt) + snapshot.pendingReleases.map(\.effectiveAt))
            .reduce(asked, max)
    }

    func requestShieldRemoval(now: Date = .now) -> UUID? {
        guard canSubmitPolicy, let snapshot = backendSnapshot,
              case .available(let wait) = shieldRemovalState(now: now) else {
            backendActionMessage = "Shield can't be removed right now. Nothing changed."
            return nil
        }
        // Five minutes of slack so the request still meets the wait when the
        // service receives it.
        return submitFixture([.requestUninstall(at: now.addingTimeInterval(wait + 300))],
                             generation: snapshot.generation, now: now)
    }

    /// Keeping Shield is never weaker, so it applies at once.
    func keepShield(now: Date = .now) -> UUID? {
        guard canSubmitPolicy, let snapshot = backendSnapshot, case .pending = shieldRemovalState(now: now) else {
            return nil
        }
        backendActionMessage = "Shield stays installed."
        return submitFixture([.cancelUninstall], generation: snapshot.generation, now: now)
    }

    func siteRemoval(for restriction: DomainRestriction, now: Date = .now) -> SiteRemoval {
        if backendSnapshot?.pendingReleases.contains(where: { $0.policyID == restriction.policyID }) == true {
            return .unavailable("A change to this block is already pending.")
        }
        switch restriction.owner {
        case .commitment where restriction.endsAt == nil: return .afterDelay
        case .commitment, .temporary: return .unavailable("Timed blocks end on their own and cannot end early.")
        case .permanent:
            // A block made under 1.1 is removed with the removal wait; Fix a
            // Mistake (24 hours) stays only for never-removable ones.
            if let removal = permanentRemoval, removal.isRemovable(restriction) {
                return .afterPermanentWait(removal.currentWait(at: now))
            }
            if restriction.isCorrectablePermanent(at: now) { return .correction }
            return .unavailable("Permanent blocks cannot be released in Shield.")
        case .recurring: return .unavailable("Change daily hours from the Today timeline.")
        case .conditional: return .unavailable("Change this from its place or condition rule.")
        }
    }

    /// Keeps the remaining websites blocked with the same commitment, at once,
    /// and releases the original rule no sooner than 24 hours from now.
    func removeSites(_ removed: Set<String>, from restriction: DomainRestriction, now: Date = .now) -> UUID? {
        guard canSubmitPolicy, let snapshot = backendSnapshot,
              snapshot.committedRestrictions.contains(restriction),
              !removed.isEmpty, removed.isSubset(of: restriction.domains) else {
            backendActionMessage = "This block changed or the service is unavailable. Nothing was submitted."
            return nil
        }
        let releaseAt = now.addingTimeInterval(LockInPlan.releaseHeadroom)
        let release: BackendCommand
        var commands = [BackendCommand]()
        let category = categoryLayout.categoryID(for: restriction.policyID,
                                                 defaultKind: ShieldGrouping.kind(for: restriction))
        var message = "Submitting change. Removed websites stay blocked for at least 24 hours."
        switch siteRemoval(for: restriction, now: now) {
        case .afterDelay: release = .release(restriction.policyID, at: releaseAt)
        case .afterPermanentWait(let wait):
            // A minute of headroom, as every release has, so it isn't refused at the boundary.
            release = .release(restriction.policyID,
                               at: now.addingTimeInterval(wait + LockInPlan.releaseHeadroom - 86_400))
            message = "Submitting change. Removed websites stay blocked for \(PermanentRemovalPolicy.describe(wait))."
        case .correction:
            // Undoing a mistaken permanent: removed sites wait 24 hours like any
            // release; kept sites stay permanent with the original deadline.
            release = .correctRecentPermanent(restriction.policyID, releaseAt: releaseAt)
            message = "Submitting correction. Removed websites stay blocked for 24 hours."
        case .unavailable(let reason):
            backendActionMessage = reason
            return nil
        }
        let remaining = restriction.domains.subtracting(removed)
        if !remaining.isEmpty || !restriction.apps.isEmpty {
            // The kept sites inherit the original start, so a correction never
            // restarts the 72-hour window that makes a permanent block correctable.
            // Removing websites never removes the rule's apps.
            let kept = DomainRestriction(owner: restriction.owner, policyID: "focus-\(UUID().uuidString)",
                                         title: restriction.title, domains: remaining,
                                         startsAt: min(restriction.startsAt ?? now, now), apps: restriction.apps,
                                         placeID: restriction.placeID)
            commands.insert(.add(kept), at: 0)
            updateCategories { $0.place([kept.policyID], in: category) }
        }
        commands.append(release)
        backendActionMessage = message
        return submitFixture(commands, generation: snapshot.generation, now: now)
    }

    /// A new daily schedule only adds blocking, so it applies at once.
    func addSchedule(name: String, domains: Set<String>, allowed: AllowedAccessWindow,
                     categoryID: String, now: Date = .now, apps: Set<AppTarget> = []) -> UUID? {
        guard canSubmitPolicy, let snapshot = backendSnapshot else {
            backendActionMessage = "Shield's service isn't available. Nothing changed."
            return nil
        }
        let title = ShieldCategoryLayout.cleanName(name)
        guard !title.isEmpty, domains.count <= 20, PolicyValidation.validTargets(domains: domains, apps: apps) else {
            backendActionMessage = "Enter a name and valid websites or apps."
            return nil
        }
        // Stored hours are the BLOCKED complement of the allowed window.
        let schedule = allowed.blockedSchedule(basedOn: DailySchedule(
            id: "schedule-\(UUID().uuidString)", title: title, domains: domains,
            startMinutes: 0, endMinutes: 1, isRequested: true, apps: apps))
        guard schedule.isValid else {
            backendActionMessage = "Choose different start and end times."
            return nil
        }
        updateCategories { $0.place([schedule.id], in: categoryID) }
        backendActionMessage = "Submitting schedule…"
        return submitFixture([.add(schedule)], generation: snapshot.generation, now: now)
    }

    /// An imported list as daily schedules with the same hours: one, or
    /// several when it's more than one rule holds. Like a new schedule it only
    /// adds blocking, so it applies at once in one request.
    func importSchedules(name: String, sites: [String], allowed: AllowedAccessWindow,
                         categoryID: String, now: Date = .now) -> UUID? {
        guard canSubmitPolicy, let snapshot = backendSnapshot else {
            backendActionMessage = "Shield's service isn't available. Nothing changed."
            return nil
        }
        let lists = WebsiteListImport.lists(sites)
        let title = ShieldCategoryLayout.cleanName(name)
        guard !title.isEmpty, !lists.isEmpty, lists.count <= WebsiteListImport.maximumLists,
              lists.allSatisfy({ PolicyValidation.validTargets(domains: $0, apps: []) }) else {
            backendActionMessage = "Enter a name and a list of valid websites."
            return nil
        }
        // Stored hours are the BLOCKED complement of the allowed window.
        let schedules = lists.enumerated().map { index, domains in
            allowed.blockedSchedule(basedOn: DailySchedule(
                id: "schedule-\(UUID().uuidString)",
                title: WebsiteListImport.title(title, part: index + 1, of: lists.count), domains: domains,
                startMinutes: 0, endMinutes: 1, isRequested: true))
        }
        guard schedules.allSatisfy(\.isValid) else {
            backendActionMessage = "Choose different start and end times."
            return nil
        }
        updateCategories { $0.place(schedules.map(\.id), in: categoryID) }
        backendActionMessage = "Submitting \(sites.count) websites…"
        return submitFixture(schedules.map { BackendCommand.add($0) }, generation: snapshot.generation, now: now)
    }

    /// An imported list blocked all day, as one or several rules: until turned
    /// off (New Block's kind) or permanent (Lock In Forever's kind, with the
    /// same 72-hour correction for mistakes). Both only add blocking, so they
    /// apply at once in one request.
    func importBlocks(name: String, sites: [String], permanent: Bool,
                      categoryID: String, now: Date = .now) -> UUID? {
        guard ShieldRuntime.allowsSimulatedPolicyChanges else {
            backendActionMessage = "UI review cannot change even simulated committed policy."
            return nil
        }
        guard canSubmitPolicy, let snapshot = backendSnapshot else {
            backendActionMessage = "Shield's service isn't available. Nothing changed."
            return nil
        }
        let lists = WebsiteListImport.lists(sites)
        let title = ShieldCategoryLayout.cleanName(name)
        guard !title.isEmpty, !lists.isEmpty, lists.count <= WebsiteListImport.maximumLists,
              lists.allSatisfy({ PolicyValidation.validTargets(domains: $0, apps: []) }) else {
            backendActionMessage = "Enter a name and a list of valid websites."
            return nil
        }
        // "focus-" keeps the 72-hour correction for Shield-made permanents.
        let rules = lists.enumerated().map { index, domains in
            DomainRestriction(owner: permanent ? .permanent : .commitment,
                              policyID: "focus-\(UUID().uuidString)",
                              title: WebsiteListImport.title(title, part: index + 1, of: lists.count),
                              domains: domains, startsAt: now)
        }
        // A big list split for the service still shows as one card.
        updateCategories {
            if rules.count > 1 { $0.combine(rules.map(\.policyID), name: title, in: categoryID) }
            else { $0.place(rules.map(\.policyID), in: categoryID) }
        }
        backendActionMessage = "Submitting \(sites.count) websites…"
        return submitFixture(rules.map { BackendCommand.add($0) }, generation: snapshot.generation, now: now)
    }

    /// More websites apply at once; fewer websites wait at least 24 hours.
    func changeScheduleSites(scheduleID: String, to domains: Set<String>, now: Date = .now) -> UUID? {
        guard canSubmitPolicy, let snapshot = backendSnapshot,
              let current = snapshot.committedSchedules.first(where: { $0.id == scheduleID }),
              snapshot.pendingReleases.allSatisfy({ $0.policyID != scheduleID }),
              !domains.isEmpty, domains.count <= PolicyValidation.maximumDomains,
              domains.allSatisfy(PolicyValidation.validDomain),
              domains != current.domains else {
            backendActionMessage = "Cannot change these websites until the service is ready and no change is pending."
            return nil
        }
        let replacement = DailySchedule(id: current.id, title: current.title, domains: domains,
                                        startMinutes: current.startMinutes, endMinutes: current.endMinutes,
                                        isRequested: true, apps: current.apps)
        let command: BackendCommand = replacement.isImmediateStrengthening(of: current)
            ? .strengthen(replacement) : .replace(replacement, at: now.addingTimeInterval(LockInPlan.releaseHeadroom))
        backendActionMessage = domains.isSuperset(of: current.domains)
            ? "Submitting added websites…" : "Submitting change. Removed websites stay on this schedule for at least 24 hours."
        return submitFixture([command], generation: snapshot.generation, now: now)
    }

    /// A download or import stopped by quitting can leave its private staging
    /// folder (which may hold a sign-in copy). Remove any older than an hour.
    private func sweepLeftoverStaging() {
        let temp = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: temp, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items where item.lastPathComponent.hasPrefix("ShieldStudy-") ||
            item.lastPathComponent.hasPrefix("ShieldImport-") {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (modified ?? .distantPast) < Date.now.addingTimeInterval(-3_600) {
                try? FileManager.default.removeItem(at: item)
            }
        }
    }

    /// Withdraws a pending release or looser-hours change. Keeping the
    /// current rules is never weaker, so the service applies it at once.
    func cancelPendingChange(_ policyID: String, now: Date = .now) -> UUID? {
        // A Lock In's end can't be cancelled: that would let it be removed early.
        guard !LockInPlan.isLockIn(policyID) else {
            backendActionMessage = "A Lock In can't be ended early."
            return nil
        }
        guard canSubmitPolicy, let snapshot = backendSnapshot,
              snapshot.pendingReleases.contains(where: { $0.policyID == policyID }) else {
            backendActionMessage = "That change is no longer pending."
            return nil
        }
        backendActionMessage = "Keeping the current rules…"
        return submitFixture([.cancelPending(policyID)], generation: snapshot.generation, now: now)
    }

    // MARK: - Places and location rules (docs/conditional-rules-blueprint.md)
    //
    // The app only senses and asks. The service judges every report, keeps
    // verdicts rather than coordinates, classifies each change (stricter now,
    // looser after 24 hours) and decides every block.

    // An older service can't decode place commands, so Places stays hidden
    // until the service says it supports them.
    var supportsLocationRules: Bool {
        !ShieldRuntime.isUIReview && isFixtureMode && backendSnapshot?.supportsPlaces == true
    }
    var locationPolicy: ConditionalPolicy { backendSnapshot?.conditions ?? .empty }

    func pendingLocationChange(place id: String) -> PendingPolicyRelease? {
        backendSnapshot?.pendingReleases.first { $0.policyID == ConditionalPolicy.pendingID(place: id) }
    }

    func pendingLocationChange(rule id: String) -> PendingPolicyRelease? {
        backendSnapshot?.pendingReleases.first { $0.policyID == ConditionalPolicy.pendingID(rule: id) }
    }

    /// The service records where this Mac is only while a block or rule uses
    /// a place (reports are otherwise acknowledged and dropped), so with none
    /// "unknown" means "not checked", not a failure.
    var checksWhereabouts: Bool {
        locationPolicy.usesPlaces || (backendSnapshot?.committedRestrictions ?? []).contains { $0.placeID != nil }
    }

    /// Ordinary blocks limited to this place.
    func blocksUsing(place id: String) -> Int {
        (backendSnapshot?.committedRestrictions ?? []).filter { $0.placeID == id }.count
    }

    // MARK: Permission screens (public release)

    /// A macOS permission Shield is about to ask for. Before macOS's own
    /// prompt, Shield says in one plain sentence why it wants it.
    enum PermissionAsk: String, Identifiable {
        case location, closingTabs
        var id: String { rawValue }
        var explainedKey: String { "Shield.PermissionExplained.\(rawValue)" }
    }

    /// The permission screen showing now, if any.
    var permissionAsk: PermissionAsk?
    @ObservationIgnored private var afterPermissionAsk: (() -> Void)?

    /// Turns Location on for something the person just asked for (Go There
    /// Today, a place rule), first explaining why when macOS hasn't asked yet.
    func requestLocation(then: (() -> Void)? = nil) {
        guard supportsLocationRules else { return }
        if LocationSensor.wasAnswered || locationSensor?.isRunning == true
            || UserDefaults.standard.bool(forKey: PermissionAsk.location.explainedKey) {
            turnOnLocation()
            then?()
            return
        }
        afterPermissionAsk = then
        permissionAsk = .location
    }

    /// Turns "Close blocked tabs" on, first explaining the browser prompt.
    func requestClosesBlockedTabs() {
        if UserDefaults.standard.bool(forKey: PermissionAsk.closingTabs.explainedKey) {
            setClosesBlockedTabs(true)
        } else {
            permissionAsk = .closingTabs
        }
    }

    /// Continue (true) or Not Now (false) on the permission screen.
    func answerPermissionAsk(_ proceed: Bool) {
        guard let ask = permissionAsk else { return }
        permissionAsk = nil
        let then = afterPermissionAsk
        afterPermissionAsk = nil
        guard proceed else { return }
        UserDefaults.standard.set(true, forKey: ask.explainedKey)
        switch ask {
        case .location:
            turnOnLocation()
            then?()
        case .closingTabs:
            setClosesBlockedTabs(true)
        }
    }

    /// Starts the sensor. The first time, macOS asks for Location access.
    func turnOnLocation() {
        guard supportsLocationRules else { return }
        #if DEBUG
        if Self.goDayTestStart { return }
        #endif
        if locationSensor == nil {
            let sensor = LocationSensor(keyURL: ShieldRuntime.supportDirectory.appendingPathComponent("location-tag.key"))
            sensor.onChange = { [weak self] in
                guard let self, self.reportPresenceIfDue(onChange: true) else { return }
                if self.fixtureBackend != nil { self.refresh() }
            }
            locationSensor = sensor
        }
        locationSensor?.start()
    }

    /// Sends what the sensor sees: on a change (at most every 10 s) and as a
    /// heartbeat about once a minute. The service keeps the verdict for 120 s,
    /// so a quit or asleep Shield leaves location unknown, which is strict.
    @discardableResult
    private func reportPresenceIfDue(now: Date = .now, onChange: Bool) -> Bool {
        // A Go day not yet reached reports every 20 s so arriving shows quickly.
        let awaitingArrival = goDayAwaitingArrival(now: now) || goDayPractice.map { now < $0.endsAt } == true
        // Less invasive: Location is used only while a rule
        // depends on a place or a Go day is waiting. A place saved for later
        // doesn't keep Shield checking where this Mac is.
        guard supportsLocationRules, checksWhereabouts || awaitingArrival else { return false }
        // Records expire 120 s after their fix; ask for a new one well before
        // (at most one restart every 30 s), not only when a report is due.
        if locationSensor?.isRunning == true { locationSensor?.keepFixFresh(now: now) }
        if let last = lastPresenceReport {
            let age = now.timeIntervalSince(last)
            let changed = onChange || presenceChangeWaiting
            guard age >= (awaitingArrival ? 20 : 55) || (changed && age >= 10) || age < 0 else {
                if onChange { presenceChangeWaiting = true }
                return false
            }
        }
        lastPresenceReport = now
        presenceChangeWaiting = false
        // Resume sensing on launch only if the user already answered the
        // Location prompt; otherwise wait for "Turn On Location" (strict meanwhile).
        if locationSensor?.isRunning != true {
            guard LocationSensor.wasAnswered else { return false }
            turnOnLocation()
        }
        guard let sensor = locationSensor, sensor.isRunning else { return false }
        if !onChange {
            sensor.scanWiFi()
            sensor.keepFixFresh(now: now)
        }
        let report = PresenceReportBuilder.report(sensor.takeEvidence(now: now))
        if let xpcClient {
            Task { [weak self] in
                do {
                    _ = try await Task.detached { try xpcClient.reportPresence(report) }.value
                    self?.locationReportProblem = nil
                } catch {
                    self?.locationReportProblem = error.localizedDescription
                }
            }
            return true
        }
        guard let fixtureBackend else { return false }
        if presenceSession == nil { presenceSession = PresenceSession() }
        do {
            _ = try fixtureBackend.reportPresence(report, session: presenceSession!, now: now, calendar: .current)
            locationReportProblem = nil
        } catch {
            locationReportProblem = error.localizedDescription
        }
        return true
    }

    // MARK: Go there today

    #if DEBUG
    nonisolated static var goDayTestStart: Bool { ProcessInfo.processInfo.environment["SHIELD_UI_TEST_GO_START"] == "1" }
    #endif

    var supportsGoDays: Bool { supportsLocationRules && backendSnapshot?.supportsGoDays == true }

    /// Today's Go day (running or reached), if any.
    func goDayToday(now: Date = .now) -> DomainRestriction? {
        let days = (backendSnapshot?.committedRestrictions ?? []).filter { $0.isGoDay && ($0.endsAt.map { now < $0 } ?? false) }
        // A second day started after arriving at the first is the one that matters.
        return days.first { $0.goDay?.arrivedAt == nil } ??
            days.max { ($0.startsAt ?? .distantPast) < ($1.startsAt ?? .distantPast) }
    }

    private func goDayAwaitingArrival(now: Date) -> Bool {
        goDayToday(now: now).map { $0.goDay?.arrivedAt == nil } ?? false
    }

    /// Where this Mac is now, as a Go day records it: a recent real fix and the
    /// Wi-Fi it can see. One of the two is needed to start.
    private func goDayStart(now: Date = .now) -> (fix: GoDayGate.StartFix?, tags: Set<String>) {
        #if DEBUG
        // Click-tests: a fixed start a few km from the seeded Library, without Core Location.
        if Self.goDayTestStart { return (.init(latitude: 40.7681, longitude: -73.9819, horizontalAccuracy: 30), []) }
        #endif
        guard let sensor = locationSensor, sensor.access == .allowed else { return (nil, []) }
        let fix = sensor.latestFix.flatMap { fix -> GoDayGate.StartFix? in
            guard !fix.isSimulated, fix.horizontalAccuracy > 0, fix.horizontalAccuracy <= 200,
                  now.timeIntervalSince(fix.observedAt) <= 120 else { return nil }
            return .init(latitude: fix.latitude, longitude: fix.longitude, horizontalAccuracy: fix.horizontalAccuracy)
        }
        let fresh = sensor.wifiCheckedAt.map { abs(now.timeIntervalSince($0)) <= 120 } ?? false
        let tags = fresh ? PresenceReportBuilder.enrollmentTags(connected: sensor.connectedTag, visible: sensor.visibleTags)
                         : []
        return (fix, tags)
    }

    var goDayStartReady: Bool {
        #if DEBUG
        if MarketingRender.isActive { return true }
        #endif
        let start = goDayStart()
        return start.fix != nil || start.tags.count >= 2
    }

    struct GoDayRefusal: Error, Equatable { let message: String }

    /// Today's Go day as the service will check it, from what the app knows
    /// now: the chosen places (copied, so editing them later changes nothing)
    /// and where this Mac is, which can never count as arriving.
    nonisolated static func makeGoDay(places chosen: [RulePlace], startFix: GoDayGate.StartFix?, startTags: Set<String>,
                          until: Date, apps: Set<AppTarget>, browsers: Bool = true, domains: Set<String> = [],
                          now: Date) -> Result<DomainRestriction, GoDayRefusal> {
        let places = chosen.filter { !$0.isHome }
        guard !places.isEmpty else { return .failure(.init(message: "Pick where you're going.")) }
        guard browsers || !apps.isEmpty || !domains.isEmpty else {
            return .failure(.init(message: "Pick something to block."))
        }
        guard startFix != nil || startTags.count >= 2 else {
            return .failure(.init(message: "Shield needs to see where you are now first. Check that Location and Wi-Fi are on."))
        }
        let startsAt = now.addingTimeInterval(GoDayGate.undoWindow)
        guard until.timeIntervalSince(startsAt) >= 600, until.timeIntervalSince(startsAt) <= GoDayGate.maximumLength else {
            return .failure(.init(message: "Pick an end time later today."))
        }
        let range = GoDayGate.radiusRange
        let gate = GoDayGate(places: places.map {
            .init(name: $0.name, latitude: $0.latitude, longitude: $0.longitude,
                  radiusMeters: min(max($0.radiusMeters, range.lowerBound), range.upperBound))
        }, startTags: startTags, startFix: startFix)
        if let here = gate.placesAtStart.first {
            return .failure(.init(message: "You're already at \(here.name), or too close to it."))
        }
        let names = ListFormatter.localizedString(byJoining: gate.places.map(\.name))
        let day = DomainRestriction(owner: .temporary, policyID: GoDayGate.policyPrefix + UUID().uuidString.prefix(8).lowercased(),
                                    title: String("Go to \(names)".prefix(160)),
                                    domains: WebsiteListParser.withWWW(domains), startsAt: startsAt, endsAt: until,
                                    apps: browsers ? apps.union([.webBrowsers]) : apps, goDay: gate)
        return day.isWellFormedGoDay ? .success(day) : .failure(.init(message: "That Go day can't be started."))
    }

    private func makeGoDay(placeIDs: Set<String>, until: Date, apps: Set<AppTarget>, browsers: Bool = true,
                           domains: Set<String> = [], now: Date) -> DomainRestriction? {
        let start = goDayStart(now: now)
        switch Self.makeGoDay(places: locationPolicy.places.filter { placeIDs.contains($0.id) },
                              startFix: start.fix, startTags: start.tags, until: until, apps: apps,
                              browsers: browsers, domains: domains, now: now) {
        case .success(let day): return day
        case .failure(let refusal):
            backendActionMessage = refusal.message
            return nil
        }
    }

    /// Starts today's Go day: browsers (and `apps`) close in 2 minutes and stay
    /// closed until the service sees this Mac arrive, or until `until`.
    func startGoDay(placeIDs: Set<String>, until: Date, apps: Set<AppTarget>, browsers: Bool = true,
                    domains: Set<String> = [], now: Date = .now) -> UUID? {
        guard canSubmitPolicy, supportsGoDays, let snapshot = backendSnapshot else {
            backendActionMessage = "Shield's service isn't available. Nothing changed."
            return nil
        }
        guard !goDayAwaitingArrival(now: now) else {
            backendActionMessage = "Today's Go day is already running."
            return nil
        }
        guard let day = makeGoDay(placeIDs: placeIDs, until: until, apps: apps, browsers: browsers,
                                  domains: domains, now: now) else { return nil }
        goDayPractice = nil
        backendActionMessage = "Starting your Go day…"
        return submitFixture([.add(day)], generation: snapshot.generation, now: now)
    }

    /// Withdraws today's Go day in its first 2 minutes. After that the service refuses.
    func undoGoDay(now: Date = .now) -> UUID? {
        guard let day = goDayToday(now: now), let startsAt = day.startsAt, now < startsAt,
              let snapshot = backendSnapshot, canSubmitPolicy else {
            backendActionMessage = "The 2 minutes to undo are over."
            return nil
        }
        backendActionMessage = "Undoing…"
        return submitFixture([.withdrawGoDay(day.policyID)], generation: snapshot.generation, now: now)
    }

    func startGoDayPractice(placeIDs: Set<String>, until: Date, now: Date = .now) -> Bool {
        guard let gate = makeGoDay(placeIDs: placeIDs, until: until, apps: [], now: now)?.goDay else { return false }
        goDayPractice = (gate, until)
        return true
    }

    func endGoDayPractice() { goDayPractice = nil }

    /// The one line shown on every page while a Go day (or practice) is on.
    func goDayLine(now: Date = .now) -> GoDayLine? {
        let time = { (date: Date) in date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: self.scheduleCalendar.timeZone)) }
        let names = { (gate: GoDayGate) in ListFormatter.localizedString(byJoining: gate.places.map(\.name)) }
        if let day = goDayToday(now: now), let gate = day.goDay, let endsAt = day.endsAt {
            if let arrived = gate.arrivedAt, arrived <= now {
                return GoDayLine(symbol: "checkmark.circle.fill", tone: .done,
                                 text: "You made it to \(names(gate)). Back to normal for today.")
            }
            if let startsAt = day.startsAt, now < startsAt {
                let seconds = Int(startsAt.timeIntervalSince(now).rounded(.up))
                return GoDayLine(symbol: "figure.walk", tone: .waiting,
                                 text: "Blocking starts in \(seconds / 60):\(String(format: "%02d", seconds % 60)).",
                                 canUndo: true)
            }
            let access = locationSensor?.access
            if access == .denied || access == .restricted || access == .approximateOnly {
                return GoDayLine(symbol: "location.slash", tone: .warning,
                                 text: "Location is off for Shield, so blocking lasts until \(time(endsAt)).")
            }
            if let tag = locationSensor?.connectedTag, gate.startTags.contains(tag) {
                return GoDayLine(symbol: "wifi.exclamationmark", tone: .warning,
                                 text: "Still on the Wi-Fi from when the day started (a phone hotspot?), so arriving can't count. Join the place's Wi-Fi.")
            }
            return GoDayLine(symbol: "figure.walk", tone: .waiting,
                             text: "Opens when you get to \(names(gate)), or at \(time(endsAt)).")
        }
        guard let practice = goDayPractice else { return nil }
        guard now < practice.endsAt else { return nil }
        let base = "Practice (nothing blocked)"
        guard let sensor = locationSensor, let fix = sensor.latestFix else {
            return GoDayLine(symbol: "location", tone: .practice, text: "\(base) · Finding where you are…", isPractice: true)
        }
        let evidence = PresenceReportBuilder.record(fix: fix, fullAccuracy: true, connectedTag: sensor.connectedTag,
                                                    visibleTags: sensor.visibleTags, sleptSinceLastReport: false, now: now).evidence
        if GoDayArrival.qualifies(evidence, gate: practice.gate, now: now) {
            return GoDayLine(symbol: "checkmark.circle", tone: .done,
                             text: "\(base) · You'd be let in here.", isPractice: true)
        }
        let accuracy = Int(fix.horizontalAccuracy.rounded())
        let away = evidence.fix.flatMap { GoDayArrival.nearest($0, gate: practice.gate) }.map { Measurement(value: $0.meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road)) + " from \($0.place.name)" } ?? ""
        return GoDayLine(symbol: "location", tone: .practice,
                         text: "\(base) · \(away) · ±\(accuracy) m", isPractice: true)
    }

    /// A place picked on the map: no Wi-Fi of its own (you haven't been there).
    /// The Location blocks category as the user styled it, for every Places screen.
    var locationCategory: ShieldCategory {
        categoryLayout.category(ShieldCategoryLayout.locationID) ?? .builtIn(.location)
    }

    /// Each place's own icon and colour. Presentation only:
    /// saved with this Mac's settings and never sent to the service.
    private(set) var placeStyles: [String: PlaceStyle] = PlaceStyle.loadAll()

    func placeStyle(_ place: RulePlace) -> PlaceStyle {
        placeStyles[place.id] ?? PlaceStyle(symbol: place.isHome ? "house.fill" : "mappin.and.ellipse",
                                            color: locationCategory.color)
    }

    /// Every saved place's look, by ID, for the maps.
    var placeLooks: [String: PlaceStyle] {
        Dictionary(uniqueKeysWithValues: locationPolicy.places.map { ($0.id, placeStyle($0)) })
    }

    func setPlaceStyle(_ style: PlaceStyle, for placeID: String) {
        guard PlaceStyle.symbols.contains(style.symbol) else { return }
        placeStyles[placeID] = style
        PlaceStyle.saveAll(placeStyles)
    }

    /// Why a place can't be added, in plain words.
    static func placeProblemText(_ problems: [RulePlaceValidator.Problem]) -> String {
        if problems.contains(.tooMany) { return "You can have at most \(RulePlaceValidator.maximumPlaces) places." }
        if problems.contains(.radius) { return "That place's area is too small or too large." }
        if problems.contains(.coordinates) { return "That spot on the map isn't valid." }
        if problems.contains(.unknownPlace) { return "A saved place block names a place that's gone. Nothing changed." }
        return "That place can't be added. Nothing changed."
    }

    func addMapPlace(name: String, latitude: Double, longitude: Double, radiusMeters: Double,
                     now: Date = .now) -> (request: UUID, placeID: String)? {
        guard canSubmitPolicy, let snapshot = backendSnapshot else {
            backendActionMessage = "Shield's service isn't available. Nothing changed."
            return nil
        }
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !title.isEmpty else {
            backendActionMessage = "Give the place a name."
            return nil
        }
        guard !nameTaken(title, except: nil) else {
            backendActionMessage = "You already have a place called \(title)."
            return nil
        }
        let policy = locationPolicy
        let place = RulePlace(id: "place-" + UUID().uuidString.prefix(8).lowercased(), name: title,
                              latitude: latitude, longitude: longitude, radiusMeters: radiusMeters, wifiTags: [])
        let problems = RulePlaceValidator.problems(places: policy.places + [place], rules: policy.rules)
        guard problems.allSatisfy({ $0 == .homeCount }) else {
            backendActionMessage = Self.placeProblemText(problems)
            return nil
        }
        backendActionMessage = "Adding \(title)…"
        guard let request = submitFixture([.add(place)], generation: snapshot.generation, now: now) else { return nil }
        return (request, place.id)
    }

    /// Enrolls the place the Mac is at now, with the Wi-Fi it can see.
    func addPlaceHere(name: String, radiusMeters: Double, isHome: Bool, now: Date = .now) -> (request: UUID, placeID: String)? {
        guard canSubmitPolicy, let snapshot = backendSnapshot else {
            backendActionMessage = "Shield's service isn't available. Nothing changed."
            return nil
        }
        guard let sensor = locationSensor, sensor.access == .allowed, let fix = sensor.latestFix,
              fix.goodForEnrollment(now: now) else {
            backendActionMessage = "Shield needs a precise reading of this Mac's location first."
            return nil
        }
        guard !sensor.hasTagKey || sensor.wifiCheckedAt.map({ abs(now.timeIntervalSince($0)) <= 60 }) == true else {
            sensor.scanWiFi()
            backendActionMessage = "Shield is still checking nearby Wi-Fi. Try again in a moment."
            return nil
        }
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let policy = locationPolicy
        guard !title.isEmpty else {
            backendActionMessage = "Give the place a name."
            return nil
        }
        guard !isHome || !policy.places.contains(where: \.isHome) else {
            backendActionMessage = "You already have a home place."
            return nil
        }
        guard !nameTaken(title, except: nil) else {
            backendActionMessage = "You already have a place called \(title)."
            return nil
        }
        let place = RulePlace(id: "place-" + UUID().uuidString.prefix(8).lowercased(), name: title,
                              latitude: fix.latitude, longitude: fix.longitude, radiusMeters: radiusMeters,
                              wifiTags: PresenceReportBuilder.enrollmentTags(connected: sensor.connectedTag,
                                                                             visible: sensor.visibleTags),
                              isHome: isHome)
        let problems = RulePlaceValidator.problems(places: policy.places + [place], rules: policy.rules)
        guard problems.allSatisfy({ $0 == .homeCount }) else {
            backendActionMessage = Self.placeProblemText(problems)
            return nil
        }
        backendActionMessage = "Adding \(title)…"
        guard let request = submitFixture([.add(place)], generation: snapshot.generation, now: now) else { return nil }
        return (request, place.id)
    }

    private func nameTaken(_ name: String, except id: String?) -> Bool {
        locationPolicy.places.contains { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Places a new block can use: saved, and not on their way out. By name.
    var availablePlaces: [RulePlace] {
        locationPolicy.places.filter { pendingLocationChange(place: $0.id) == nil }.sorted { $0.name < $1.name }
    }

    /// Renaming changes nothing about where the place is, so it applies at once.
    func renamePlace(_ id: String, to name: String, now: Date = .now) -> UUID? {
        let title = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard canSubmitPolicy, let snapshot = backendSnapshot,
              var place = locationPolicy.places.first(where: { $0.id == id }), pendingLocationChange(place: id) == nil else {
            backendActionMessage = "That place can't be renamed right now."
            return nil
        }
        guard !title.isEmpty else {
            backendActionMessage = "Give the place a name."
            return nil
        }
        guard title != place.name else { return nil }
        guard !nameTaken(title, except: id) else {
            backendActionMessage = "You already have a place called \(title)."
            return nil
        }
        place.name = title
        backendActionMessage = "Renaming…"
        return submitFixture([.replace(place)], generation: snapshot.generation, now: now)
    }

    /// Removing a place waits 24 hours: its rules pull both ways, so removal can loosen one.
    func removePlace(_ id: String, now: Date = .now) -> UUID? {
        let policy = locationPolicy
        guard canSubmitPolicy, let snapshot = backendSnapshot, policy.places.contains(where: { $0.id == id }),
              pendingLocationChange(place: id) == nil else {
            backendActionMessage = "That place can't be removed right now."
            return nil
        }
        guard blocksUsing(place: id) == 0, !policy.rules.contains(where: { $0.placeIDs.contains(id) }) else {
            backendActionMessage = "Release the blocks that use this place first."
            return nil
        }
        backendActionMessage = "Submitting. The place stays for at least 24 hours."
        return submitFixture([.removePlace(id, at: now.addingTimeInterval(LockInPlan.releaseHeadroom))], generation: snapshot.generation, now: now)
    }

    /// Ends a daily schedule no sooner than 24 hours from now.
    func removeSchedule(_ scheduleID: String, now: Date = .now) -> UUID? {
        guard canSubmitPolicy, let snapshot = backendSnapshot,
              snapshot.committedSchedules.contains(where: { $0.id == scheduleID }),
              snapshot.pendingReleases.allSatisfy({ $0.policyID != scheduleID }) else {
            backendActionMessage = "This schedule changed or a change is already pending."
            return nil
        }
        backendActionMessage = "Submitting removal. The schedule keeps blocking for at least 24 hours."
        return submitFixture([.release(scheduleID, at: now.addingTimeInterval(LockInPlan.releaseHeadroom))],
                             generation: snapshot.generation, now: now)
    }

    /// Whether deleting a category could also release any of its rules.
    func canReleaseRules(inCategory categoryID: String) -> Bool {
        guard let snapshot = backendSnapshot else { return false }
        return !releaseCommands(inCategory: categoryID, snapshot: snapshot, now: .now).isEmpty
    }

    /// Requests release of every rule in a category that can be released
    /// (not permanent or timed blocks), all in one request.
    func releaseRules(inCategory categoryID: String, now: Date = .now) -> UUID? {
        guard canSubmitPolicy, let snapshot = backendSnapshot else {
            backendActionMessage = "Shield's service isn't available. Nothing changed."
            return nil
        }
        let commands = releaseCommands(inCategory: categoryID, snapshot: snapshot, now: now)
        guard !commands.isEmpty else {
            backendActionMessage = "Nothing in this category can be released."
            return nil
        }
        backendActionMessage = "Submitting removal. These rules keep blocking for at least 24 hours."
        let requestID = submitFixture(commands, generation: snapshot.generation, now: now)
        // The category goes once the service confirms, even if its sheet was closed.
        if let requestID { categoryDeletions[requestID] = categoryID }
        return requestID
    }
    @ObservationIgnored private var categoryDeletions: [UUID: String] = [:]

    private func releaseCommands(inCategory categoryID: String, snapshot: BackendSnapshot,
                                 now: Date) -> [BackendCommand] {
        let releaseAt = now.addingTimeInterval(LockInPlan.releaseHeadroom)
        let pending = Set(snapshot.pendingReleases.map(\.policyID))
        var commands = [BackendCommand]()
        for schedule in snapshot.committedSchedules where !pending.contains(schedule.id) &&
            categoryLayout.categoryID(for: schedule.id, defaultKind: ShieldGrouping.kind(for: schedule)) == categoryID {
            commands.append(.release(schedule.id, at: releaseAt))
        }
        for rule in snapshot.committedRestrictions where
            categoryLayout.categoryID(for: rule.policyID, defaultKind: ShieldGrouping.kind(for: rule)) == categoryID {
            switch siteRemoval(for: rule, now: now) {
            // Permanent blocks stay, even recent ones: undoing a mistake is
            // only ever "Fix a Mistake…", never a side effect of deleting a category.
            case .afterDelay: commands.append(.release(rule.policyID, at: releaseAt))
            case .correction, .afterPermanentWait, .unavailable: break
            }
        }
        return commands
    }


    @discardableResult
    func changeConfirmedHours(scheduleID: String, start: Int, end: Int, now: Date = .now) -> UUID? {
        guard canSubmitPolicy, let snapshot = backendSnapshot,
              let current = snapshot.committedSchedules.first(where: { $0.id == scheduleID }),
              snapshot.pendingReleases.allSatisfy({ $0.policyID != scheduleID }),
              (0..<1440).contains(start), (0..<1440).contains(end), start != end else {
            backendActionMessage = "Cannot change these hours until service evidence is ready and no change is pending."
            return nil
        }
        let replacement = current.withHours(start: start, end: end, isRequested: true)
        guard replacement != current else {
            backendActionMessage = "These are already the confirmed hours."
            return nil
        }
        let command: BackendCommand = replacement.isImmediateStrengthening(of: current)
            ? .strengthen(replacement) : .replace(replacement, at: now.addingTimeInterval(LockInPlan.releaseHeadroom))
        backendActionMessage = "Sending new hours. More allowed time waits 24 hours; less applies right away."
        return submitFixture([command], generation: snapshot.generation, now: now)
    }

    func requestFixtureRelease(policyID: String, now: Date = .now) {
        guard ShieldRuntime.allowsSimulatedPolicyChanges else {
            backendActionMessage = "UI review cannot release committed policy."
            return
        }
        guard isFixtureMode, let snapshot = backendSnapshot,
              (snapshot.committedRestrictions.contains(where: {
                  $0.policyID == policyID && $0.owner == .commitment && $0.endsAt == nil
              }) || snapshot.committedSchedules.contains(where: { $0.id == policyID })),
              !snapshot.pendingReleases.contains(where: { $0.policyID == policyID }) else {
            backendActionMessage = "This commitment cannot be released by request."
            return
        }
        // The service evaluates the minimum delay against its own receive
        // time. Leave headroom for XPC transit and clock skew so a legitimate
        // request is not rejected for arriving milliseconds after creation.
        submitFixture([.release(policyID, at: now.addingTimeInterval(LockInPlan.releaseHeadroom))],
                      generation: snapshot.generation, now: now)
    }

    /// Removes a 1.1 permanent block after the removal wait (with headroom).
    func requestPermanentRemoval(policyID: String, now: Date = .now) {
        guard ShieldRuntime.allowsSimulatedPolicyChanges else {
            backendActionMessage = "UI review cannot release committed policy."
            return
        }
        guard isFixtureMode, let snapshot = backendSnapshot,
              let rule = snapshot.committedRestrictions.first(where: { $0.policyID == policyID }),
              case .afterPermanentWait(let wait) = siteRemoval(for: rule, now: now) else {
            backendActionMessage = "This block can't be removed."
            return
        }
        submitFixture([.release(policyID, at: now.addingTimeInterval(wait + 300))],
                      generation: snapshot.generation, now: now)
    }

    /// Ends every list of a combined card after 24 hours, in one request:
    /// all of them, or none. Only "until removed" lists can be released.
    func requestFixtureRelease(policyIDs: [String], now: Date = .now) {
        guard policyIDs.count > 1 else {
            if let only = policyIDs.first { requestFixtureRelease(policyID: only, now: now) }
            return
        }
        guard ShieldRuntime.allowsSimulatedPolicyChanges else {
            backendActionMessage = "UI review cannot release committed policy."
            return
        }
        guard isFixtureMode, let snapshot = backendSnapshot,
              policyIDs.allSatisfy({ id in
                  snapshot.committedRestrictions.contains { $0.policyID == id && $0.owner == .commitment && $0.endsAt == nil } &&
                      !snapshot.pendingReleases.contains { $0.policyID == id }
              }) else {
            backendActionMessage = "These blocks cannot be released by request."
            return
        }
        let at = now.addingTimeInterval(LockInPlan.releaseHeadroom)
        submitFixture(policyIDs.map { .release($0, at: at) }, generation: snapshot.generation, now: now)
    }

    @discardableResult
    private func submitFixture(_ commands: [BackendCommand], generation: UInt64,
                               now: Date) -> UUID? {
        guard !submissionInFlight, pendingSubmission == nil, submissionRecordError == nil else { return nil }
        let request = BackendRequest(version: BackendRequest.schemaVersion, id: UUID(),
                                     expectedGeneration: generation, submittedAt: now,
                                     commands: commands)
        pendingSubmission = PendingPolicySubmission(version: 1, request: request, before: backendSnapshot)
        if xpcClient != nil {
            do { try submissionStore.save(pendingSubmission!) }
            catch {
                pendingSubmission = nil
                submissionState = .failed(request.id)
                backendActionMessage = "Request was not sent: \(error.localizedDescription)"
                return request.id
            }
        }
        sendPendingSubmission(now: now)
        return request.id
    }

    @ObservationIgnored private var rebasedRequests: Set<UUID> = []

    private func resendAgainstCurrentState(_ request: BackendRequest, xpcClient: FixtureBackendXPCClient) {
        Task { [weak self] in
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) { try xpcClient.snapshot() }.value
                guard let self else { return }
                try self.acceptBackendSnapshot(snapshot, now: .now)
                guard self.pendingSubmission?.request.id == request.id else { return }
                let rebased = BackendRequest(version: request.version, id: request.id,
                                             expectedGeneration: snapshot.generation, submittedAt: .now,
                                             commands: request.commands)
                var pending = PendingPolicySubmission(version: 1, request: rebased)
                pending.keptSchedules = self.pendingSubmission?.keptSchedules
                pending.keptPlaces = self.pendingSubmission?.keptPlaces
                try self.submissionStore.save(pending)
                self.pendingSubmission = pending
                self.sendPendingSubmission(now: .now)
            } catch {
                guard let self else { return }
                self.closeRefusedRequest(request.id)
                self.backendActionMessage = "Shield's rules changed while sending, so nothing was applied. Try again."
            }
        }
    }

    /// Clears a request the service refused. If its local record can't be
    /// removed, keep it so a relaunch can't mistake it for a lost change.
    private func closeRefusedRequest(_ id: UUID) {
        do {
            try submissionStore.remove()
            pendingSubmission = nil
        } catch {
            submissionRecordError = "The refused request's record couldn't be cleared."
        }
        submissionState = .failed(id)
    }

    /// Replies that prove the service refused a request before changing anything.
    nonisolated static func isDefinitiveRejection(_ message: String) -> Bool {
        message.contains("generation does not match") || message.contains("Invalid backend request")
    }

    /// The service refuses requests older than five minutes.
    var canRetryPendingSubmission: Bool {
        guard let pending = pendingSubmission, !submissionInFlight else { return false }
        return Date.now.timeIntervalSince(pending.request.submittedAt) < 290
    }

    func retryPendingSubmission() {
        guard !submissionInFlight, let pending = pendingSubmission else { return }
        guard canRetryPendingSubmission else {
            if let snapshot = backendSnapshot, pending.isConfirmed(by: snapshot) {
                resolvePendingSubmission(with: snapshot)
            } else {
                backendActionMessage = "This request is too old to resend. Check Protection, then make the change again."
            }
            return
        }
        sendPendingSubmission(now: .now)
    }

    func archiveUnreadableSubmission() {
        guard submissionRecordError != nil, backendSnapshot != nil, !submissionInFlight else { return }
        do {
            // Preserve the bytes for diagnosis; this action never edits authority.
            try submissionStore.archiveUnreadable()
            submissionRecordError = nil
            backendActionMessage = "Unreadable local request archived. Review confirmed commitments before submitting again."
        } catch { backendActionMessage = "Could not archive the local request: \(error.localizedDescription)" }
    }

    // Explicitly dismiss only the local unresolved intent after reviewing live
    // authority. This never withdraws a request, releases policy, or edits root state.
    func finishReviewingSubmission() {
        guard !submissionInFlight, backendSnapshot != nil, pendingSubmission != nil else { return }
        do {
            if xpcClient != nil { try submissionStore.remove() }
            pendingSubmission = nil
            submissionState = .idle
            backendActionMessage = "Request review closed. Confirmed commitments remain unchanged."
        } catch { backendActionMessage = "Could not close request review: \(error.localizedDescription)" }
    }

    private func resolvePendingSubmission(with snapshot: BackendSnapshot) {
        guard let pending = pendingSubmission, pending.isConfirmed(by: snapshot) else { return }
        do { if xpcClient != nil { try submissionStore.remove() } }
        catch {
            submissionState = .unconfirmed(pending.request.id)
            backendActionMessage = "The service confirmed the request, but its local record could not be cleared. Refresh to retry."
            return
        }
        pendingSubmission = nil
        if let categoryID = categoryDeletions.removeValue(forKey: pending.request.id) { deleteCategory(categoryID) }
        submissionState = .confirmed(pending.request.id)
        backendActionMessage = isServiceMode ? "Changes confirmed by the service." : "Preview updated. These changes do not protect this Mac."
    }

    private func sendPendingSubmission(now: Date) {
        guard let pending = pendingSubmission else { return }
        let request = pending.request
        submissionState = .submitting(request.id)
        if let xpcClient {
            guard !submissionInFlight else {
                backendActionMessage = "A request is already being sent."
                return
            }
            submissionInFlight = true
            if backendActionMessage == nil { backendActionMessage = "Sending to Shield…" }
            refreshSequence &+= 1
            let sequence = refreshSequence
            Task { [weak self] in
                do {
                    let (acknowledgment, snapshot) = try await Task.detached(priority: .userInitiated) {
                        let acknowledgment = try xpcClient.submit(request)
                        let snapshot = try xpcClient.snapshot()
                        return (acknowledgment, snapshot)
                    }.value
                    guard let self else { return }
                    self.submissionInFlight = false
                    guard self.refreshSequence == sequence else { return }
                    guard snapshot.generation >= acknowledgment.receipt.payload.generation else {
                        throw FixtureBackendError.invalidReceipt
                    }
                    try self.acceptBackendSnapshot(snapshot, now: .now)
                    let hosts: String
                    switch snapshot.enforcementSource {
                    case .installedSystemHosts:
                        hosts = "Installed system hosts reconciled"
                    case .disposableSystemHosts:
                        hosts = "Disposable system hosts reconciled"
                    case .fixtureHosts:
                        hosts = "Fixture hosts reconciled"
                    }
                    if self.submissionState == .confirmed(request.id) {
                        self.backendActionMessage = "Changes confirmed by the service. \(hosts)."
                    } else if self.pendingSubmission != nil {
                        self.submissionState = .unconfirmed(request.id)
                    }
                } catch {
                    guard let self else { return }
                    self.submissionInFlight = false
                    guard self.refreshSequence == sequence else { return }
                    // The service validates a request before committing anything, so
                    // these replies mean nothing changed. Close the request instead of
                    // offering a retry that can never succeed.
                    let message = error.localizedDescription
                    // The service's once-a-minute upkeep moves its generation, so a
                    // change can arrive one step late. Nothing was applied: resend the
                    // same request once against the current state (same ID, so an open
                    // editor still sees its result). The service checks it again.
                    if message.contains("generation does not match"), !self.rebasedRequests.contains(request.id) {
                        self.rebasedRequests.insert(request.id)
                        self.resendAgainstCurrentState(request, xpcClient: xpcClient)
                        return
                    }
                    if Self.isDefinitiveRejection(message) {
                        self.closeRefusedRequest(request.id)
                        if let range = message.range(of: "Invalid backend request: ") {
                            self.backendActionMessage = "Shield didn't accept this change: " + message[range.upperBound...]
                        } else {
                            self.backendActionMessage = "Shield's rules changed while sending, so nothing was applied. Try again."
                        }
                        self.refresh()
                        return
                    }
                    self.submissionState = .unconfirmed(request.id)
                    // The request stays pending (no second send is possible), and a
                    // brief no-reply keeps the page while Shield is asked again.
                    self.handleRefreshFailure(error, now: .now)
                    self.backendActionMessage = "No reply from Shield. Check the request before sending it again."
                }
            }
            return
        }
        guard let backend = fixtureBackend else { return }
        do {
            _ = try backend.apply(request, now: now, calendar: .current)
            refresh(now: now)
            if let snapshot = backendSnapshot { resolvePendingSubmission(with: snapshot) }
            backendActionMessage = "Preview updated. These changes do not protect this Mac."
        } catch {
            pendingSubmission = nil
            submissionState = .failed(request.id)
            backendActionMessage = "Fixture request rejected: \(error.localizedDescription)"
            refresh(now: now)
        }
    }

    func refresh(now: Date = .now) {
        reportPresenceIfDue(now: now, onChange: false)
        if let xpcClient {
            guard !submissionInFlight else { return }
            // A refresh still waiting for its reply isn't superseded (that used
            // to drop every reply slower than 5 s); one stuck for 30 s is.
            if let started = refreshStartedAt, now.timeIntervalSince(started) < 30, now >= started { return }
            refreshStartedAt = now
            refreshSequence &+= 1
            let sequence = refreshSequence
            Task { [weak self] in
                do {
                    // The window is waiting on this answer; macOS passes the
                    // priority on to the service while it handles the call.
                    let snapshot = try await Task.detached(priority: .userInitiated) {
                        _ = try xpcClient.tick()
                        return try xpcClient.snapshot()
                    }.value
                    // Cleared even when a submission superseded this reply.
                    if self?.refreshStartedAt == now { self?.refreshStartedAt = nil }
                    guard let self, self.refreshSequence == sequence else { return }
                    try self.acceptBackendSnapshot(snapshot, now: .now)
                    self.lastAnsweredAt = .now
                    if self.isReconnecting { self.isReconnecting = false }
                } catch {
                    if self?.refreshStartedAt == now { self?.refreshStartedAt = nil }
                    guard let self, self.refreshSequence == sequence else { return }
                    self.handleRefreshFailure(error, now: .now)
                }
            }
            return
        }
        if let fixtureBackend {
            do {
                _ = try fixtureBackend.tick(now: now, calendar: .current)
                let snapshot = try fixtureBackend.snapshot(now: now, calendar: .current)
                try acceptBackendSnapshot(snapshot, now: now)
                #if DEBUG
                previewAppEnforcer?.enforce(snapshot.authority.effectiveRestrictions.flatMap(\.apps))
                #endif
            } catch {
                backendSnapshot = nil
                fixtureReceipt = nil
                fixtureReceiptError = error.localizedDescription
            }
        }
        updateHealth(now: now)
    }

    func acceptBackendSnapshot(_ snapshot: BackendSnapshot, now: Date) throws {
        guard snapshot.generation >= max(highestObservedGeneration, backendSnapshot?.generation ?? 0) else {
            rejectBackendSnapshot(FixtureBackendError.uncertain("The service returned a stale generation."), now: now)
            throw FixtureBackendError.uncertain("The service returned a stale generation.")
        }
        if Self.pollNeedsRedraw(shown: backendSnapshot, incoming: snapshot, shownAt: snapshotShownAt, now: now) {
            backendSnapshot = snapshot
            snapshotShownAt = now
        } else {
            latestSnapshot = snapshot
        }
        if highestObservedGeneration != snapshot.generation { highestObservedGeneration = snapshot.generation }
        if fixtureReceipt != snapshot.receipt { fixtureReceipt = snapshot.receipt }
        if fixtureReceiptError != nil { fixtureReceiptError = nil }
        updateHealth(now: now)
        resolvePendingSubmission(with: snapshot)
        // Between changes the 5 s polls carry fresh evidence only, so this
        // bookkeeping waits for a new generation or a window opening/closing.
        let key = BookkeepingKey(snapshot)
        guard bookkept != key else { return }
        bookkept = key
        observeBrowserPolicy(snapshot, now: now)
    }

    // MARK: Reopen Chrome

    private func observeBrowserPolicy(_ snapshot: BackendSnapshot, now: Date) {
        guard snapshot.supportsBrowserPolicy else { return }
        // The same list the service gives the hosts file and the browsers.
        let blocked = snapshot.authority.effectiveRestrictions.reduce(into: Set<String>()) { $0.formUnion($1.domains) }
        let previous = browserReopen.lastBlocked
        var next = browserReopen
        next.observe(blocked: blocked, now: now)
        next.prune(earliestLaunch: PolicyBrowsers.running().compactMap(\.launchDate).min())
        saveBrowserReopen(next)
        if let previous, closesBlockedTabs, isServiceMode, !ShieldRuntime.isUIReview {
            let newlyBlocked = blocked.subtracting(previous)
            if !newlyBlocked.isEmpty { closeBlockedTabs(newlyBlocked) }
        }
    }

    func setClosesBlockedTabs(_ on: Bool) {
        closesBlockedTabs = on
        UserDefaults.standard.set(on, forKey: Self.closesBlockedTabsKey)
        if !on { tabClosingProblem = nil; tabClosingNeedsPermission = false }
    }

    func clearClosedTabs() {
        closedTabs = []
        UserDefaults.standard.removeObject(forKey: Self.closedTabsKey)
    }

    /// Closes tabs on sites that just became blocked, now and once more after
    /// 75 s (a page opened in the meantime from a remembered address).
    private func closeBlockedTabs(_ newlyBlocked: Set<String>, again: Bool = true) {
        let browsers = BlockedTabCloser.runningBrowsers()
        if !browsers.isEmpty {
            Task { @MainActor in
                var closed: [BlockedTabCloser.ClosedTab] = []
                var notAllowed: [String] = [], failed: [String] = []
                for browser in browsers {
                    let result = await BlockedTabCloser.closeTabs(bundleID: browser.bundleID, newlyBlocked: newlyBlocked)
                    closed += result.closed.map { .init(url: $0.url, browser: browser.name, closedAt: .now) }
                    switch result.failure {
                    case .notAllowed: notAllowed.append(browser.name)
                    case .failed: failed.append(browser.name)
                    case nil: break
                    }
                }
                finishClosingTabs(newlyBlocked, closed: closed, notAllowed: notAllowed, failed: failed,
                                  firstPass: again)
            }
        }
        guard again else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(75))
            guard let self, self.closesBlockedTabs else { return }
            let still = newlyBlocked.intersection(self.browserReopen.lastBlocked ?? [])
            if !still.isEmpty { self.closeBlockedTabs(still, again: false) }
        }
    }

    private func finishClosingTabs(_ checked: Set<String>, closed: [BlockedTabCloser.ClosedTab],
                                   notAllowed: [String], failed: [String], firstPass: Bool) {
        if !closed.isEmpty {
            let recent = (closed + closedTabs).filter { $0.closedAt > Date.now.addingTimeInterval(-86_400) }
            closedTabs = Array(recent.prefix(100))
            if let data = try? JSONEncoder().encode(closedTabs) { UserDefaults.standard.set(data, forKey: Self.closedTabsKey) }
            backendActionMessage = "Closed \(closed.count) tab\(closed.count == 1 ? "" : "s") on newly blocked sites. "
                + "They're listed in Settings."
        }
        var problems: [String] = []
        if !notAllowed.isEmpty {
            problems.append("macOS hasn't let Shield control \(LockInPlan.listed(notAllowed)). Allow it in System "
                            + "Settings → Privacy & Security → Automation → Shield.")
        }
        if !failed.isEmpty { problems.append("Shield couldn't check the tabs in \(LockInPlan.listed(failed)).") }
        // The 75 s second look never erases a problem the first one found.
        if !problems.isEmpty || firstPass {
            tabClosingProblem = problems.isEmpty ? nil : problems.joined(separator: " ")
            tabClosingNeedsPermission = !notAllowed.isEmpty
        }
        // Every open policy browser was checked: nothing left to reopen for these blocks.
        let everyBrowserChecked = PolicyBrowsers.running().allSatisfy {
            $0.bundleIdentifier.map { BlockedTabCloser.scriptableBrowsers[$0] != nil } ?? false
        }
        if problems.isEmpty && everyBrowserChecked {
            var next = browserReopen
            next.markHandled(checked)
            saveBrowserReopen(next)
        }
    }

    private func saveBrowserReopen(_ next: BrowserReopenAdvisor) {
        guard next != browserReopen else { return }
        browserReopen = next
        if let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: Self.browserReopenKey) }
    }

    /// What the Reopen notice says, and which browsers it reopens; nil when
    /// no running browser is behind on a site that opened.
    ///
    /// Only for sites that OPENED: a block reaches the browser
    /// that's already open, and asking someone to reopen their browser to be
    /// blocked defeats the point of Shield. Newly blocked sites are still
    /// tracked (`blockedSince`), for "Close blocked tabs".
    func browserReopenAdvice() -> (headline: String, browserName: String, apps: [NSRunningApplication],
                                   opened: Bool, blocked: Bool)? {
        guard backendSnapshot?.supportsBrowserPolicy == true else { return nil }
        let behind = PolicyBrowsers.running().filter { app in
            guard let launched = app.launchDate else { return false }
            return !browserReopen.openedSince(launch: launched).isEmpty
        }
        guard let first = behind.first, let launched = behind.compactMap(\.launchDate).min() else { return nil }
        // Named by category, in the order Protection shows them.
        let categories = ShieldRulePresentation(model: self).groups.map { ($0.title, $0.domains) }
        let opened = BrowserReopenAdvisor.names(for: browserReopen.openedSince(launch: launched), categories: categories)
        let browserName = behind.count == 1 ? (first.localizedName ?? "your browser") : "your browsers"
        return (BrowserReopenAdvisor.headline(opened), browserName, behind, true, false)
    }

    func dismissBrowserReopen(now: Date = .now) {
        var next = browserReopen
        next.dismissedAt = now
        saveBrowserReopen(next)
    }

    /// A missed reply keeps the last verified rules for a short while and
    /// asks again soon. A receipt or generation problem is never ridden out:
    /// those reject at once, as before.
    private func handleRefreshFailure(_ error: Error, now: Date) {
        if Self.ridesOut(error, hasSnapshot: backendSnapshot != nil, lastAnswered: lastAnsweredAt, now: now) {
            if !isReconnecting { isReconnecting = true }
            updateHealth(now: now)
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
            return
        }
        isReconnecting = false
        rejectBackendSnapshot(error, now: now)
    }

    /// Only a transport problem (no reply, a timeout, a dropped connection)
    /// within the grace period after a verified answer is ridden out.
    nonisolated static func ridesOut(_ error: Error, hasSnapshot: Bool, lastAnswered: Date?, now: Date) -> Bool {
        guard hasSnapshot, let lastAnswered, now >= lastAnswered,
              now.timeIntervalSince(lastAnswered) < connectionGrace,
              case FixtureBackendError.uncertain(let detail) = error else { return false }
        // A reply the service did send (an error about its state, a stale
        // generation) is never ridden out. Everything else is the connection
        // itself: the client's timeout, or macOS's interrupted-connection
        // error, which is worded in the Mac's own language.
        return !serviceReported.contains { detail.localizedCaseInsensitiveContains($0) }
    }

    /// How the service words its own errors (FixtureBackendError, always English).
    nonisolated static let serviceReported = [
        "Backend state is uncertain",
        "Invalid backend request",
        "generation does not match",
        "could not be authenticated",
        "accepts only an existing",
        "stale generation",
        "fixture-only interruption",
    ]

    private func rejectBackendSnapshot(_ error: Error, now: Date) {
        backendSnapshot = nil
        fixtureReceipt = nil
        fixtureReceiptError = error.localizedDescription
        updateHealth(now: now)
    }

    /// The last comparison of the blocked sites against hosts. Polls between
    /// changes carry the same lists (the same values), so with tens of
    /// thousands of sites this is reused instead of rebuilt every 5 s.
    /// Equal inputs always give the same result, so reuse can't hide a change.
    @ObservationIgnored private var lastHostsComparison: (expected: [DomainRestriction], observed: Set<String>,
                                                          missing: Set<String>, unexpected: Set<String>)?

    private func hostsComparison(expected restrictions: [DomainRestriction],
                                 observed: Set<String>) -> (missing: Set<String>, unexpected: Set<String>) {
        if let last = lastHostsComparison, last.expected == restrictions, last.observed == observed {
            return (last.missing, last.unexpected)
        }
        let expected = restrictions.reduce(into: Set<String>()) {
            $0.formUnion($1.domains.map { $0.lowercased() })
        }
        let missing = expected.subtracting(observed)
        let unexpected = observed.subtracting(expected)
        lastHostsComparison = (restrictions, observed, missing, unexpected)
        return (missing, unexpected)
    }

    private func updateHealth(now: Date) {
        // In fixture mode, only the backend snapshot carries a verified receipt.
        // A separately readable authority file must not keep the UI looking
        // healthy after receipt verification or journal recovery fails.
        let authority: AuthorityStatus
        if isFixtureMode {
            if let latestSnapshot {
                authority = .valid(latestSnapshot.authority)
            } else {
                authority = .unavailable(.unreadable(
                    fixtureReceiptError ?? "No authenticated fixture snapshot is available."))
            }
        } else {
            authority = authorityReader.read(now: now)
        }
        let enforcement: EvidenceState

        let observed: Result<EnforcementSnapshot, Error> = isFixtureMode
            ? latestSnapshot.map { .success($0.enforcement) } ??
                .failure(FixtureBackendError.uncertain("No service hosts evidence is available."))
            : enforcementReader.read()
        switch (authority, observed) {
        case (.valid(let state), .success(let snapshot)):
            let (missing, unexpected) = hostsComparison(expected: state.effectiveRestrictions,
                                                        observed: snapshot.blockedDomains)
            if abs(now.timeIntervalSince(snapshot.observedAt)) > ShieldEvidence.maximumAge {
                enforcement = .unavailable("Hosts observation is stale.")
            } else if !snapshot.managedSectionPresent {
                enforcement = .mismatch("Kairos managed hosts section is missing or incomplete.")
            } else if !missing.isEmpty {
                enforcement = .mismatch(
                    "Expected domains are absent from hosts: \(missing.sorted().joined(separator: ", "))."
                )
            } else if !unexpected.isEmpty {
                enforcement = .mismatch("Managed hosts has domains absent from authority: \(unexpected.sorted().joined(separator: ", ")).")
            } else {
                enforcement = .verified
            }
        case (.unavailable(let error), _):
            enforcement = .unavailable(
                "Enforcement cannot be verified without valid authority: \(error.localizedDescription)"
            )
        case (_, .failure(let error)):
            enforcement = .unavailable("Hosts enforcement is unreadable: \(error.localizedDescription)")
        }

        // Same health every 5 s is the norm: only a change redraws the window.
        let inspected = installationInspector.inspect(authority: authority, enforcement: enforcement)
        if inspected != health { health = inspected }
        lastRefresh = now
        if isDownloading, let reason = studyFetchBlockReason {
            cancelDownloads()
            studyMessage = "Download cancelled because protection changed: \(reason)"
        }
    }

    var diagnosticReport: String {
        let authority = authorityState.map {
            "schema=\($0.schemaVersion) generation=\($0.generation) reconciled=\($0.lastSuccessfulReconciliation.formatted(.iso8601))"
        } ?? "authority=unavailable"
        let hosts: String
        switch health.enforcement {
        case .verified: hosts = "hosts=consistent"
        case .mismatch: hosts = "hosts=mismatch"
        case .unavailable: hosts = "hosts=unavailable"
        }
        let receipt = fixtureReceipt.map { "receipt-generation=\($0.payload.generation)" }
            ?? "receipt=unavailable"
        let fixture = backendSnapshot.map {
            "owners=\($0.committedRestrictions.count) schedules=\($0.committedSchedules.count) pending=\($0.pendingReleases.count)"
        } ?? "fixture-snapshot=unavailable"
        let mode: String
        if ShieldRuntime.isUIReview {
            mode = "mode=ui-review authority=simulated downloads=disabled imports=disabled"
        } else if ShieldRuntime.isDevelopment {
            let authoritySource: String
            if isServiceMode {
                authoritySource = backendSnapshot == nil
                    ? "xpc-service-unavailable" : "xpc-service"
            } else {
                authoritySource = "in-process-fixture"
            }
            mode = "mode=development authority=\(authoritySource)"
        } else {
            mode = "mode=production"
        }
        let source = "enforcement-source=\(backendSnapshot?.enforcementSource.rawValue ?? "unavailable")"
        // Only fixed labels, counts and service timestamps leave this model.
        // Error descriptions may contain private paths, domains or OS metadata.
        return ["Shield diagnostic report (private details omitted)", mode, authority, hosts, receipt, fixture, source,
                "reconciler-present=\(health.reconcilerPresent)",
                "scheduler-definition-present=\(health.schedulerDefinitionPresent)"].joined(separator: "\n")
    }

    func importStudyManifest(from url: URL) {
        do {
            guard !ShieldRuntime.isUIReview else {
                studyMessage = "UI Review cannot import files."
                return
            }
            guard !isDownloading, !isRestoringStudy else {
                studyMessage = "Wait for the current download or check to finish."
                return
            }
            openStudyManifest(try readManifestFile(url), approved: false)
        } catch {
            studyMessage = error.localizedDescription
        }
    }

    /// Adds a collection file's videos to the library as a new collection.
    func importCollectionFile(from url: URL) {
        guard !ShieldRuntime.isUIReview else {
            queueNotice = "UI Review cannot import files."
            return
        }
        do { addCourseToLibrary(try readManifestFile(url), symbol: "folder.fill", color: .teal) }
        catch { queueProblem("That file couldn't be imported.") }
    }

    private func readManifestFile(_ url: URL) throws -> StudyManifest {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard url.isFileURL else { throw StudyDownloadError.unsafePath }
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw StudyDownloadError.unsafePath }
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  info.st_size > 0, info.st_size <= 1_048_576 else {
                throw StudyDownloadError.invalidManifest("Manifest is empty, oversized, or not a regular file.")
            }
            let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                .read(upToCount: 1_048_577) ?? Data()
            guard data.count <= 1_048_576 else {
                throw StudyDownloadError.invalidManifest("Manifest exceeds 1 MiB.")
            }
            var manifest = try JSONDecoder().decode(StudyManifest.self, from: data)
            // Imported metadata cannot claim ownership of the app's link queue.
            manifest.origin = nil
            return try manifest.validated()
    }

    func reportStudyError(_ error: Error) {
        if (error as NSError).code != NSUserCancelledError {
            studyMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func openStudyManifest(_ manifest: StudyManifest, approved: Bool, replacingQueue: Bool = false) {
        do {
            guard !isDownloading, !isRestoringStudy else {
                studyMessage = "Wait for the current download or check to finish."
                return
            }
            let store = StudyLibraryStore(root: libraryDirectory(for: manifest))
            let previous: StudyLibrarySnapshot?
            do {
                previous = try store.load()
                pendingLibraryRecovery = nil
            } catch {
                pendingLibraryRecovery = manifest
                throw error
            }
            let ids = Set(manifest.videos.map(\.id))
            guard previous == nil || (previous?.manifest.courseTitle == manifest.courseTitle &&
                                      (previous?.manifest.videos == manifest.videos ||
                                       (replacingQueue && (previous?.completedIDs ?? []).isSubset(of: ids)))) else {
                throw StudyDownloadError.invalidManifest("A different manifest already owns this course directory.")
            }
            try store.save(StudyLibrarySnapshot(version: 1, manifest: manifest,
                completedIDs: previous?.completedIDs ?? [],
                failures: previous?.failures.filter { ids.contains($0.key) } ?? [:], updatedAt: .now,
                inFlightIDs: (previous?.inFlightIDs ?? []).intersection(ids)))
            studyPersistenceError = nil
            studyManifest = manifest
            loadSavedCourses()
            studyCourseApproved = approved
            studyStore = store
            studyManifestTitle = manifest.courseTitle
            do {
                try StudyLibrarySelectionStore(root: studyLibraryRoot).saveSelection(for: manifest)
            } catch { studyPersistenceError = "Course selection could not be saved: \(error.localizedDescription)" }
            reloadPlaybackProgress()
            studyMessage = studyExecutionAvailable
                ? "Checking saved media and local tools…" : "Checking saved local media…"
            if ShieldRuntime.isUIReview {
                studyMessage = "Course opened for review. External tools and media checks are disabled."
            }
            studyJobs = manifest.videos.map {
                StudyJob(id: $0.id, title: $0.title,
                         state: previous?.failures[$0.id].flatMap { $0 == "Cancelled" ? nil : .failed($0) } ??
                         ((previous?.inFlightIDs ?? []).contains($0.id)
                            ? .failed("Interrupted before completion. Retry or import the video again.") : .queued))
            }
            isRestoringStudy = true
            restoreTask = Task { [weak self] in
                await self?.restoreStudy(manifest: manifest, store: store)
            }
        } catch {
            studyMessage = error.localizedDescription
        }
    }

    func rebuildStudyIndex() {
        guard !ShieldRuntime.isUIReview, !isDownloading, !isRestoringStudy,
              let manifest = pendingLibraryRecovery else { return }
        do {
            try StudyLibraryStore(root: libraryDirectory(for: manifest)).rebuildIndex(using: manifest)
            pendingLibraryRecovery = nil
            openStudyManifest(manifest, approved: manifest.isLinkQueue)
        } catch { studyMessage = "Library index could not be rebuilt: \(error.localizedDescription)" }
    }

    func startDownloads() {
        guard studyExecutionAvailable else {
            studyMessage = "External tools are disabled in this build. No process was started."
            return
        }
        guard !isDownloading, !isRestoringStudy, let manifest = studyManifest else { return }
        guard canDownloadStudyCourse else {
            studyMessage = "Allow downloads for this folder first."
            return
        }
        if let reason = studyFetchBlockReason { studyMessage = reason; return }
        let pending = manifest.videos.filter { video in
            if manifest.isLinkQueue, !queue.items.contains(where: { $0.id == video.id }) { return false }
            guard let state = studyJobs.first(where: { $0.id == video.id })?.state else { return true }
            if case .complete = state { return false }
            return true
        }
        runDownloads(manifest: StudyManifest(schemaVersion: 1, courseTitle: manifest.courseTitle,
                                             videos: pending))
    }

    /// Downloads a saved video again: at the quality chosen
    /// in Settings, and with the transcript's timing, so the transcript can
    /// follow along and captions can show. If anything goes wrong, or it's
    /// stopped, the saved copy is kept as it was.
    func downloadAgain(id: String) {
        guard studyExecutionAvailable, !isDownloading, !isRestoringStudy, let manifest = studyManifest,
              canDownloadStudyCourse,
              !manifest.isLinkQueue || queue.items.contains(where: { $0.id == id }),
              let video = manifest.videos.first(where: { $0.id == id }),
              let job = studyJobs.first(where: { $0.id == id }), case .complete = job.state else { return }
        if let reason = studyFetchBlockReason { studyMessage = reason; return }
        redownloadingIDs = [id]
        runDownloads(manifest: StudyManifest(schemaVersion: 1, courseTitle: manifest.courseTitle, videos: [
            StudyVideo(id: video.id, title: video.title, expectedDuration: video.expectedDuration,
                       transcriptRequested: true)
        ]))
    }

    func retryDownload(id: String) {
        guard studyExecutionAvailable else {
            studyMessage = "External tools are disabled in this build."
            return
        }
        guard !isDownloading, !isRestoringStudy, let manifest = studyManifest,
              !manifest.isLinkQueue || queue.items.contains(where: { $0.id == id }),
              let video = manifest.videos.first(where: { $0.id == id }),
              let job = studyJobs.first(where: { $0.id == id }) else { return }
        guard canDownloadStudyCourse else {
            studyMessage = "Allow downloads for this folder first."
            return
        }
        if let reason = studyFetchBlockReason { studyMessage = reason; return }
        guard case .failed = job.state else { return }
        runDownloads(manifest: StudyManifest(schemaVersion: 1, courseTitle: manifest.courseTitle,
                                             videos: [video]))
    }

    func playbackSelection(for id: String, transcript: Bool = false) -> StudyPlaybackSelection? {
        guard !ShieldRuntime.isUIReview, let manifest = studyManifest,
              let video = manifest.videos.first(where: { $0.id == id }),
              let job = studyJobs.first(where: { $0.id == id }), case .complete = job.state,
              let store = studyStore else {
            studyMessage = "This video is not ready to play. Import or validate it first."
            return nil
        }
        do {
            let playback = StudyPlaybackStore(root: store.root)
            _ = try playback.mediaURL(videoID: id)
            return StudyPlaybackSelection(video: video, store: playback, showTranscript: transcript)
        } catch {
            studyMessage = error.localizedDescription
            if let index = studyJobs.firstIndex(where: { $0.id == id }) {
                studyJobs[index].state = .queued
                updateStudyJob(StudyJob(id: id, title: video.title,
                    state: .failed("Saved media is unavailable. Import it again. \(error.localizedDescription)")))
            }
            return nil
        }
    }

    /// Where saved videos live, for drawing their stills off the main thread.
    var thumbnailStore: StudyPlaybackStore? { studyStore.map { StudyPlaybackStore(root: $0.root) } }

    // Read-only access for validation/integration callers. Playback uses the
    // selection above and never delegates to another application.
    func mediaURL(for id: String) -> URL? {
        guard let manifest = studyManifest, manifest.videos.contains(where: { $0.id == id }),
              let store = studyStore else { return nil }
        return try? StudyPlaybackStore(root: store.root).mediaURL(videoID: id)
    }

    private static let playbackProblem = "A saved playback position needs attention. Open the video to reset it."

    func reloadPlaybackProgress() {
        if studyPersistenceError == Self.playbackProblem { studyPersistenceError = nil }
        guard let manifest = studyManifest, let store = studyStore else { playbackPositions = [:]; return }
        let playback = StudyPlaybackStore(root: store.root)
        var positions: [String: StudyPlaybackPosition] = [:]
        for video in manifest.videos {
            do { positions[video.id] = try playback.load(videoID: video.id) }
            catch { studyPersistenceError = Self.playbackProblem }
        }
        playbackPositions = positions
    }

    /// Re-reads one video's position, after its player closes.
    func reloadPlaybackProgress(for id: String) {
        guard let store = studyStore else { return }
        do { playbackPositions[id] = try StudyPlaybackStore(root: store.root).load(videoID: id) }
        catch { studyPersistenceError = Self.playbackProblem }
    }

    private func runDownloads(manifest: StudyManifest) {
        guard !manifest.videos.isEmpty, let store = studyStore else {
            studyMessage = "All approved videos are already saved."
            return
        }
        for video in manifest.videos {
            // A saved video being downloaded again stays saved meanwhile.
            if let index = studyJobs.firstIndex(where: { $0.id == video.id }), !redownloadingIDs.contains(video.id) {
                studyJobs[index].state = .queued
            }
        }
        isDownloading = true
        downloadBatchIDs = Set(manifest.videos.map(\.id))
        downloadActivities = [:]
        downloadAttempts = [:]
        let operationID = UUID()
        downloadOperationID = operationID
        studyMessage = "Downloading approved items."
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldStudy-\(UUID().uuidString)", isDirectory: true)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            let coordinator: StudyDownloadCoordinator
            if let containment = StudyContainment.bundled,
               let tools = StudyContainment.discoveredTools, self.studyToolsOverride == nil {
                var fetcher = StudyContainedFetcher(tools: tools, containment: containment)
                fetcher.maxHeight = YTDLPRestrictedFetcher.savedQuality
                fetcher.onMetadata = { [weak self] id, title in
                    Task { @MainActor [weak self] in
                        guard let self, self.downloadOperationID == operationID else { return }
                        self.recordVideoTitle(id, title: title)
                    }
                }
                coordinator = StudyDownloadCoordinator(
                    fetcher: fetcher,
                    validator: NativeLocalMediaValidator(),
                    installer: ValidatedMediaInstaller(libraryRoot: store.root),
                    repairer: ContainedMediaRepairer(ffmpeg: tools.ffmpeg))
            } else if StudyWorkerFetcher.isPackaged {
                coordinator = StudyDownloadCoordinator(
                    fetcher: StudyWorkerFetcher(approvedIDs: manifest.videos.map(\.id), policyAllows: { [weak self] in
                        guard let self else { return false }
                        return await MainActor.run { self.studyFetchBlockReason == nil }
                    }, onMetadata: { [weak self] id, title in
                        Task { @MainActor [weak self] in
                            guard let self, self.downloadOperationID == operationID else { return }
                            self.recordVideoTitle(id, title: title)
                        }
                    }, onActivity: { [weak self] id, phase in
                        Task { @MainActor [weak self] in
                            guard let self, self.downloadOperationID == operationID else { return }
                            self.downloadActivities[id] = phase
                        }
                    }, onToolVersions: { [weak self] versions in
                        Task { @MainActor [weak self] in
                            guard let self, self.downloadOperationID == operationID else { return }
                            self.toolVersions = versions
                        }
                    }), validator: NativeLocalMediaValidator(),
                    installer: ValidatedMediaInstaller(libraryRoot: store.root))
            } else {
                // Existing explicit disposable-tool tests retain their isolated path.
                // Packaged GUI apps cannot use it; only the signed worker is eligible.
                do {
                    let tools = try self.studyToolsOverride ?? StudyTools.discover()
                    self.toolVersions = try await tools.versions()
                    coordinator = StudyDownloadCoordinator(
                        fetcher: YTDLPRestrictedFetcher(ytdlpURL: tools.ytdlp, denoURL: tools.deno, ffmpegLocation: tools.ffmpeg,
                                                        maxHeight: YTDLPRestrictedFetcher.savedQuality),
                        validator: FFprobeMediaValidator(ffprobeURL: tools.ffprobe, ffmpegURL: tools.ffmpeg),
                        installer: ValidatedMediaInstaller(libraryRoot: store.root),
                        repairer: MediaCompatibilityRepairer(ffprobeURL: tools.ffprobe, ffmpegURL: tools.ffmpeg))
                } catch {
                    self.studyMessage = error.localizedDescription
                    self.isDownloading = false
                    self.downloadOperationID = nil
                    self.downloadTask = nil
                    return
                }
            }
            let jobs = await coordinator.run(manifest: manifest, stagingDirectory: staging) { [weak self] job in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadOperationID == operationID else { return }
                    self.updateStudyJob(job)
                }
            }
            try? FileManager.default.removeItem(at: staging)
            self.persistStudyJobs(jobs.compactMap { self.applyStudyJob($0) })
            let again = self.redownloadingIDs
            self.redownloadingIDs = []
            self.downloadOperationID = nil
            self.isDownloading = false
            self.downloadBatchIDs = []
            let completed = jobs.filter { if case .complete = $0.state { return true }; return false }.count
            if let job = jobs.first(where: { again.contains($0.id) }) {
                let name = self.libraryTitle(job.id)
                if case .complete = job.state {
                    self.studyMessage = "Downloaded “\(name)” again."
                } else if case .failed(let raw) = job.state, raw != "Cancelled" {
                    let why = StudyFailureText.describe(raw, signInFilePresent: self.signInFilePresent).text
                    self.studyMessage = "“\(name)” wasn't downloaded again: \(why) The saved copy is unchanged."
                } else {
                    self.studyMessage = "“\(name)” wasn't downloaded again. The saved copy is unchanged."
                }
            } else {
                self.studyMessage = Task.isCancelled
                    ? "Download cancelled. \(completed) validated videos remain saved; unfinished items can be retried."
                    : "\(completed) of \(jobs.count) videos validated and saved."
            }
            self.downloadTask = nil
        }
    }

    private func recordVideoTitle(_ id: String, title: String) {
        guard isShowingLinkQueue,
              let index = queue.items.firstIndex(where: { $0.id == id }),
              queue.items[index].title == nil else { return }
        var updated = queue
        updated.items[index].title = String(title.prefix(160))
        do { try queueStore.save(updated); queue = updated }
        catch { queueProblem("The video's title couldn't be saved.") }
    }

    func cancelDownloads() {
        downloadTask?.cancel()
        studyMessage = "Cancelling downloads…"
    }

    func beginMediaImport(from folder: URL) { beginMediaImport(from: [folder]) }

    func beginMediaImport(from selected: [URL], forVideoID: String? = nil) {
        guard importTask == nil, !isRestoringStudy, !isDownloading else { return }
        importTask = Task { [weak self] in
            await self?.importExistingMedia(from: selected, forVideoID: forVideoID)
            self?.importTask = nil
        }
    }

    func cancelMediaImport() {
        importTask?.cancel()
        studyMessage = "Cancelling import. Videos already saved will be kept."
    }

    // The explicit picker authorizes only these files/directories. Originals
    // stay read-only; repair and validation use a private staging directory.
    func importExistingMedia(from folder: URL) async {
        await importExistingMedia(from: [folder])
    }

    func importExistingMedia(from selected: [URL], forVideoID: String? = nil) async {
        guard ShieldRuntime.allowsLocalMediaImport else {
            studyMessage = "Local media import is disabled in UI review."
            return
        }
        guard !isDownloading, !isRestoringStudy, let manifest = studyManifest,
              let store = studyStore else { return }
        if let id = forVideoID {
            guard manifest.videos.contains(where: { $0.id == id }), selected.count == 1,
                  selected[0].pathExtension.lowercased() == "mp4" else {
                studyMessage = "Choose one MP4 for the selected video. No files were changed."
                return
            }
        }
        isRestoringStudy = true
        isImportingMedia = true
        defer { isRestoringStudy = false; isImportingMedia = false }
        let scoped = selected.filter { $0.startAccessingSecurityScopedResource() }
        defer { for source in scoped { source.stopAccessingSecurityScopedResource() } }
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShieldImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        do {
            let validator: any MediaValidating
            let repairer: MediaCompatibilityRepairer?
            if ShieldRuntime.allowsExternalTools, let tools = studyToolsOverride {
                toolVersions = try await tools.versions()
                validator = FFprobeMediaValidator(ffprobeURL: tools.ffprobe, ffmpegURL: tools.ffmpeg)
                repairer = MediaCompatibilityRepairer(ffprobeURL: tools.ffprobe, ffmpegURL: tools.ffmpeg)
            } else {
                validator = NativeLocalMediaValidator()
                repairer = nil
            }
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let files = try StudyMediaSourceSelection.collect(from: selected)
            if forVideoID != nil {
                guard files.count == 1,
                      files[0] == selected[0].resolvingSymlinksInPath().standardizedFileURL else {
                    throw StudyDownloadError.invalidMedia("Choose a single regular MP4, not a folder or alias.")
                }
            }
            let installer = ValidatedMediaInstaller(libraryRoot: store.root)
            var imported = 0
            var issues: [String] = []
            for video in manifest.videos {
                try Task.checkCancellation()
                if let id = forVideoID, id != video.id { continue }
                let candidates = forVideoID == video.id
                    ? files.filter { $0.pathExtension.lowercased() == "mp4" }
                    : StudyMediaImportMatcher.candidates(for: video.id, in: files)
                guard !candidates.isEmpty else { continue }
                do {
                    guard candidates.count == 1, let source = candidates.first else {
                        throw StudyDownloadError.invalidMedia("Multiple local files claim the same video ID.")
                    }
                    let copy = staging.appendingPathComponent("\(video.id).mp4")
                    let sourceSize = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    try StudyStorageBudget.requireCapacity(at: staging, sourceBytes: Int64(sourceSize))
                    try StudyStorageBudget.requireCapacity(at: store.root, sourceBytes: Int64(sourceSize))
                    studyMessage = "Importing \(video.title)…"
                    try await StudyMediaImportStager.copy(from: source, to: copy)
                    defer { try? FileManager.default.removeItem(at: copy) }
                    let prepared: URL
                    if let repairer { prepared = try await repairer.prepare(copy) }
                    else {
                        let expected = video.expectedDuration
                        prepared = try await Self.offMain { try await NativeMediaPreparer().prepare(copy, expectedDuration: expected) }
                    }
                    defer { if prepared != copy { try? FileManager.default.removeItem(at: prepared) } }
                    let expected = video.expectedDuration
                    let videoID = video.id
                    // Checking and copying a multi-GB file must not freeze the window.
                    let validation = try await Self.offMain {
                        try await validator.validate(mediaURL: prepared, expectedDuration: expected, transcriptURL: nil)
                    }
                    _ = try await Self.offMain {
                        try installer.install(stagedMedia: prepared, validation: validation, videoID: videoID)
                    }
                    VideoThumbnailCache.shared.forget(video.id) // the file was replaced
                    // Persist the successful media commit before awaiting an optional
                    // transcript. Cancellation there must not hide a saved video.
                    updateStudyJob(StudyJob(id: video.id, title: video.title, state: .complete(validation)))
                    imported += 1
                    var hasTranscript = false
                    let transcriptSource = source.deletingPathExtension().appendingPathExtension("txt")
                    if files.contains(transcriptSource) {
                        let stagedTranscript = staging.appendingPathComponent("\(video.id).txt")
                        defer { try? FileManager.default.removeItem(at: stagedTranscript) }
                        do {
                            try await StudyMediaImportStager.copy(from: transcriptSource,
                                to: stagedTranscript, maximumBytes: 2_000_000)
                            try installer.installTranscript(from: stagedTranscript, videoID: video.id)
                            hasTranscript = true
                        } catch is CancellationError { throw CancellationError() }
                        catch { issues.append("\(video.title): transcript import failed (\(error.localizedDescription))") }
                    } else {
                        hasTranscript = (try? StudyPlaybackStore(root: store.root).transcript(videoID: video.id)) != nil
                    }
                    let installed = MediaValidation(duration: validation.duration,
                        hasVideo: validation.hasVideo, hasAudio: validation.hasAudio,
                        fileSize: validation.fileSize, transcriptPresent: hasTranscript)
                    updateStudyJob(StudyJob(id: video.id, title: video.title, state: .complete(installed)))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    issues.append("\(video.title): \(error.localizedDescription)")
                    updateStudyJob(StudyJob(id: video.id, title: video.title,
                                            state: .failed("Import failed: \(error.localizedDescription)")))
                }
            }
            studyMessage = "Imported \(imported) videos. Originals are unchanged."
            if !issues.isEmpty { studyMessage! += " \(issues.prefix(3).joined(separator: " "))" }
            else if imported == 0 { studyMessage! += " MP4 filenames must contain their matching YouTube video IDs." }
        } catch is CancellationError {
            studyMessage = "Import cancelled. Saved videos and originals were preserved."
        } catch {
            studyMessage = "Import stopped: \(error.localizedDescription)"
        }
    }

    private func updateStudyJob(_ job: StudyJob) {
        if let changed = applyStudyJob(job) { persistStudyJobs([changed]) }
    }

    /// Shows `job` in the list. Returns it when the saved library state needs
    /// to change too; progress ticks never touch the disk.
    private func applyStudyJob(_ job: StudyJob) -> StudyJob? {
        var job = job
        // Stopping a run is not a failure: the video is simply not saved yet.
        if case .failed(let reason) = job.state, reason == "Cancelled" { job.state = .queued }
        guard let index = studyJobs.firstIndex(where: { $0.id == job.id }) else { return nil }
        let previous = studyJobs[index].state
        // Downloading a saved video again: only a new copy that checked out
        // changes it. Progress, a failure or Stop leave it saved as it was.
        if redownloadingIDs.contains(job.id) {
            guard case .complete = job.state else { return nil }
            studyJobs[index] = job
            VideoThumbnailCache.shared.refresh(job.id)
            return job
        }
        switch (previous, job.state) {
        case (.complete, .downloading), (.complete, .validating), (.complete, .failed): return nil
        case (.validating, .downloading(let attempt)):
            // A late tick from the attempt being checked is dropped; a new attempt takes over.
            guard attempt > downloadAttempts[job.id, default: 1] else { return nil }
        default: break
        }
        if case .downloading(let attempt) = job.state {
            downloadAttempts[job.id] = max(attempt, downloadAttempts[job.id, default: 0])
        }
        studyJobs[index] = job
        // A download just saved this video's file (perhaps over an older
        // one), so its picture must be taken from the new file.
        if case .complete = job.state {
            switch previous {
            case .downloading, .validating: VideoThumbnailCache.shared.refresh(job.id)
            default: break
            }
        }
        if case .downloading(let old) = previous, case .downloading(let new) = job.state, old == new { return nil }
        return job
    }

    /// Writes the saved/failed/in-progress state of `jobs` in one save.
    private func persistStudyJobs(_ jobs: [StudyJob]) {
        guard !jobs.isEmpty, let store = studyStore, let manifest = studyManifest else { return }
        do {
            var snapshot = try store.load() ?? StudyLibrarySnapshot(version: 1, manifest: manifest,
                                                                     completedIDs: [], failures: [:], updatedAt: .now)
            for job in jobs {
                switch job.state {
                case .complete:
                    snapshot.completedIDs.insert(job.id)
                    snapshot.failures.removeValue(forKey: job.id)
                case .failed(let reason):
                    snapshot.completedIDs.remove(job.id)
                    snapshot.failures[job.id] = reason
                case .queued:
                    snapshot.failures.removeValue(forKey: job.id)
                default: break
                }
                switch job.state {
                case .downloading, .validating:
                    snapshot.inFlightIDs = (snapshot.inFlightIDs ?? []).union([job.id])
                default: snapshot.inFlightIDs?.remove(job.id)
                }
            }
            snapshot.updatedAt = .now
            try store.save(snapshot)
        } catch { studyPersistenceError = "Library state could not be saved: \(error.localizedDescription)" }
    }

    /// Heavy media work (sample decoding, multi-GB copies) runs here instead of
    /// on the main actor, where plain async functions otherwise stay under
    /// approachable concurrency (lag audit).
    nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try await work() }.value
    }

    private func restoreStudy(manifest: StudyManifest, store: StudyLibraryStore) async {
        // Every result is shown at once and saved together at the end.
        var changed: [StudyJob] = []
        defer { persistStudyJobs(changed); isRestoringStudy = false; restoreTask = nil }
        func record(_ job: StudyJob) { if let job = applyStudyJob(job) { changed.append(job) } }
        guard ShieldRuntime.allowsLocalMediaImport else { return }
        do {
            let validator: any MediaValidating
            if ShieldRuntime.allowsExternalTools, let tools = studyToolsOverride {
                toolVersions = try await tools.versions()
                validator = FFprobeMediaValidator(ffprobeURL: tools.ffprobe,
                                                   ffmpegURL: tools.ffmpeg)
            } else {
                validator = NativeLocalMediaValidator()
            }
            ValidatedMediaInstaller.removeLeftovers(in: store.root)
            let previouslySaved = try store.load()?.completedIDs ?? []
            for video in manifest.videos {
                try Task.checkCancellation()
                let media = store.root.appendingPathComponent("\(video.id).mp4")
                guard FileManager.default.fileExists(atPath: media.path) else {
                    if previouslySaved.contains(video.id) {
                        record(StudyJob(id: video.id, title: video.title,
                            state: .failed("Saved video is missing. Import it again.")))
                    }
                    continue
                }
                do {
                    _ = try StudyPlaybackStore(root: store.root).mediaURL(videoID: video.id)
                    let transcript = store.root.appendingPathComponent("\(video.id).txt")
                    let expected = video.expectedDuration
                    // Decoding samples is slow; off the main thread so the
                    // window stays smooth while saved videos are checked.
                    let result = try await Self.offMain {
                        try await validator.validate(mediaURL: media, expectedDuration: expected, transcriptURL: transcript)
                    }
                    record(StudyJob(id: video.id, title: video.title, state: .complete(result)))
                } catch is CancellationError { throw CancellationError() }
                catch {
                    record(StudyJob(id: video.id, title: video.title,
                                            state: .failed("Saved file failed validation: \(error.localizedDescription)")))
                }
            }
            // The library's counts already say what is saved; only older
            // course folders, which can only be imported, need the hint.
            studyMessage = manifest.isLinkQueue ? nil
                : (studyCompletedCount > 0 ? "Saved videos are ready to play." : "Import videos to start watching.")
        } catch is CancellationError { studyMessage = "Saved-video check cancelled. Files were preserved." }
        catch { studyMessage = "Saved-video check failed: \(error.localizedDescription)" }
    }

    private func libraryDirectory(for manifest: StudyManifest) -> URL {
        if manifest.isLinkQueue { return studyLibraryRoot.appendingPathComponent(".link-queue-v1") }
        let slug = manifest.courseTitle.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = String(slug.prefix(60)).isEmpty ? "course" : String(slug.prefix(60))
        let legacy = studyLibraryRoot.appendingPathComponent(base)
        // Preserve existing course locations. New Unicode or similarly named
        // collections no longer collide through a lossy/truncated title slug.
        if FileManager.default.fileExists(atPath: legacy.path) {
            if let saved = try? StudyLibraryStore(root: legacy).load() {
                if saved.manifest.courseTitle == manifest.courseTitle { return legacy }
            } else { return legacy } // Explicit damaged-index recovery remains available.
        }
        let digest = SHA256.hash(data: Data(manifest.courseTitle.precomposedStringWithCanonicalMapping.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        return studyLibraryRoot.appendingPathComponent("\(base)-\(digest)")
    }
}

 
#if DEBUG
// Previews and tests only: an example plan with curated lists and six daily
// schedules. Release builds ship no built-in blocking plan.
enum ShieldPreparedPlan {
    static let adultRoots: [String] = ["pornhub.com","xvideos.com","beeg.com","xnxx.com","redtube.com","xhamster.com","eporner.com","spankbang.com","tnaflix.com","youporn.com","tube8.com","thumbzilla.com","pornpics.com","chaturbate.com","stripchat.com","livejasmin.com","brazzers.com","bangbros.com","realitykings.com","nhentai.net","rule34.xxx","motherless.com","cam4.com","myfreecams.com","camsoda.com","bongacams.com","manyvids.com","fansly.com","onlyfans.com","javlibrary.com","javbus.com","javdb.com","hanime.tv","hitomi.la","e-hentai.org","exhentai.org","youjizz.com","drtuber.com","nuvid.com","hqporner.com","4tube.com","literotica.com","sex.com","porn.com","pornhd.com","txxx.com","upornia.com","hclips.com","ixxx.com","slutload.com","pornone.com","porn300.com","3movs.com"]
    static let foodRoots: [String] = ["doordash.com","ubereats.com","postmates.com","grubhub.com","seamless.com","trycaviar.com","delivery.com","chipotle.com","chownow.com","slicelife.com","eatstreet.com","beyondmenu.com","menufy.com","chowbus.com","ezcater.com","order.online","mcdonalds.com","tacobell.com","wendys.com","burgerking.com","dominos.com","pizzahut.com","papajohns.com","panerabread.com","chick-fil-a.com","subway.com","wingstop.com","pandaexpress.com","kfc.com","popeyes.com","qdoba.com","jerseymikes.com","littlecaesars.com","raisingcanes.com","sonicdrivein.com","dunkin.com","starbucks.com","shakeshack.com","culvers.com","fiveguys.com","sweetgreen.com","noodles.com","potbelly.com","buffalowildwings.com","applebees.com","ihop.com","dennys.com"]
    static let customRoots: [String] = ["stream.example","takeout.example","order.takeout.example"]

    static func expanded(_ roots: [String]) -> [String] {
        Set(roots.flatMap { domain -> [String] in
            var entries = [domain]
            // www aliases only for registered-looking two-part roots; avoid
            // constructing www.i.redd.it, www.order.takeout.example, etc.
            if domain.split(separator: ".").count == 2 && !domain.hasPrefix("www.") {
                entries.append("www." + domain)
            }
            return entries
        }).sorted()
    }

    static var scheduleDefinitions: [DailySchedule] {
        if MarketingRender.isActive {
            return exampleScheduleDefinitions.compactMap { schedule in
                MarketingRender.hours[schedule.id].map { schedule.withHours(start: $0.start, end: $0.end, isRequested: true) }
            }
        }
        return exampleScheduleDefinitions
    }

    // Generic allowed hours, stored as the blocked complement: social 5–9 PM,
    // Netflix 8–10 PM, YouTube 7–9 PM, Pinterest 3–5 PM.
    private static var exampleScheduleDefinitions: [DailySchedule] {
        [
            DailySchedule(id: "social-afternoon", title: "X / Reddit",
                domains: Set(expanded(["x.com","twitter.com","api.twitter.com","t.co","reddit.com","old.reddit.com","new.reddit.com","redd.it","i.redd.it","v.redd.it","preview.redd.it","oauth.reddit.com"])),
                startMinutes: 1260, endMinutes: 1020, isRequested: true),
            DailySchedule(id: "netflix-evening", title: "Netflix",
                domains: Set(expanded(["netflix.com","netflix.net","nflxvideo.net","nflximg.net","nflximg.com","nflxso.net","nflxext.com","nflxsearch.net"])),
                startMinutes: 1320, endMinutes: 1200, isRequested: true),
            DailySchedule(id: "youtube-evening", title: "YouTube",
                domains: Set(expanded(["youtube.com","m.youtube.com","music.youtube.com","youtu.be","youtube-nocookie.com","youtubei.googleapis.com"])),
                startMinutes: 1260, endMinutes: 1140, isRequested: true),
            DailySchedule(id: "instagram-afternoon", title: "Instagram",
                domains: Set(expanded(["instagram.com","cdninstagram.com","i.instagram.com","graph.instagram.com","api.instagram.com"])),
                startMinutes: 1260, endMinutes: 1020, isRequested: true),
            DailySchedule(id: "tiktok-afternoon", title: "TikTok",
                domains: Set(expanded(["tiktok.com","tiktokcdn.com","tiktokv.com"])),
                startMinutes: 1260, endMinutes: 1020, isRequested: true),
            DailySchedule(id: "pinterest-afternoon", title: "Pinterest",
                domains: Set(expanded(["pinterest.com","pin.it","pinimg.com"])),
                startMinutes: 1020, endMinutes: 900, isRequested: true)
        ]
    }

    static func commands(at now: Date) -> [BackendCommand] {
        var result: [BackendCommand] = []
        let categories: [(String, String, [String])] = [
            ("adult", "Adult content", adultRoots),
            ("food", "Food ordering", foodRoots),
            ("custom", "Custom permanent sites", MarketingRender.isActive ? [] : customRoots)
        ]
        for (categoryID, title, roots) in categories {
            let domains = expanded(roots)
            // Backend caps an owner at 100 exact domains. Chunk by unique
            // stable policy IDs; the signed authority accepts the whole plan
            // in one atomic request, never one half-applied category.
            for offset in stride(from: 0, to: domains.count, by: 100) {
                let part = offset / 100 + 1
                let owner = DomainRestriction(
                    owner: .permanent, policyID: "owner-plan-" + categoryID + "-" + String(part),
                    title: title, domains: Set(domains[offset..<min(offset + 100, domains.count)]),
                    startsAt: now)
                result.append(.add(owner))
            }
        }
        result += scheduleDefinitions.map(BackendCommand.add)
        return result
    }
}
#endif
