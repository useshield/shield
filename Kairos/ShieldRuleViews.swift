import AppKit
import SwiftUI

// The adapter only reads authenticated projections. It has no submission API.
@MainActor
struct ShieldRulePresentation {
    let model: ShieldViewModel
    var evidence: ShieldEvidence {
        let resolved = liveEvidence
        #if DEBUG
        if MarketingRender.isActive, resolved == .preview { return .confirmed }
        #endif
        // The read-only UI Review build enforces nothing and its sample data
        // never refreshes: "Needs attention" there would read as a fault.
        return ShieldRuntime.isUIReview && resolved == .attention ? .preview : resolved
    }
    private var liveEvidence: ShieldEvidence {
        let snapshot = model.backendSnapshot
        return ShieldEvidence.resolve(authority: model.health.authority, enforcement: model.health.enforcement,
            hasSnapshot: snapshot != nil,
            isLiveService: model.isServiceMode && snapshot?.enforcementSource == .installedSystemHosts,
            observedAt: snapshot?.enforcement.observedAt,
            generationsMatch: snapshot.map {
                $0.generation == $0.authority.generation && $0.generation == $0.receipt.payload.generation
            } ?? false, now: .now)
    }
    var pending: [ShieldPendingChange] {
        guard let snapshot = model.backendSnapshot else { return [] }
        if let cached = model.rulePresentationMemo.pending { return cached }
        // Place and location-rule changes are listed with their own section.
        let result = snapshot.pendingReleases.filter { !ConditionalPolicy.isConditionalOwner($0.policyID) }.map {
            ShieldPendingChange(policyID: $0.policyID, effectiveAt: $0.effectiveAt,
                                replacementSchedule: $0.replacementSchedule)
        }
        model.rulePresentationMemo.pending = result
        return result
    }
    var effectiveIDs: Set<String> {
        guard let snapshot = model.backendSnapshot else { return [] }
        if let cached = model.rulePresentationMemo.effectiveIDs { return cached }
        let result = Set(snapshot.authority.effectiveRestrictions.map(\.policyID))
        model.rulePresentationMemo.effectiveIDs = result
        return result
    }
    /// The color of the category a rule is shown in, owner-made ones included
    /// A rule's confirmation matches its category.
    func categoryTint(ruleID: String) -> Color {
        groups.first { group in
            group.schedules.contains { $0.id == ruleID } || group.restrictions.contains { $0.policyID == ruleID }
                || group.unmatchedChanges.contains { $0.policyID == ruleID }
        }?.category.color.color ?? .shieldAccent
    }
    var pendingIDs: Set<String> {
        if let cached = model.rulePresentationMemo.pendingIDs, model.backendSnapshot != nil { return cached }
        let result = Set(pending.map(\.policyID))
        if model.backendSnapshot != nil { model.rulePresentationMemo.pendingIDs = result }
        return result
    }
    var groups: [ShieldRuleGroup] {
        let layout = model.categoryLayout
        guard let snapshot = model.backendSnapshot else { return [] }
        if let cached = model.rulePresentationMemo.groups { return cached }
        // Retain unmatched effective owners too, including unfamiliar recurring
        // records, instead of losing them because schedule metadata is absent.
        let represented = Set(snapshot.committedRestrictions.map(\.policyID) + snapshot.committedSchedules.map(\.id))
        let extras = snapshot.authority.effectiveRestrictions.filter {
            !represented.contains($0.policyID) && $0.owner != .conditional
        }
        let result = ShieldGrouping.groups(schedules: snapshot.committedSchedules,
                                           restrictions: snapshot.committedRestrictions + extras, pending: pending,
                                           layout: layout, includeEmpty: true)
        model.rulePresentationMemo.groups = result
        return result
    }
    /// Which effective lists block each website (built once per snapshot).
    private var blockersByDomain: [String: [String]] {
        guard let snapshot = model.backendSnapshot else { return [:] }
        if let cached = model.rulePresentationMemo.blockersByDomain { return cached }
        var result: [String: [String]] = [:]
        for restriction in snapshot.authority.effectiveRestrictions {
            for domain in restriction.domains { result[domain, default: []].append(restriction.policyID) }
        }
        model.rulePresentationMemo.blockersByDomain = result
        return result
    }
    func status(_ schedule: DailySchedule) -> ShieldRuleStatus {
        let blockers = blockersByDomain
        let overlaps = schedule.domains.contains { domain in blockers[domain]?.contains { $0 != schedule.id } == true }
        // Same answer as checking against every other effective list's websites.
        return ShieldGrouping.scheduleStatus(schedule, evidence: evidence, effectiveIDs: effectiveIDs, pendingIDs: pendingIDs,
            otherBlockedDomains: overlaps ? schedule.domains : [])
    }
    func status(_ restriction: DomainRestriction) -> ShieldRuleStatus {
        ShieldGrouping.restrictionStatus(restriction, evidence: evidence,
            effectiveIDs: effectiveIDs, pendingIDs: pendingIDs, now: .now)
    }
    func status(_ group: ShieldRuleGroup) -> ShieldRuleStatus {
        ShieldGrouping.groupStatus(group.schedules.map { status($0) } + group.restrictions.map { status($0) }
            + group.unmatchedChanges.map { _ in .pending }, evidence: evidence)
    }
}

// MARK: - Status hero

/// One calm, truthful sentence about protection. Green only when the service
/// verified live enforcement; preview is never green.
struct ProtectionHero: View {
    let model: ShieldViewModel
    let presentation: ShieldRulePresentation
    /// What changes next, when known ("X / Reddit blocks at 8 PM").
    var detail: String? = nil
    /// Renders one state on its own (snapshot tests only; the app passes nil).
    var evidenceOverride: ShieldEvidence? = nil
    var hasRulesOverride: Bool? = nil

