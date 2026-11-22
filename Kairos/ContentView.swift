import AppKit
import SwiftUI

@MainActor
struct ContentView: View {
    @State private var model: ShieldViewModel

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SHIELD_VISUAL_FIXTURE"] == "1" {
            let fixture = makeFixturePreviewModel(persistent: ShieldRuntime.isUIReview)
            if let sectionName = ProcessInfo.processInfo.environment["SHIELD_VISUAL_SECTION"]?.lowercased(),
               let section = ShieldSection.allCases.first(where: {
                   $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "") == sectionName ||
                   ($0 == .studyLibrary && sectionName == "studylibrary") ||
                   ($0 == .diagnostics && sectionName == "diagnostics")
               }) {
                fixture.selectedSection = section
            }
            _model = State(initialValue: fixture)
            return
        }
        #endif
        _model = State(initialValue: ShieldAppHost.shared.model)
        hosted = true
    }

    init(model: ShieldViewModel) {
        _model = State(initialValue: model)
    }

    /// The app's one model (ShieldAppHost keeps it across window close/reopen).
    static func makeDefaultModel() -> ShieldViewModel {
        #if DEBUG
        return ShieldRuntime.isUIReview
            ? makeFixturePreviewModel(persistent: true)
            : ShieldViewModel(xpcClient: FixtureBackendXPCClient(
                serviceName: ProcessInfo.processInfo.environment["SHIELD_CI_XPC_SERVICE"] ??
                    ShieldRuntime.serviceName,
                privileged: ProcessInfo.processInfo.environment["SHIELD_CI_PRIVILEGED_XPC"] == "1"))
        #else
        return ShieldViewModel(xpcClient: FixtureBackendXPCClient(privileged: true))
        #endif
    }
    /// True for the app's own model; previews and fixtures own theirs.
    private var hosted = false
    @State private var showingFirstRun = false

    /// Category IDs drilled into from Protection, "place:" pages from Places,
    /// or "video:"/"transcript:" player routes on the Library stack.
    @State private var path: [String] = []
    /// Players opened from Library, checked when the user asked (never while
    /// the destination view is being built).
    @State private var players: [String: StudyPlaybackSelection] = [:]
    /// Hidden while the player is in theater or full screen.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    private func openPlayer(_ id: String, transcript: Bool, replacing: Bool = false) {
        guard let selection = model.playbackSelection(for: id, transcript: transcript) else { return }
        let route = (transcript ? "transcript:" : "video:") + id
        players[route] = selection
        if replacing, !path.isEmpty { path.removeLast() }
        path.append(route)
    }

    #if DEBUG
    /// Snapshot/visual-review entry point with a pre-pushed drill-down route.
    init(model: ShieldViewModel, initialPath: [String]) {
        _model = State(initialValue: model)
        _path = State(initialValue: initialPath)
    }
    #endif

    /// Sidebar rows: the app sections, and Library's collections.
    private enum SidebarItem: Hashable {
        case section(ShieldSection)
        case collection(String)
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding {
            // An older download folder isn't a sidebar row; nothing is
            // highlighted, so clicking Library or a collection goes back.
            if model.selectedSection == .studyLibrary && model.isShowingOlderLibrary { return nil }
            if model.selectedSection == .studyLibrary, let id = model.selectedCollectionID {
                return .collection(id)
            }
            return model.selectedSection.map { .section($0) }
        } set: { item in
            switch item {
            case .section(let section):
                model.selectedSection = section
                if section == .studyLibrary {
                    model.selectedCollectionID = nil
                    if model.isShowingOlderLibrary { model.openLibrary() }
                }
            case .collection(let id):
                model.selectedSection = .studyLibrary
                model.selectedCollectionID = id
                if model.isShowingOlderLibrary { model.openLibrary() }
            case nil: break
            }
        }
    }

    private func navigationID(_ section: ShieldSection) -> String {
        section == .studyLibrary ? "nav-studylibrary" : (section == .diagnostics ? "nav-diagnostics" :
            "nav-\(section.rawValue.lowercased().replacingOccurrences(of: " ", with: ""))")
    }

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Native selection semantics: no Button nested inside a selectable
            // List row.
            List(selection: sidebarSelection) {
                // Schedules live on Protection's Today timeline.
                // Library is the Video Library add-on: shown once it's added.
                ForEach(ShieldSection.allCases.filter {
                    $0 != .schedules && ($0 != .studyLibrary || model.videoLibraryEnabled)
                }) { section in
                    Label(section.rawValue, systemImage: section.symbol)
                        .modifier(MarketingSidebarText())
                        .tag(SidebarItem.section(section))
                        .accessibilityLabel(section.rawValue)
                        .accessibilityIdentifier(navigationID(section))
                }
                if model.videoLibraryEnabled && !model.collectionLayout.collections.isEmpty {
                    Section("Collections") {
                        ForEach(model.collectionLayout.collections) { collection in
                            Label {
                                Text(collection.name).lineLimit(1)
                            } icon: {
                                CategoryIcon(symbol: collection.symbol, tint: collection.color.color, size: 18)
                            }
                            .tag(SidebarItem.collection(collection.id))
                            .accessibilityIdentifier("collection-\(collection.id)")
                            .contextMenu {
                                Button("Edit Collection…") { model.collectionEditor = .existing(collection) }
                                Button("Move Up") { model.moveCollection(collection.id, by: -1) }
                                    .disabled(model.collectionLayout.collections.first?.id == collection.id)
                                Button("Move Down") { model.moveCollection(collection.id, by: 1) }
                                    .disabled(model.collectionLayout.collections.last?.id == collection.id)
                                Divider()
                                Button("Delete Collection…", role: .destructive) {
                                    model.collectionPendingDelete = collection
                                }
                            }
                        }
                        // Drag to reorder; Library's collection tiles follow the same order.
                        .onMove { source, destination in
                            withAnimation(.snappy) { model.moveCollections(fromOffsets: source, toOffset: destination) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            #if DEBUG
            // Release has no footer. An inset around the resulting empty view
            // collapsed the sidebar scroll view to zero height: rows
            // still drew but no click reached them, so the sidebar was dead.
            .safeAreaInset(edge: .bottom, spacing: 0) { RuntimeModeFooter(model: model) }
            #endif
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            // Notices float over each page, never above the
            // whole stack pushing it down. Not a safeAreaInset either: an inset
            // around an empty view broke the sidebar.
            VStack(spacing: 0) {
                NavigationStack(path: $path) {
                    sectionContent
                        .modifier(FloatingNoticeHost(model: model))
                        .navigationDestination(for: String.self) { route in
                            if route.hasPrefix("video:") || route.hasPrefix("transcript:") {
                                if let selection = players[route] {
                                    // Next plays in the same player (The
                                    // arrow did nothing when it swapped the page instead).
                                    StudyPlayerView(selection: selection,
                                                    title: { model.videoTitle($0) },
                                                    nextID: { model.nextSavedVideo(after: $0) },
                                                    selectionFor: { model.playbackSelection(for: $0) },
                                                    onTheater: { on in
                                                        withAnimation(.snappy) { columnVisibility = on ? .detailOnly : .automatic }
                                                    },
                                                    onLeave: { model.reloadPlaybackProgress(for: $0) })
                                } else {
                                    ShieldEmptyState(title: "Video unavailable", symbol: "play.slash",
                                                     message: "Go back and try again.", tint: .secondary, fillsPage: true)
                                        .background(Color.shieldPage)
                                }
                            } else if route.hasPrefix("place:") {
                                PlaceDetailPage(placeID: String(route.dropFirst("place:".count)), model: model)
                                    .modifier(FloatingNoticeHost(model: model))
                            } else {
                                RuleGroupDetailPage(categoryID: route, model: model)
                                    .modifier(FloatingNoticeHost(model: model))
                            }
                        }
                }
                .id(model.selectedSection ?? .protection)
            }
        }
        .focusedSceneValue(\.navigateBack, path.isEmpty ? nil : { path.removeLast() })
        .focusedSceneValue(\.shieldModel, model)
        .frame(minWidth: 760, minHeight: 560)
        #if DEBUG
        .background { VisualFixtureWindowSizer() }
        .preferredColorScheme(Self.reviewColorScheme)
        #endif
        .onChange(of: model.selectedSection) { _, _ in path = [] }
        .onChange(of: model.selectedCollectionID) { _, _ in
            if model.selectedSection == .studyLibrary { path = [] }
        }
        .sheet(item: $model.collectionEditor) { target in
            StudyCollectionEditor(model: model, existing: target.collection, addingVideoIDs: target.videoIDs)
        }
        .shieldConfirmation(isPresented: Binding(get: { model.collectionPendingDelete != nil },
                                                 set: { if !$0 { model.collectionPendingDelete = nil } })) {
            let collection = model.collectionPendingDelete
            return ShieldConfirmation(symbol: "trash.fill", tint: .red,
                                      title: "Delete “\(collection?.name ?? "")”?",
                                      message: "Its videos stay in Library.",
                                      confirmTitle: "Delete Collection", destructive: true,
                                      confirmIdentifier: "confirmDeleteCollection") {
                if let collection { model.deleteCollection(collection.id) }
            }
        }
        // First run (public release): once, after Shield first hears from its
        // service, and only for someone with no blocks yet.
        .onChange(of: model.backendSnapshot == nil, initial: true) { _, missing in
            guard hosted, !missing else { return }
            if FirstRunSetup.takeAutomaticShow(ruleCount: FirstRunSetup.ruleCount(model.backendSnapshot)) {
                showingFirstRun = true
            }
        }
        .sheet(isPresented: $showingFirstRun) { FirstRunSetupView(model: model) }
        .shieldConfirmation(isPresented: Binding(get: { model.permissionAsk != nil },
                                                 set: { if !$0 { model.answerPermissionAsk(false) } })) {
            PermissionScreen.confirmation(for: model.permissionAsk ?? .location) { model.answerPermissionAsk(true) }
        }
        .task {
            if hosted { ShieldAppHost.shared.windowAppeared() } else { model.start() }
        }
        .onDisappear {
            if hosted { ShieldAppHost.shared.windowDisappeared() } else { model.stop() }
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch model.selectedSection ?? .protection {
        case .protection, .schedules:
            ProtectionView(model: model)
        case .places:
            PlacesView(model: model)
        case .studyLibrary:
            if model.videoLibraryEnabled {
                StudyLibraryView(model: model) { id, transcript in openPlayer(id, transcript: transcript) }
            } else {
                ProtectionView(model: model)
            }
        case .diagnostics:
            DiagnosticsView(model: model)
        }
    }

    #if DEBUG
    // nil would follow a system Dark Mode and override the requested light
    // review appearance, so both review appearances are explicit.
    private static var reviewColorScheme: ColorScheme? {
        switch ProcessInfo.processInfo.environment["SHIELD_VISUAL_APPEARANCE"] {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    #endif

}

#if DEBUG
private struct VisualFixtureWindowSizer: NSViewRepresentable {
    final class SizingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard ProcessInfo.processInfo.environment["SHIELD_VISUAL_FIXTURE"] == "1",
                  let window else { return }
            Self.applyFixtureSize(to: window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak window] in
                guard let window else { return }
                Self.applyFixtureSize(to: window)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak window] in
                guard let window else { return }
                Self.applyFixtureSize(to: window)
            }
        }

        private static func applyFixtureSize(to window: NSWindow) {
            // Never fight a fullscreen transition the reviewer started.
            guard !window.styleMask.contains(.fullScreen) else { return }
            let mode = ProcessInfo.processInfo.environment["SHIELD_VISUAL_SIZE"] ?? "standard"
            let compact = mode == "compact"
            let size = switch mode {
            case "compact": CGSize(width: 860, height: 560)
            case "wide": CGSize(width: 1680, height: 1000)
            default: CGSize(width: 1000, height: 625)
            }
            if abs(window.contentLayoutRect.width - size.width) > 1 ||
               abs(window.contentLayoutRect.height - size.height) > 1 {
                let current = window.contentView?.bounds.size ?? size
                window.setContentSize(CGSize(width: current.width + size.width - window.contentLayoutRect.width,
                                             height: current.height + size.height - window.contentLayoutRect.height))
                window.center()
            }
            // Without a requested appearance the window follows Settings ▸ Appearance.
            if let requested = ProcessInfo.processInfo.environment["SHIELD_VISUAL_APPEARANCE"] {
                window.appearance = NSAppearance(named: requested == "dark" ? .darkAqua : .aqua)
            }
            if let directory = ProcessInfo.processInfo.environment["SHIELD_VISUAL_METRICS_DIR"],
               let section = ProcessInfo.processInfo.environment["SHIELD_VISUAL_SECTION"],
               let appearance = ProcessInfo.processInfo.environment["SHIELD_VISUAL_APPEARANCE"] {
                let label = compact ? "compact" : (mode == "wide" ? "wide" : "standard")
                let measured = window.contentLayoutRect.size
                let line = "\(appearance)-\(label)-\(section): \(Int(measured.width))x\(Int(measured.height))\n"
                let file = URL(fileURLWithPath: directory, isDirectory: true)
                    .appendingPathComponent("\(appearance)-\(label)-\(section).window.txt")
                try? line.write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }

    func makeNSView(context: Context) -> SizingView { SizingView() }
    func updateNSView(_ view: SizingView, context: Context) {}
}
#endif

#Preview {
    ContentView(model: makeFixturePreviewModel())
}

/// Throwaway preview folders from earlier runs (each run makes a new one).
/// Only this app's own temporary folder, only names it made, only over an hour old.
private func removeStalePreviewFolders(now: Date = .now) {
    let fileManager = FileManager.default
    let temporary = fileManager.temporaryDirectory
    guard let names = try? fileManager.contentsOfDirectory(atPath: temporary.path) else { return }
    for name in names where name.hasPrefix("ShieldPreview-") && UUID(uuidString: String(name.dropFirst(14))) != nil {
        let url = temporary.appendingPathComponent(name, isDirectory: true)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, let modified = values.contentModificationDate,
              now.timeIntervalSince(modified) > 3_600 else { continue }
        try? fileManager.removeItem(at: url)
    }
}

// Internal (not private) so the DEBUG offscreen snapshot harness can build the
// same simulated fixture. `preparedPlan` forces the six example
// schedules and permanent groups without relying on process environment.
@MainActor
func makeFixturePreviewModel(persistent: Bool = false, preparedPlan: Bool = false) -> ShieldViewModel {
    if !persistent { removeStalePreviewFolders() }
    do {
        let root = persistent ? ShieldRuntime.fixtureDirectory :
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "ShieldPreview-\(UUID().uuidString)", isDirectory: true)
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let backend = try FixtureBackend(root: root)
        if FileManager.default.fileExists(atPath: backend.paths.journal.path) {
            _ = try backend.recover(now: .now, calendar: .current)
        }
        if !FileManager.default.fileExists(atPath: backend.paths.document.path) {
            guard !FileManager.default.fileExists(atPath: backend.paths.hosts.path),
                  !FileManager.default.fileExists(atPath: backend.paths.authority.path),
                  !FileManager.default.fileExists(atPath: backend.paths.key.path) else {
                throw FixtureBackendError.uncertain("An incomplete development backend needs inspection.")
            }
            try Data("127.0.0.1 localhost\n".utf8).write(to: backend.paths.hosts)
            var commands: [BackendCommand] = [
                                        .add(DomainRestriction(owner: .permanent, policyID: "preview-hard",
                                                               title: "Focus protection", domains: ["example.com"])),
                                        .add(DomainRestriction(owner: .commitment, policyID: "preview-study",
                                                               title: "Study block", domains: ["study.example"]))
                                     ]
            #if DEBUG
            // Only explicit UI-polish screenshots use the six exact schedule
            // templates and separate permanent owners. No installed authority.
            if preparedPlan || ProcessInfo.processInfo.environment["SHIELD_UI_POLISH_FIXTURE"] == "1" {
                commands = ShieldPreparedPlan.commands(at: .now)
            }
            // Click-tests of place blocks: one saved place, so New Block offers
            // "Only at Library" without Core Location.
            if ProcessInfo.processInfo.environment["SHIELD_UI_TEST_PLACES"] == "1" {
                commands.append(.add(RulePlace(id: "test-library", name: "Library", latitude: 40.7532,
                                               longitude: -73.9822, radiusMeters: 200, wifiTags: [])))
            }
            #endif
            if ProcessInfo.processInfo.environment["SHIELD_UI_TEST_BLOCK_FETCH"] == "1" {
                commands.append(.add(DomainRestriction(owner: .permanent, policyID: "test-video-block",
                    title: "Test YouTube block", domains: ["youtube.com"])))
            }
            let request = BackendRequest(version: 1, id: UUID(), expectedGeneration: 0,
                                         submittedAt: .now, commands: commands)
            _ = try backend.apply(request, now: .now, calendar: .current)
        }
        var libraryRoot = persistent ? ShieldRuntime.supportDirectory.appendingPathComponent("StudyLibrary")
                                     : root.appendingPathComponent("study")
        #if DEBUG
        // Previews: a COPY of a library folder, so the new Library home
        // can be seen with real videos. Never the installed app's own folder.
        if !ShieldRuntime.isUIReview, let copy = ProcessInfo.processInfo.environment["SHIELD_PREVIEW_LIBRARY"],
           copy.hasPrefix("/"), !copy.contains("/ShieldRC/") {
            libraryRoot = URL(fileURLWithPath: copy, isDirectory: true)
        }
        #endif
        return ShieldViewModel(authorityReader: AuthorityStateReader(fileURL: backend.paths.authority),
                               enforcementReader: HostsEnforcementReader(fileURL: backend.paths.hosts),
                               studyLibraryRoot: libraryRoot,
                               fixtureBackend: backend,
                               studyToolsOverride: ProcessInfo.processInfo.environment["SHIELD_UI_TEST_MISSING_TOOLS"] == "1"
                                   ? StudyTools(ytdlp: root.appendingPathComponent("missing-yt-dlp"),
                                                deno: root.appendingPathComponent("missing-deno"),
                                                ffmpeg: root.appendingPathComponent("missing-ffmpeg"),
                                                ffprobe: root.appendingPathComponent("missing-ffprobe")) : nil)
    } catch {
        #if DEBUG
        let root = ShieldRuntime.fixtureDirectory
        return ShieldViewModel(authorityReader: AuthorityStateReader(fileURL: root.appendingPathComponent("authority.plist")),
                               enforcementReader: HostsEnforcementReader(fileURL: root.appendingPathComponent("hosts")),
                               studyLibraryRoot: ShieldRuntime.supportDirectory.appendingPathComponent("StudyLibrary"))
        #else
        return ShieldViewModel()
        #endif
    }
}

/// The window's notices, shown like Mac notifications in the
/// top-right corner: a Go There day, "reopen your browser" after a site
/// opens, and the page's own (handed up with `PageNoticeKey`). One stack, so
/// they never cover each other. The video player has none: they'd sit over
/// the picture.
struct FloatingNoticeHost: ViewModifier {
    let model: ShieldViewModel
    @State private var hidden: Set<String> = []

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(PageNoticeKey.self, alignment: .topTrailing) { notices in
            let shown = notices.filter { !hidden.contains($0.id) }
            VStack(alignment: .trailing, spacing: 10) {
                GoDayBar(model: model)
                ReopenBrowserNotice(model: model)
                ForEach(shown, id: \.id) { notice in
                    notice.bar.closing { withAnimation(.snappy(duration: 0.2)) { _ = hidden.insert(notice.id) } }
                }
            }
            .padding(.top, 14)
            .padding(.trailing, 18)
            .animation(.snappy(duration: 0.3), value: shown.map(\.id))
        }
    }
}
