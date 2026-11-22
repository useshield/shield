import SwiftUI

/// "What Shield changes on this Mac". Every
/// place Shield touches the system, whether it's in use now, and one line on
/// what it does. Read-only: each item is turned on or off where it lives.
struct ShieldChangesSection: View {
    let model: ShieldViewModel

    struct Item: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let detail: String
        let on: Bool
    }

    static func items(snapshot: BackendSnapshot?, locationOn: Bool, closesTabs: Bool,
                      videoLibrary: Bool) -> [Item] {
        let restrictions = snapshot?.committedRestrictions ?? []
        let schedules = snapshot?.committedSchedules ?? []
        let blocksSites = restrictions.contains { !$0.domains.isEmpty } || schedules.contains { !$0.domains.isEmpty }
        let blocksApps = restrictions.contains { !$0.apps.isEmpty } || schedules.contains { !$0.apps.isEmpty }
        let connected = snapshot != nil
        return [
            Item(id: "service", symbol: "gearshape.2.fill", title: "Background service",
                 detail: "Keeps your blocks on when Shield is closed. Lives in /Library.", on: connected),
            Item(id: "hosts", symbol: "globe", title: "Website blocking",
                 detail: "Adds one marked section to /etc/hosts for the sites you block.", on: connected && blocksSites),
            Item(id: "browsers", symbol: "safari.fill", title: "Browser settings",
                 detail: "Sets a block list in Chrome, Edge, Brave, Firefox and others so they can't skip it.",
                 on: connected && blocksSites && snapshot?.supportsBrowserPolicy == true),
            Item(id: "apps", symbol: "app.badge.fill", title: "Closing blocked apps",
                 detail: "Asks blocked apps to quit while their block is on.", on: connected && blocksApps),
            Item(id: "location", symbol: "location.fill", title: "Location",
                 detail: "Only while a place rule or Go There Today needs it. Never saved.", on: locationOn),
            Item(id: "tabs", symbol: "xmark.rectangle.fill", title: "Closing blocked tabs",
                 detail: "Closes tabs of a site when its block starts.", on: closesTabs),
            Item(id: "video", symbol: "play.rectangle.on.rectangle.fill", title: "Video Library tools",
                 detail: "Runs the download tools you installed, in a sandbox.", on: videoLibrary),
        ]
    }

    var body: some View {
        Section {
            ForEach(Self.items(snapshot: model.backendSnapshot, locationOn: model.locationSensor?.isRunning == true,
                               closesTabs: model.closesBlockedTabs, videoLibrary: model.videoLibraryEnabled)) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.symbol)
                        .foregroundStyle(item.on ? Color.shieldAccent : Color.secondary)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                        Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(item.on ? "On" : "Off")
                        .font(.callout)
                        .foregroundStyle(item.on ? .primary : .secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("shieldChange-\(item.id)")
            }
        } header: {
            Text("What Shield changes on this Mac")
        } footer: {
            Text("Remove Shield undoes all of these.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Settings → Permanent blocks (Shield 1.1): how long removing one waits. A
/// longer wait applies at once; a shorter one only after the current wait.
struct PermanentWaitSection: View {
    let model: ShieldViewModel
    static let choices: [TimeInterval] = [1, 2, 3, 7, 14, 30].map { Double($0) * 86_400 }

    var body: some View {
        if let removal = model.permanentRemoval {
            Section {
                Picker("Removing a permanent block waits", selection: Binding(
                    get: { removal.pendingWait ?? removal.wait },
                    set: { _ = model.setPermanentRemovalWait($0) })) {
                    ForEach(Self.choices, id: \.self) { Text(PermanentRemovalPolicy.describe($0)).tag($0) }
                }
                .disabled(!model.canSubmitPolicy)
                .accessibilityIdentifier("permanentRemovalWait")
                if let next = removal.pendingWait, let at = removal.pendingWaitAt {
                    Text("Changes to \(PermanentRemovalPolicy.describe(next)) on \(PlaceDates.short(at, calendar: model.scheduleCalendar)).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Permanent blocks")
            } footer: {
                Text("A longer wait starts now. A shorter one starts after the current wait. Blocks added in the last 10 minutes can be undone at once.")
            }
        }
    }
}

/// Settings → Remove Shield (1.1). It waits like removing a permanent block,
/// and never before a timed block ends; keeping Shield applies at once. A
/// never-removable block keeps Shield installed.
struct RemoveShieldSection: View {
    let model: ShieldViewModel
    @State private var removing = false
    @State private var keeping = false

    var body: some View {
        let state = model.shieldRemovalState()
        if state != .unsupported {
            Section {
                switch state {
                case .pending(let due):
                    LabeledContent {
                        Button("Keep Shield") { keeping = true }
                            .disabled(!model.canSubmitPolicy)
                            .accessibilityIdentifier("keepShield")
                    } label: {
                        Text("Shield will be removed \(date(due)).")
                    }
                case .blocked:
                    Text("A block you made never-removable keeps Shield on this Mac.")
                        .foregroundStyle(.secondary)
                default:
                    Button("Remove Shield…", role: .destructive) { removing = true }
                        .disabled(!model.canSubmitPolicy)
                        .accessibilityIdentifier("removeShield")
                }
            } header: {
                Text("Remove Shield")
            } footer: {
                Text("Every block stays until then. Your Video Library and settings are kept.")
            }
            .shieldConfirmation(isPresented: $removing) {
                let when = model.shieldRemovalDate().map(date) ?? "later"
                return ShieldConfirmation(symbol: "shield.slash.fill", tint: .red, title: "Remove Shield?",
                                          message: "Every block stays until \(when). Then Shield removes itself from this Mac.",
                                          confirmTitle: "Remove Shield", destructive: true,
                                          confirmIdentifier: "confirmRemoveShield") { _ = model.requestShieldRemoval() }
            }
            .shieldConfirmation(isPresented: $keeping) {
                ShieldConfirmation(symbol: "checkmark.shield.fill", tint: .blue, title: "Keep Shield?",
                                   message: "Shield stays on this Mac. Removing it later means waiting again.",
                                   confirmTitle: "Keep Shield",
                                   confirmIdentifier: "confirmKeepShield") { _ = model.keepShield() }
            }
        }
    }

    private func date(_ value: Date) -> String {
        PlaceDates.short(value, calendar: model.scheduleCalendar)
    }
}

/// Settings → Time zone (1.1): the zone schedules run in, and a change by
/// hand waiting its 24 hours.
struct ScheduleZoneSection: View {
    let model: ShieldViewModel

    var body: some View {
        if model.permanentRemoval != nil {
            Section {
                LabeledContent("Schedules use", value: model.scheduleTimeZoneDescription)
                if let zone = model.backendSnapshot?.scheduleZone, let next = zone.pendingIdentifier,
                   let at = zone.pendingAt, let nextZone = TimeZone(identifier: next) {
                    Text("Changes to \(nextZone.localizedName(for: .generic, locale: .current) ?? next) \(PlaceDates.short(at, calendar: model.scheduleCalendar)).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Time zone")
            } footer: {
                Text("When your Mac sets its time zone from your location, schedules switch at once. A time zone changed by hand applies after 24 hours.")
            }
        }
    }
}