    private var evidence: ShieldEvidence { evidenceOverride ?? presentation.evidence }
    private var isEmptyConfirmed: Bool {
        evidence == .confirmed && !(hasRulesOverride ?? presentation.groups.contains { $0.count > 0 })
    }

    private var title: String {
        switch evidence {
        case .confirmed: return isEmptyConfirmed ? "Shield is ready" : "Protection on"
        case .preview: return "Preview only"
        case .attention: return "Protection needs attention"
        case .unavailable: return "Can't reach Shield"
        }
    }

    private var message: String {
        switch evidence {
        case .confirmed:
            if isEmptyConfirmed { return "" }
            return detail ?? "Blocking is on."
        case .preview:
            return model.backendSnapshot?.enforcementSource == .disposableSystemHosts
                ? "Disposable system-hosts test. These are test commitments."
                : (detail ?? "Simulated rules don't block websites on this Mac.")
        case .attention:
            return "Couldn't confirm protection. Your blocks are unchanged."
        case .unavailable:
            return "Your blocks are unchanged. Trying again…"
        }
    }

    private var symbol: String {
        switch evidence {
        case .confirmed: return isEmptyConfirmed ? "shield" : "checkmark.shield.fill"
        case .preview: return "shield.lefthalf.filled"
        case .attention: return "exclamationmark.shield.fill"
        case .unavailable: return "xmark.shield.fill"
        }
    }

    private var tint: Color {
        switch evidence {
        case .confirmed: return isEmptyConfirmed ? .secondary : .green
        case .preview: return .secondary
        case .attention: return .orange
        case .unavailable: return .red
        }
    }

    var body: some View {
        // Green, but smaller than the first card and flat
        // (no gradient). The coloured gradient headers stay on category pages.
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(tint == .secondary ? Color.secondary : tint)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.headline)
                        .accessibilityIdentifier("protectionStatus")
                    if !message.isEmpty {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("backendModeLabel")
                    }
                }
                Spacer(minLength: 0)
            }
            if evidence == .attention || evidence == .unavailable {
                HStack {
                    Button("Retry Connection") { model.refresh() }
                        .disabled(model.isSubmittingPolicy)
                        .accessibilityIdentifier("retryScheduleConnection")
                    Button("Check in Settings") { model.selectedSection = .diagnostics }
                        .accessibilityIdentifier("openSettingsFromProtection")
                }
                .padding(.leading, 30 + 12)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let fill = tint == .secondary ? Color.gray : tint
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(fill.opacity(0.13))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(fill.opacity(0.22), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .contain)
    }
}

struct PolicyActionNotice: View {
    let model: ShieldViewModel
    var isVisible: Bool {
        if model.isSubmittingPolicy { return true }
        guard let message = model.backendActionMessage else { return false }
        return !message.hasPrefix("Changes confirmed by the service") && !message.hasPrefix("Preview updated")
    }
    var body: some View {
        if model.isSubmittingPolicy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for confirmation…").foregroundStyle(.secondary)
            }
        } else if isVisible, let message = model.backendActionMessage {
            Label {
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("backendActionMessage")
            .accessibilityLabel(message).accessibilityValue(message)
        }
    }
}

/// A site opened (its allowed hours began, or you left a place) while a
/// browser was already open: that browser still has the older block list,
/// because browsers read Shield's list when they open. Shown as a banner in
/// the window's corner on every page.
struct ReopenBrowserNotice: View {
    let model: ShieldViewModel
    @State private var reopening = false
    @State private var problem: String?

    var body: some View {
        if let advice = model.browserReopenAdvice() {
            let detail = BrowserReopenAdvisor.detail(browser: advice.browserName, opened: advice.opened,
                                                     blocked: advice.blocked,
                                                     restoresTabs: PolicyBrowsers.restoresTabs(advice.apps))
            // "Not Now" is its ×, so there's no second one.
            ShieldBanner(symbol: "arrow.clockwise", tint: Color.shieldAccent, title: advice.headline,
                         message: detail, warning: problem) {
                if reopening { ProgressView().controlSize(.small) }
                Button("Not Now") { model.dismissBrowserReopen() }
                    .disabled(reopening)
                    .accessibilityIdentifier("dismissReopenBrowser")
                Button("Reopen \(advice.apps.count == 1 ? advice.apps[0].localizedName ?? "Browser" : "Browsers")") {
                    reopening = true
                    problem = nil
                    Task {
                        // Only the browsers still running now: one you already quit isn't opened again.
                        let result = await PolicyBrowsers.reopen(advice.apps.filter { !$0.isTerminated })
                        reopening = false
                        problem = result.message
                    }
                }
                .buttonStyle(ShieldFilledButtonStyle())
                .disabled(reopening)
                .accessibilityIdentifier("reopenBrowser")
            }
            .accessibilityIdentifier("reopenBrowserBar")
        }
    }
}

// MARK: - Rows

struct PendingRuleChangeView: View {
    let change: ShieldPendingChange
    let calendar: Calendar
    /// Offers "Keep Current Rules", which cancels the change once you confirm.
    var model: ShieldViewModel? = nil
    /// The schedule as it is now, to say what the pending change actually changes.
    var current: DailySchedule? = nil
    @State private var confirmingKeep = false
    private var description: String {
        let when = PlaceDates.short(change.effectiveAt, calendar: calendar)
        guard let replacement = change.replacementSchedule else { return "Ends \(when)" }
        let sameHours = current.map { $0.startMinutes == replacement.startMinutes && $0.endMinutes == replacement.endMinutes } ?? false
        let sameSites = current.map { $0.domains == replacement.domains && $0.apps == replacement.apps } ?? false
        if sameHours && !sameSites { return "Websites change \(when)" }
        if !sameHours && !sameSites && current != nil { return "Hours and websites change \(when)" }
        return "New hours from \(when)"
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "clock").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(description)
                    .accessibilityIdentifier("pendingScheduleRelease-\(change.policyID)")
                    .accessibilityLabel(description).accessibilityValue(description)
                if let replacement = change.replacementSchedule,
                   current.map({ $0.startMinutes != replacement.startMinutes || $0.endMinutes != replacement.endMinutes }) ?? true,
                   let window = AllowedAccessWindow(blockedSchedule: replacement) {
                    Text("Allowed " + ScheduleText.short(window))
                }
            }
            // No explainer line under the date. A Lock In's
            // reason sits in the hover help; the others have their button.
            // A Lock In's end is the lock itself: cancelling it would let the
            // schedule be removed 24 hours later, ending the lock early.
            if let model, !LockInPlan.isLockIn(change.policyID) {
                Spacer(minLength: 8)
                Button("Keep Current Rules…") { confirmingKeep = true }
                    .controlSize(.small)
                    .disabled(!model.canSubmitPolicy)
                    .help("Cancel this change. The current, stricter rules stay.")
                    .accessibilityIdentifier("cancelPending-\(change.policyID)")
                    .shieldConfirmation(isPresented: $confirmingKeep) {
                        keepConfirmation(model)
                    }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .help(LockInPlan.isLockIn(change.policyID) ? "Part of a Lock In. It can't be ended early." : "")
    }

    /// The rule's name as the rest of Shield shows it.
    private func ruleName(_ model: ShieldViewModel) -> String? {
        if let schedule = model.backendSnapshot?.committedSchedules.first(where: { $0.id == change.policyID }) {
            return model.displayName(for: schedule.id, title: schedule.title)
        }
        if let rule = model.backendSnapshot?.committedRestrictions.first(where: { $0.policyID == change.policyID }) {
            return model.displayName(for: rule.policyID, title: rule.title)
        }
        return nil
    }

    private func keepConfirmation(_ model: ShieldViewModel) -> ShieldConfirmation {
        let when = PlaceDates.short(change.effectiveAt, calendar: calendar)
        let name = ruleName(model)
        let what = change.replacementSchedule == nil ? "end" : "change"
        return ShieldConfirmation(
            symbol: "checkmark.shield.fill", tint: ShieldRulePresentation(model: model).categoryTint(ruleID: change.policyID),
            title: "Keep your current rules?",
            message: (name.map { "\($0) won't \(what) at \(when)." } ?? "This change won't happen at \(when).")
                + " Changing it later means waiting 24 hours again.",
            confirmTitle: "Keep Current Rules",
            confirmIdentifier: "confirmKeepCurrentRules-\(change.policyID)") {
                _ = model.cancelPendingChange(change.policyID)
            }
    }
}

/// One schedule: name, allowed hours and a 24-hour bar. Clicking the row shows
/// its websites; Edit holds hours, websites, name, category and removal.
/// Column widths are fixed so bars align.
struct ScheduleRuleRow: View {
    let schedule: DailySchedule
    let model: ShieldViewModel
    /// Category pages list the websites; the Today timeline stays compact.
    var showsWebsites = false
    static let nameColumn: CGFloat = 180
    static let actionColumn: CGFloat = 56
    @State private var showingWebsites = false
    @State private var editingHours = false
    @State private var editingSites = false
    @State private var renaming = false
    @State private var confirmingRemoval = false

    private var presentation: ShieldRulePresentation { ShieldRulePresentation(model: model) }
    private var window: AllowedAccessWindow? { AllowedAccessWindow(blockedSchedule: schedule) }
    private var hours: String {
        window?.description(calendar: model.scheduleCalendar) ?? "Hours need review"
    }
    private var name: String { model.displayName(for: schedule.id, title: schedule.title) }
    private var isPending: Bool { presentation.pendingIDs.contains(schedule.id) }
    private var categoryID: String {
        model.categoryLayout.categoryID(for: schedule.id, defaultKind: ShieldGrouping.kind(for: schedule))
    }
    private var tint: Color { RowTint.color(name: name, domains: schedule.domains) }

    private var canEdit: Bool { model.canSubmitPolicy && !isPending }
    /// " · 12 websites" after the hours.
    private var websitesSuffix: String {
        showsWebsites && !schedule.domains.isEmpty ? " · " + WebsiteListParser.count(schedule.domains) : ""
    }

    /// Name over hours. Drawn twice: inside the button with the hours hidden
    /// (layout and click target), and over it with only the hours shown.
    private func nameAndHours(hoursVisible: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).fontWeight(.medium).lineLimit(1)
                .opacity(hoursVisible ? 0 : 1)
                .accessibilityHidden(hoursVisible)
            Text((window.map { ScheduleText.short($0) } ?? "Needs review") + websitesSuffix)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.85)
                .opacity(hoursVisible ? 1 : 0)
                .accessibilityHidden(!hoursVisible)
                .accessibilityIdentifier(hoursVisible ? "confirmedScheduleHours-\(schedule.id)" : "")
                .accessibilityLabel(hours).accessibilityValue(hours)
        }
        .frame(width: Self.nameColumn, alignment: .leading)
    }

    private var canShowWebsites: Bool { showsWebsites && !schedule.domains.isEmpty }
    private var shortHours: String { window.map { ScheduleText.short($0) } ?? "Needs review" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 14 matches `ScheduleAxisRow`, so bars line up with the hour labels.
            HStack(spacing: 14) {
                Button {
                    guard canShowWebsites else { return }
                    withAnimation(.snappy(duration: 0.25)) { showingWebsites.toggle() }
                } label: {
                    HStack(spacing: ShieldMetrics.rowSpacing) {
                        RuleKindTile(symbol: "clock.fill", tint: tint)
                            .opacity(isPending ? 0.6 : 1)
                        HStack(spacing: 14) {
                            nameAndHours(hoursVisible: false)
                            AllowedHoursBar(window: window, nowMinutes: model.scheduleNowMinutes)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(canShowWebsites ? (showingWebsites ? "Hide websites" : "Show websites") : name)
                .accessibilityLabel("\(name), allowed \(shortHours)")
                .accessibilityValue(shortHours)
                .accessibilityHint(canShowWebsites ? "Shows or hides its websites" : "")
                .accessibilityIdentifier("scheduleWebsites-\(schedule.id)")
                // macOS folds a button's label into one element, so the allowed hours
                // are drawn over the button as their own readable text.
                .overlay(alignment: .leading) {
                    nameAndHours(hoursVisible: true)
                        .padding(.leading, ShieldMetrics.rowIcon + ShieldMetrics.rowSpacing)
                        .allowsHitTesting(false)
                }
                editMenu.frame(width: Self.actionColumn, alignment: .trailing)
            }
            Group {
                if let pending = presentation.pending.first(where: { $0.policyID == schedule.id }) {
                    PendingRuleChangeView(change: pending, calendar: model.scheduleCalendar, model: model, current: schedule)
                }
                if !schedule.apps.isEmpty {
                    AppTargetsLine(apps: schedule.apps, identifier: "scheduleApps-\(schedule.id)")
                }
                if showingWebsites && canShowWebsites {
                    WebsitesPanel(domains: schedule.domains)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.leading, ShieldMetrics.detailIndent)
        }
        .padding(.vertical, 3)
        .sheet(isPresented: $editingHours) { PreparedScheduleHoursEditor(model: model, schedule: schedule) }
        .sheet(isPresented: $editingSites) { ScheduleSitesEditor(model: model, schedule: schedule) }
        .sheet(isPresented: $renaming) { RenameRuleSheet(model: model, ruleID: schedule.id, current: name, what: "Schedule") }
        .shieldConfirmation(isPresented: $confirmingRemoval) {
            ShieldConfirmation(symbol: "calendar.badge.minus", tint: presentation.categoryTint(ruleID: schedule.id),
                               title: "Remove \(name)?",
                               message: "Its hours keep applying for 24 hours, then it's gone.",
                               confirmTitle: "Remove After 24 Hours", destructive: true,
                               confirmIdentifier: "confirmRemoveSchedule") { _ = model.removeSchedule(schedule.id) }
        }
    }

    /// Hours and websites wait while a change is pending; name and category never do.
    private var editMenu: some View {
        Menu {
            Button("Hours…") { editingHours = true }
                .disabled(!canEdit)
                .accessibilityIdentifier("changeHours-\(schedule.id)")
            Button("Websites…") { editingSites = true }
                .disabled(!canEdit)
                .accessibilityIdentifier("editScheduleSites-\(schedule.id)")
            Button("Rename…") { renaming = true }
            MoveToCategoryMenu(model: model, ruleID: schedule.id, currentCategoryID: categoryID)
            Divider()
            Button("Remove Schedule…", role: .destructive) { confirmingRemoval = true }
                .disabled(!canEdit)
                .accessibilityIdentifier("removeSchedule-\(schedule.id)")
        } label: {
            Text("Edit")
        }
        .ruleEditMenuStyle()
        .help(isPending ? "A change is already pending" :
                (model.canSubmitPolicy ? "Change hours, websites, name or category" : "Only the name and category can change right now"))
        .accessibilityLabel("Edit \(name)")
        .accessibilityValue(shortHours)
        .accessibilityIdentifier("editPreparedSchedule-\(schedule.id)")
    }
}

/// Axis row aligned with `ScheduleRuleRow` bars.
struct ScheduleAxisRow: View {
    var body: some View {
        HStack(spacing: ShieldMetrics.rowSpacing) {
            Color.clear.frame(width: ShieldMetrics.rowIcon, height: 1)
            HStack(spacing: 14) {
                Color.clear.frame(width: ScheduleRuleRow.nameColumn, height: 1)
                HourAxisLabels().frame(maxWidth: .infinity)
                Color.clear.frame(width: ScheduleRuleRow.actionColumn, height: 1)
            }
        }
    }
}

/// One card for a list that isn't a daily schedule: blocked all day, until a
/// date, or at a place. Laid out like `ScheduleRuleRow`: clicking it shows its
/// websites, Edit holds the rest. A combined card shows several lists
/// as one; each keeps its own terms in the service.
struct RestrictionRuleRow: View {
    let rules: [DomainRestriction]
    let model: ShieldViewModel
    @State private var showingWebsites = false
    @State private var removingSites = false
    @State private var confirmingRelease = false
    @State private var renaming = false
    private var presentation: ShieldRulePresentation { ShieldRulePresentation(model: model) }
    private var first: DomainRestriction { rules[0] }
    private var isCombined: Bool { rules.count > 1 }
    private var ids: [String] { rules.map(\.policyID) }
    private var domains: Set<String> { rules.reduce(into: Set<String>()) { $0.formUnion($1.domains) } }
    private var apps: Set<AppTarget> { rules.reduce(into: Set<AppTarget>()) { $0.formUnion($1.apps) } }
    private var name: String { model.displayName(for: first.policyID, title: first.title) }
    private var removal: ShieldViewModel.SiteRemoval { model.siteRemoval(for: first) }
    private var canRemoveSites: Bool {
        guard !isCombined, model.canSubmitPolicy else { return false }
        if case .unavailable = removal { return false }
        return true
    }
    private var pendingIDs: Set<String> { Set(presentation.pending.map(\.policyID)) }
    /// Every list ends after 24 hours on request ("until removed" lists only).
    /// Place blocks too.
    private var canRelease: Bool {
        model.canSubmitPolicy && (rules.allSatisfy { $0.owner == .commitment && $0.endsAt == nil } || permanentWait != nil)
            && pendingIDs.isDisjoint(with: ids)
    }
    /// A single permanent block made under Shield 1.1: its removal wait.
    private var permanentWait: TimeInterval? {
        guard !isCombined, case .afterPermanentWait(let wait) = removal else { return nil }
        return wait
    }
    private var categoryID: String { ShieldGrouping.categoryID(for: first, layout: model.categoryLayout) }
    private var isPermanent: Bool { rules.allSatisfy { $0.owner == .permanent } }

    private var detail: String {
        if isPermanent {
            return !isCombined && removal == .correction ? "Fixable until \(correctionDeadline)" : "Forever"
        }
        if let end = rules.compactMap(\.endsAt).max(), rules.allSatisfy({ $0.endsAt != nil }) {
            return "Until \(PlaceDates.short(end, calendar: model.scheduleCalendar))"
        }
        if let id = first.placeID {
            return "At " + (model.locationPolicy.places.first { $0.id == id }?.name ?? "a removed place")
        }
        return "Until removed"
    }

    private var removalWaitText: String { PermanentRemovalPolicy.describe(permanentWait ?? 86_400) }

    private var correctionDeadline: String {
        PlaceDates.short((first.startsAt ?? .now).addingTimeInterval(DomainRestriction.permanentCorrectionWindow),
                         calendar: model.scheduleCalendar)
    }

    /// "Forever · 116 websites · 4 lists"
    private func summary(_ domains: Set<String>) -> String {
        var parts = [detail]
        if !domains.isEmpty { parts.append(WebsiteListParser.count(domains)) }
        if !apps.isEmpty { parts.append("\(apps.count) app\(apps.count == 1 ? "" : "s")") }
        if isCombined { parts.append("\(rules.count) lists") }
        return parts.joined(separator: " · ")
    }

    private var kindSymbol: String {
        if isPermanent { return "lock.fill" }
        if first.placeID != nil { return "mappin.and.ellipse" }
        if rules.allSatisfy({ $0.endsAt != nil }) { return "hourglass" }
        return "nosign"
    }

    private var status: ShieldRuleStatus {
        ShieldGrouping.groupStatus(rules.map { presentation.status($0) }, evidence: presentation.evidence)
    }

    var body: some View {
        let domains = self.domains
        VStack(alignment: .leading, spacing: 0) {
            // 14 matches `ScheduleAxisRow`, so bars line up with the hour labels.
            HStack(spacing: 14) {
                Button {
                    guard !domains.isEmpty else { return }
                    withAnimation(.snappy(duration: 0.25)) { showingWebsites.toggle() }
                } label: {
                    HStack(spacing: ShieldMetrics.rowSpacing) {
                        RuleKindTile(symbol: kindSymbol, tint: RowTint.color(name: name, domains: domains))
                            .opacity(status == .inactive || status == .scheduled ? 0.5 : 1)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name).fontWeight(.medium).lineLimit(1).truncationMode(.tail)
                            Text(summary(domains)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(domains.isEmpty ? name : (showingWebsites ? "Hide websites" : "Show websites"))
                .accessibilityElement(children: .combine)
                .accessibilityHint(domains.isEmpty ? "" : "Shows or hides its websites")
                .accessibilityIdentifier("ruleWebsites-\(first.policyID)")
                editMenu.frame(width: ScheduleRuleRow.actionColumn, alignment: .trailing)
            }
            Group {
                if let start = rules.compactMap(\.startsAt).min(), start > .now {
                    Text("Starts \(PlaceDates.short(start, calendar: model.scheduleCalendar))")
                        .font(.callout).foregroundStyle(.secondary).padding(.top, 2)
                }
                ForEach(presentation.pending.filter { ids.contains($0.policyID) }) { pending in
                    PendingRuleChangeView(change: pending, calendar: model.scheduleCalendar, model: model)
                }
                if !isCombined && model.canUndoNewBlock(first) {
                    Button("Undo") { _ = model.undoNewBlock(first) }
                        .controlSize(.small)
                        .help("Added in the last 10 minutes, so it can still be undone")
                        .accessibilityIdentifier("undoNewBlock-\(first.policyID)")
                        .padding(.top, 2)
                }
                if !isCombined && removal == .correction && pendingIDs.isDisjoint(with: ids) {
                    Button("Fix a Mistake…") { removingSites = true }
                        .controlSize(.small)
                        .disabled(!model.canSubmitPolicy)
                        .help(model.canSubmitPolicy ? "Remove websites added by mistake" : "Changes aren't available right now")
                        .accessibilityIdentifier("correctPermanent-\(first.policyID)")
                        .padding(.top, 2)
                }
                if !apps.isEmpty {
                    AppTargetsLine(apps: apps, identifier: "ruleApps-\(first.policyID)")
                }
                if showingWebsites && !domains.isEmpty {
                    WebsitesPanel(domains: domains)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.leading, ShieldMetrics.detailIndent)
        }
        .padding(.vertical, 3)
        .sheet(isPresented: $removingSites) { RemoveSitesSheet(model: model, restriction: first) }
        .sheet(isPresented: $renaming) {
            RenameRuleSheet(model: model, ruleID: first.policyID, current: name, what: isCombined ? "Lists" : "Block")
        }
        .shieldConfirmation(isPresented: $confirmingRelease) {
            ShieldConfirmation(symbol: "minus.circle.fill", tint: presentation.categoryTint(ruleID: first.policyID),
                               title: isCombined ? "Remove these \(rules.count) lists?" : "Remove \(name)?",
                               message: "It stays blocked for \(removalWaitText), then ends.",
                               confirmTitle: "Remove After \(removalWaitText.capitalized)", destructive: true,
                               confirmIdentifier: "confirmRemoveBlock") {
                if permanentWait != nil { model.requestPermanentRemoval(policyID: first.policyID) }
                else { model.requestFixtureRelease(policyIDs: ids) }
            }
        }
    }

    private var editMenu: some View {
        Menu {
            Button("Rename…") { renaming = true }
            if canRemoveSites {
                Button("Remove Websites…") { removingSites = true }
                    .accessibilityIdentifier("removeSites-\(first.policyID)")
            }
            if first.placeID == nil {
                MoveToCategoryMenu(model: model, ruleID: first.policyID, currentCategoryID: categoryID)
            }
            if model.categoryLayout.combination(containing: first.policyID) != nil {
                Button("Separate Lists") { model.separateRules(ids) }
                    .accessibilityIdentifier("separateLists-\(first.policyID)")
            }
            if canRelease {
                Divider()
                Button(isCombined ? "Remove Lists…" : "Remove Block…", role: .destructive) { confirmingRelease = true }
                    .accessibilityIdentifier("requestRelease-\(first.policyID)")
            }
        } label: {
            Text("Edit")
        }
        .ruleEditMenuStyle()
        .help("Rename, move or remove")
        .accessibilityLabel("Edit \(name)")
        .accessibilityIdentifier("ruleMenu-\(first.policyID)")
    }
}

/// Renames a list or schedule in Shield's window. Blocking doesn't change.
struct RenameRuleSheet: View {
    let model: ShieldViewModel
    let ruleID: String
    let current: String
    /// "Block", "Schedule" or "Lists": the title says what's being renamed.
    var what = "Block"

    var body: some View {
        RenameSheet(title: "Rename \(what)", subtitle: "",
                    current: current, fieldIdentifier: "renameRuleName", saveIdentifier: "confirmRenameRule",
                    onReset: model.categoryLayout.names[ruleID] == nil ? nil : { model.renameRule(ruleID, to: "") }) { name in
            model.renameRule(ruleID, to: name)
        }
    }
}

/// One small sheet for every rename (lists, schedules, videos, places): the
/// field opens focused with the current name selected.
struct RenameSheet: View {
    let title: String
    let subtitle: String
    let current: String
    var fieldIdentifier = "renameName"
    var saveIdentifier = "confirmRename"
    /// Shown as "Use Original Name" when the name was changed before.
    var onReset: (() -> Void)? = nil
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool

    init(title: String, subtitle: String, current: String, fieldIdentifier: String = "renameName",
         saveIdentifier: String = "confirmRename", onReset: (() -> Void)? = nil, onSave: @escaping (String) -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.current = current
        self.fieldIdentifier = fieldIdentifier
        self.saveIdentifier = saveIdentifier
        self.onReset = onReset
        self.onSave = onSave
        // Starts with the current name in the field, never blank.
        _name = State(initialValue: current)
    }

    private var cleaned: String { ShieldCategoryLayout.cleanName(name) }

    var body: some View {
        VStack(spacing: 0) {
            EditorSheetHeader(symbol: "pencil", tint: .shieldAccent, title: title, subtitle: subtitle)
            Form {
                TextField("Name", text: $name, prompt: Text(current.isEmpty ? "Name" : current))
                    .focused($focused)
                    .onSubmit(save)
                    .accessibilityIdentifier(fieldIdentifier)
            }
            .formStyle(.bubble)
            HStack {
                if let onReset {
                    Button("Use Original Name") { onReset(); dismiss() }
                        .accessibilityIdentifier("resetName")
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: save)
                    .buttonStyle(.prominentWhenEnabled)
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleaned.isEmpty)
                    .accessibilityIdentifier(saveIdentifier)
            }
            .shieldSheetFooter()
        }
        .frame(width: 420)
        .shieldSheet()
        .onAppear { if name.isEmpty { name = current }; focused = true }
    }

    private func save() {
        guard !cleaned.isEmpty else { return }
        if cleaned != current { onSave(cleaned) }
        dismiss()
    }
}

/// Shows several lists in a category as one card. Permanent lists combine
/// only with permanent ones, so a card never mixes what can and can't end.
struct CombineListsSheet: View {
    let model: ShieldViewModel
    let categoryID: String
    let cards: [[DomainRestriction]]
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []
    @State private var name = ""

    private func key(_ card: [DomainRestriction]) -> String { card[0].policyID }
    private func isPermanent(_ card: [DomainRestriction]) -> Bool { card.allSatisfy { $0.owner == .permanent } }
    private var chosenCards: [[DomainRestriction]] { cards.filter { chosen.contains(key($0)) } }
    private var mixed: Bool { Set(chosenCards.map(isPermanent)).count > 1 }
    private var fallbackName: String { model.categoryLayout.category(categoryID)?.name ?? "Combined list" }

    private func label(_ card: [DomainRestriction]) -> String {
        let domains = card.reduce(into: Set<String>()) { $0.formUnion($1.domains) }
        return model.displayName(for: card[0].policyID, title: card[0].title) + " · " + WebsiteListParser.count(domains)
    }

    @ViewBuilder private func section(_ title: String, permanent: Bool) -> some View {
        let matching = cards.filter { isPermanent($0) == permanent }
        if !matching.isEmpty {
            Section(title) {
                ForEach(matching, id: \.first!.policyID) { card in
                    Toggle(label(card), isOn: Binding(
                        get: { chosen.contains(key(card)) },
                        set: { if $0 { chosen.insert(key(card)) } else { chosen.remove(key(card)) } }))
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorSheetHeader(symbol: "square.stack.3d.up", tint: .shieldAccent, title: "Combine Lists",
                              subtitle: "")
            Form {
                section("Permanent", permanent: true)
                section("Until removed", permanent: false)
                Section {
                    TextField("Name", text: $name, prompt: Text(fallbackName))
                        .accessibilityIdentifier("combineListsName")
                } header: {
                    Text("Name")
                } footer: {
                    if mixed { Text("Permanent lists combine only with other permanent lists.").foregroundStyle(.orange) }
                }
            }
            .formStyle(.bubble)
            .scrollContentBackground(.hidden)
            HStack {
                Text("You can separate them again any time.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Combine") {
                    let ids = chosenCards.flatMap { $0.map(\.policyID) }
                    model.combineRules(ids, name: name.isEmpty ? fallbackName : name, in: categoryID)
                    dismiss()
                }
                .buttonStyle(.prominentWhenEnabled)
                .disabled(chosenCards.count < 2 || mixed)
                .accessibilityIdentifier("confirmCombineLists")
            }
            .shieldSheetFooter()
        }
        .frame(width: 460)
        .shieldSheet()
        .frame(minHeight: 360, maxHeight: 640)
        .onAppear {
            // Start with the larger kind chosen, so Combine works in one click.
            let permanent = cards.filter(isPermanent).count >= cards.filter { !isPermanent($0) }.count
            chosen = Set(cards.filter { isPermanent($0) == permanent }.map(key))
        }
    }
}

// MARK: - Drill-down page

struct RuleGroupDetailPage: View {
    let categoryID: String
    let model: ShieldViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingCategory = false
    @State private var addingBlock = false
    @State private var addingSchedule = false
    @State private var importingList = false
    @State private var combining = false
    private var presentation: ShieldRulePresentation { ShieldRulePresentation(model: model) }
    private var group: ShieldRuleGroup? { presentation.groups.first { $0.id == categoryID } }
    private var category: ShieldCategory? { model.categoryLayout.category(categoryID) }
    /// Daily schedules can't be limited to a place, so Location blocks offers only New Block.
    private var offersSchedules: Bool { categoryID != ShieldCategoryLayout.locationID }

    /// The category's lists as cards: lists the user combined, and the parts
    /// of one owner plan (split only by the service's per-rule size), as one.
    static func cards(_ restrictions: [DomainRestriction], layout: ShieldCategoryLayout) -> [[DomainRestriction]] {
        var result: [[DomainRestriction]] = []
        var used = Set<String>()
        for rule in restrictions where !used.contains(rule.policyID) {
            let together: [String]
            if let combined = layout.combination(containing: rule.policyID) {
                together = combined
            } else if let plan = ownerPlan(rule.policyID) {
                together = restrictions.map(\.policyID).filter {
                    ownerPlan($0) == plan && layout.combination(containing: $0) == nil
                }
            } else {
                together = [rule.policyID]
            }
            let members = restrictions.filter { together.contains($0.policyID) && !used.contains($0.policyID) }
            used.formUnion(members.map(\.policyID))
            result.append(members.isEmpty ? [rule] : members)
        }
        return result
    }

    /// "owner-plan-adult-2" → "owner-plan-adult".
    static func ownerPlan(_ policyID: String) -> String? {
        guard policyID.hasPrefix("owner-plan-"), let dash = policyID.lastIndex(of: "-") else { return nil }
        return String(policyID[..<dash])
    }

    /// Cards that could be shown as one: every list here except place blocks
    /// and timed locks.
    /// Only lists of the same kind combine: two permanent, or two until-removed.
    static func canCombine(_ cards: [[DomainRestriction]]) -> Bool {
        let permanent = cards.count { $0.allSatisfy { $0.owner == .permanent } }
        return permanent > 1 || cards.count - permanent > 1
    }

    private func combinable(_ group: ShieldRuleGroup) -> [[DomainRestriction]] {
        Self.cards(group.restrictions, layout: model.categoryLayout)
            .filter { $0.allSatisfy { $0.placeID == nil && $0.endsAt == nil } }
    }

    private var addItems: [AddMenuItem] {
        let enabled = category != nil
        var items = [AddMenuItem(title: "New Block…", identifier: "newBlock", enabled: enabled) { addingBlock = true }]
        if offersSchedules {
            items.append(AddMenuItem(title: "New Daily Schedule…", identifier: "addSchedule", enabled: enabled) { addingSchedule = true })
            items.append(AddMenuItem(title: "Import Website List…", identifier: "importList", enabled: enabled) { importingList = true })
        }
        return items
    }

    private func headerSubtitle(_ group: ShieldRuleGroup?) -> String {
        guard let group else { return "Nothing here yet" }
        var parts: [String] = []
        if !group.schedules.isEmpty {
            parts.append("\(group.schedules.count) daily schedule\(group.schedules.count == 1 ? "" : "s")")
        }
        let cards = Self.cards(group.restrictions, layout: model.categoryLayout).count
        if cards > 0 { parts.append("\(cards) block\(cards == 1 ? "" : "s")") }
        if parts.isEmpty { return "Nothing here yet" }
        return ([presentation.status(group).title] + parts).joined(separator: " · ")
    }

    var body: some View {
        ShieldBubblePage(maxWidth: 900) {
            if let category {
                if category.id == ShieldCategoryLayout.locationID {
                    // The coloured header doesn't fit the places pages.
                    Text(headerSubtitle(group)).foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .accessibilityIdentifier("categoryHeader")
                } else {
                    PageHeader(symbol: category.symbol, tint: category.color.color, title: category.name,
                               subtitle: headerSubtitle(group))
                        .shieldBubble(padding: 20, tint: category.color.color)
                        .accessibilityIdentifier("categoryHeader")
                }
                if model.categoryMessage != nil || PolicyActionNotice(model: model).isVisible ||
                    model.submissionRecordError != nil || (model.pendingSubmission != nil && !model.isSubmittingPolicy) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let message = model.categoryMessage {
                            Text(message).font(.callout).foregroundStyle(.orange)
                        }
                        PolicyActionNotice(model: model)
                        PolicySubmissionRecoveryView(model: model)
                    }
                    .shieldBubble()
                }
                if let group, presentation.evidence == .attention || presentation.evidence == .unavailable {
                    StatusLabel(status: presentation.status(group)).shieldBubble(padding: 14)
                }
                if let group, !group.schedules.isEmpty {
                    BubbleSection(title: "Allowed hours") {
                        ScheduleAxisRow().padding(.horizontal, 14)
                        ForEach(group.schedules) { schedule in
                            ScheduleRuleRow(schedule: schedule, model: model, showsWebsites: true)
                                .shieldBubble(padding: 14)
                        }
                    }
                }
                if let group, !group.restrictions.isEmpty {
                    BubbleSection(title: group.restrictions.allSatisfy { $0.owner == .permanent } ? "Always blocked" : "Blocks") {
                        ForEach(Self.cards(group.restrictions, layout: model.categoryLayout), id: \.first!.policyID) { card in
                            RestrictionRuleRow(rules: card, model: model)
                                .shieldBubble(padding: 14)
                        }
                    }
                }
                if let group, !group.unmatchedChanges.isEmpty {
                    BubbleSection(title: "Pending") {
                        ForEach(group.unmatchedChanges) { change in
                            PendingRuleChangeView(change: change, calendar: model.scheduleCalendar, model: model)
                                .shieldBubble(padding: 14)
                        }
                    }
                }
                if group.map({ $0.count == 0 }) ?? true {
                    ShieldEmptyState(title: "Nothing here yet", symbol: category.symbol,
                                     tint: category.color.color) {
                        Button("New Block…") { addingBlock = true }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("categoryAddWebsites")
                        if offersSchedules {
                            Button("New Daily Schedule…") { addingSchedule = true }
                                .accessibilityIdentifier("categoryAddSchedule")
                        }
                    }
                }
            } else {
                ShieldEmptyState(title: "Category removed", symbol: "square.stack",
                                 message: "Its rules moved to their usual category.", tint: .secondary)
            }
        }
        .navigationTitle(category?.name ?? "Category")
        .toolbar {
            // The same pair as the Protection page: a blue + to add, ⋯ for the category.
            AddAndMoreToolbar(add: AddMenuButton(items: addItems, help: "Add a block, daily schedule or imported list to this category",
                                                 identifier: "categoryAddMenu")) {
                Menu {
                    if let group, Self.canCombine(combinable(group)) {
                        Button("Combine Lists…") { combining = true }
                            .accessibilityIdentifier("combineLists")
                    }
                    Button("Edit Category…") { editingCategory = true }
                        .accessibilityIdentifier("editCategory")
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
                .disabled(category == nil)
                .help("Combine lists or edit this category")
                .accessibilityLabel("More")
                .accessibilityIdentifier("categoryMoreMenu")
            }
        }
        .sheet(isPresented: $editingCategory) {
            CategoryEditor(model: model, existing: category) { dismiss() }
        }
        .sheet(isPresented: $addingBlock) { BlockEditor(model: model, categoryID: categoryID) }
        .sheet(isPresented: $addingSchedule) { NewScheduleEditor(model: model, categoryID: categoryID) }
        .sheet(isPresented: $importingList) { ImportListEditor(model: model, categoryID: categoryID) }
        .sheet(isPresented: $combining) {
            if let group { CombineListsSheet(model: model, categoryID: categoryID, cards: combinable(group)) }
        }
    }
}

/// "Apps: Example Game, Other" under a rule, with how app blocking works.
struct AppTargetsLine: View {
    let apps: Set<AppTarget>
    let identifier: String

    var body: some View {
        let sorted = apps.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        HStack(spacing: 6) {
            HStack(spacing: -4) {
                ForEach(sorted.prefix(3)) { AppIcon(bundleID: $0.bundleID, size: 16) }
            }
            Text("Apps: " + sorted.map(\.displayName).joined(separator: ", "))
                .accessibilityIdentifier(identifier)
        }
        .font(.callout).foregroundStyle(.secondary)
        .help("These apps are closed within a few seconds whenever they open.")
    }
}

/// The installed app's own icon, or a plain placeholder when it isn't found.
struct AppIcon: View {
    let bundleID: String
    var size: CGFloat = 18

    /// Looked up once per app, not on every redraw.
    @MainActor private static var icons: [String: NSImage?] = [:]

    var body: some View {
        if let icon = Self.icon(bundleID) {
            Image(nsImage: icon)
                .resizable().frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed").frame(width: size, height: size).accessibilityHidden(true)
        }
    }

    @MainActor private static func icon(_ bundleID: String) -> NSImage? {
        if let known = icons[bundleID] { return known }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[bundleID] = icon
        return icon
    }
}

/// One row's websites, shown by clicking the row; long lists scroll in place.
struct WebsitesPanel: View {
    let domains: Set<String>

    var body: some View {
        let roots = WebsiteListParser.roots(domains)
        let text = Text(roots.joined(separator: ", "))
            .textSelection(.enabled)
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        Group {
            if roots.count > 120 {
                ScrollView { text }.frame(height: 180)
            } else {
                text
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rowWebsites")
    }
}

/// See `ShieldViewModel.rulePresentationMemo`.
struct RulePresentationMemo {
    var pending: [ShieldPendingChange]?
    var pendingIDs: Set<String>?
    var effectiveIDs: Set<String>?
    var groups: [ShieldRuleGroup]?
    var blockersByDomain: [String: [String]]?
}
