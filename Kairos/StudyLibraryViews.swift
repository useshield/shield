import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Library: the videos of the collection chosen in the sidebar (or all of
// them). Collections only organize; deleting one never deletes a video.
// Adding is ⌘V, drop, or the toolbar; rows show actions on hover.

struct StudyLibraryView: View {
    @Bindable var model: ShieldViewModel
    /// Opens the player for a video (transcript first when true).
    var onPlay: (String, Bool) -> Void = { _, _ in }

    @State private var search = ""
    @State private var filter = Filter.all
    @State private var selection: String?
    @State private var addingLinks = false
    @State private var linkText = ""
    @State private var isDropTarget = false
    @State private var renamingVideoID: String?
    @State private var renameText = ""
    @State private var deletingVideoID: String?
    @State private var errorDetails: String?
    @State private var confirmingExperimentalDownloads = false
    @State private var rebuildingLibrary = false
    @State private var recoveringList = false
    @State private var stopping = false
    // One file importer serves both imports: SwiftUI reliably presents only
    // one .fileImporter per view.
    private enum ImportKind { case collection, media }
    @State private var importKind = ImportKind.collection
    @State private var importing = false
    @State private var importingVideoID: String?
    /// The Library opens on its front page; All Videos is the full list.
    @State private var showingAllVideos = false

    private enum Filter: String, CaseIterable {
        case all = "All Videos", unsaved = "Not Saved", saved = "Saved", problems = "Problems"
    }

    // MARK: Derived state

    private var busy: Bool { model.isDownloading || model.isRestoringStudy }
    private var collection: StudyCollection? {
        model.isShowingOlderLibrary ? nil : model.selectedCollectionID.flatMap(model.collectionLayout.collection)
    }
    private var scopeJobs: [StudyJob] { model.libraryJobs(in: collection?.id) }
    private var scopeTitle: String {
        model.isShowingOlderLibrary ? (model.studyManifestTitle ?? "Older Downloads") : (collection?.name ?? "Library")
    }

    private func fullTitle(_ job: StudyJob) -> String {
        model.isShowingLinkQueue ? model.libraryTitle(job.id) : job.title
    }

    /// The words every title in view starts with ("Algebra Course - Lesson "),
    /// so rows can show only what differs.
    private var sharedPrefix: String {
        let titles = scopeJobs.map(fullTitle)
        guard titles.count >= 3, var prefix = titles.first else { return "" }
        for title in titles.dropFirst() {
            while !title.hasPrefix(prefix) { prefix.removeLast() }
            if prefix.isEmpty { return "" }
        }
        guard let space = prefix.lastIndex(of: " "),
              prefix.distance(from: prefix.startIndex, to: space) >= 10 else { return "" }
        return String(prefix[...space])
    }

    private func shortTitle(_ job: StudyJob, prefix: String) -> String {
        let title = fullTitle(job)
        guard !prefix.isEmpty, title.hasPrefix(prefix), title.count > prefix.count + 2 else { return title }
        return String(title.dropFirst(prefix.count))
    }


    private var visibleJobs: [StudyJob] {
        scopeJobs.filter { job in
            guard search.isEmpty || fullTitle(job).localizedCaseInsensitiveContains(search) ||
                    job.id.localizedCaseInsensitiveContains(search) else { return false }
            switch filter {
            case .all: return true
            case .unsaved: return !job.isSaved
            case .saved: return job.isSaved
            case .problems: return job.isFailed
            }
        }
    }

    /// Videos a Download click would fetch.
    private var remaining: Int { scopeJobs.count(where: model.isDownloadable) }
    private var problems: Int { scopeJobs.count(where: \.isFailed) }
    private var retryable: Int {
        scopeJobs.filter { failure($0).map { $0.action == .retry || $0.action == .downloadAgain } ?? false }.count
    }

    private var downloadBlockedReason: String? {
        if let reason = model.studyFetchBlockReason {
            return reason.contains("blocks YouTube") ? "Downloads are paused while YouTube is blocked." : reason
        }
        if busy { return "Wait for the current task to finish." }
        if !model.canDownloadStudyCourse { return "Downloads aren't available here." }
        return nil
    }
    private var canDownload: Bool { downloadBlockedReason == nil }

    private func failure(_ job: StudyJob) -> StudyFailureText? {
        guard case .failed(let raw) = job.state else { return nil }
        return .describe(raw, signInFilePresent: model.signInFilePresent)
    }

    private func takeCommand() {
        guard model.command == .addVideos else { return }
        model.command = nil
        // ⌘L from an older download folder goes back to the library first.
        if model.isShowingOlderLibrary { model.openLibrary() }
        if canAddLinks { addingLinks = true }
    }

    private var canAddLinks: Bool { model.canAddVideoLinks && !model.isShowingOlderLibrary }

    /// The Library's front page: no collection, not all videos, not an older folder.
    private var isLibraryHome: Bool {
        collection == nil && !model.isShowingOlderLibrary && !showingAllVideos
    }

    private func goToLibraryHome() {
        if model.isShowingOlderLibrary { model.openLibrary() }
        model.selectedCollectionID = nil
        showingAllVideos = false
        selection = nil
        search = ""
        filter = .all
    }

    private func addLinks(_ text: String) {
        guard canAddLinks, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if model.addVideoLinks(text, toCollection: collection?.id) {
            linkText = ""
            addingLinks = false
            // New rows are where they can be seen being added.
            if collection == nil { showingAllVideos = true }
        }
    }

    // MARK: Body

    var body: some View {
        content.frame(maxHeight: .infinity)
            .buttonStyle(ShieldPillButtonStyle())
            // Floats with the window's other notices, not as a bar pushing the page down.
            .preference(key: PageNoticeKey.self, value: notice.map { [PageNotice(bar: $0)] } ?? [])
            // A containing element: its children keep their own identifiers.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("pageScrollView")
            .navigationTitle(scopeTitle)
            .navigationSubtitle(subtitle)
            .searchable(text: $search, placement: .toolbar, prompt: "Search")
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom, spacing: 0) { statusBar }
            .onPasteCommand(of: [.plainText, .url]) { _ in
                if let text = NSPasteboard.general.string(forType: .string) { addLinks(text) }
            }
            .dropDestination(for: String.self) { values, _ in
                guard canAddLinks else { return false }
                addLinks(values.joined(separator: "\n"))
                return !values.isEmpty
            } isTargeted: { isDropTarget = $0 }
            .overlay {
                if isDropTarget {
                    ShieldBubble.shape.strokeBorder(.tint, lineWidth: 2).padding(6)
                        .allowsHitTesting(false)
                }
            }
            .background(Color.shieldPage)
            .buttonBorderShape(.capsule)
            .sheet(isPresented: $addingLinks) { addPopover }
            .sheet(isPresented: Binding(get: { renamingVideoID != nil }, set: { if !$0 { renamingVideoID = nil } })) {
                RenameSheet(title: "Rename Video", subtitle: "",
                            current: renameText, fieldIdentifier: "renameVideoName", saveIdentifier: "confirmRenameVideo") { name in
                    if let id = renamingVideoID { model.renameVideo(id, to: name) }
                }
            }
            .alert("Download Details", isPresented: Binding(get: { errorDetails != nil },
                                                           set: { if !$0 { errorDetails = nil } })) {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(errorDetails ?? "", forType: .string)
                }
                Button("OK", role: .cancel) {}
            } message: { Text(errorDetails ?? "") }
            .shieldConfirmation(isPresented: Binding(get: { deletingVideoID != nil },
                                                     set: { if !$0 { deletingVideoID = nil } })) {
                let id = deletingVideoID
                let saved = id.flatMap { id in model.studyJobs.first { $0.id == id } }.map(\.isSaved) == true
                return ShieldConfirmation(symbol: "trash.fill", tint: .red, title: "Delete this video?",
                                          message: saved ? "It's removed from every collection and its saved file is deleted."
                                                         : "It's removed from your library and every collection.",
                                          confirmTitle: "Delete Video", destructive: true,
                                          confirmIdentifier: "confirmDeleteVideo") {
                    if let id { model.deleteVideo(id) }
                }
            }
            .shieldConfirmation(isPresented: $confirmingExperimentalDownloads) {
                ShieldConfirmation(symbol: "flask.fill", tint: .orange,
                                   title: "Enable experimental downloads for this session?",
                                   message: "Use only content you're allowed to download. This ends when you quit.",
                                   confirmTitle: "Enable for This Session",
                                   confirmIdentifier: "confirmExperimentalDownloads") {
                    model.setExperimentalDownloadsEnabled(true)
                }
            }
            .shieldConfirmation(isPresented: $rebuildingLibrary) {
                ShieldConfirmation(symbol: "arrow.triangle.2.circlepath", tint: .blue, title: "Rebuild the library index?",
                                   message: "Saved videos are checked again. Nothing is deleted.",
                                   confirmTitle: "Rebuild Index", confirmIdentifier: "confirmRebuildIndex") {
                    model.rebuildStudyIndex()
                }
            }
            .shieldConfirmation(isPresented: $recoveringList) {
                ShieldConfirmation(symbol: "tray.full.fill", tint: .orange, title: "Start a new video list?",
                                   message: "The unreadable list is kept as a backup. Saved files stay in place.",
                                   confirmTitle: "Archive and Start Fresh", confirmIdentifier: "confirmRecoverList") {
                    model.recoverDownloadQueue()
                }
            }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: importKind == .collection ? [.json]
                            : (importingVideoID == nil ? [.folder, .mpeg4Movie] : [.mpeg4Movie]),
                          allowsMultipleSelection: importKind == .media && importingVideoID == nil) { result in
                switch (importKind, result) {
                case (.collection, .success(let urls)): if let url = urls.first { model.importCollectionFile(from: url) }
                case (.media, .success(let urls)):
                    let id = importingVideoID
                    importingVideoID = nil
                    model.beginMediaImport(from: urls, forVideoID: id)
                case (_, .failure(let error)): model.reportStudyError(error)
                }
            }
            .onChange(of: model.selectedCollectionID) { _, _ in
                filter = .all; selection = nil; showingAllVideos = false; search = ""
            }
            .onChange(of: model.isDownloading) { _, downloading in if !downloading { stopping = false } }
            .onAppear { takeCommand() }
            .onChange(of: model.command) { _, _ in takeCommand() }
    }

    private var subtitle: String {
        let jobs = scopeJobs
        guard !jobs.isEmpty, !showsHome else { return "" }
        return "\(jobs.count) video\(jobs.count == 1 ? "" : "s")"
    }

    private var showsHome: Bool {
        collection == nil && !model.isShowingOlderLibrary && !showingAllVideos && search.isEmpty && filter == .all
    }

    @ViewBuilder private var content: some View {
        if scopeJobs.isEmpty {
            // In a scroll view like every other page: a bare empty page
            // pushed the sidebar up under the window buttons.
            GeometryReader { page in
                ScrollView { emptyState.frame(minHeight: page.size.height) }
                    .scrollIndicators(.never)
                    .modifier(HardTopEdge())
            }
        } else if showsHome {
            LibraryHomeView(model: model, title: fullTitle, onPlay: { onPlay($0, false) },
                            onShowAll: { showingAllVideos = true },
                            onDownload: { showingAllVideos = true; model.downloadVideos(in: nil) },
                            downloadBlockedReason: downloadBlockedReason)
        } else if visibleJobs.isEmpty {
            ShieldEmptyState(title: search.isEmpty ? "Nothing here" : "No results", symbol: "magnifyingglass",
                             message: search.isEmpty ? "No videos match “\(filter.rawValue)”." : "No videos match “\(search)”.",
                             fillsPage: true) {
                Button("Show All Videos") { search = ""; filter = .all }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("resetLibraryFilter")
            }
            .background(Color.shieldPage)
        } else {
            list
        }
    }

    private var list: some View {
        let prefix = sharedPrefix
        let order = Dictionary(scopeJobs.enumerated().map { ($0.element.id, $0.offset + 1) },
                               uniquingKeysWith: { first, _ in first })
        return List(selection: $selection) {
            ForEach(visibleJobs) { job in
                row(job, number: order[job.id] ?? 0, title: shortTitle(job, prefix: prefix))
                    .tag(job.id)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .background(Color.shieldPage)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let job = scopeJobs.first(where: { $0.id == id }) { actions(job) }
        } primaryAction: { ids in
            if let id = ids.first, let job = scopeJobs.first(where: { $0.id == id }) { primary(job) }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.isShowingOlderLibrary {
            ShieldEmptyState(title: "No videos", symbol: "archivebox", tint: .secondary, fillsPage: true)
        } else if let collection {
            ShieldEmptyState(title: "Nothing here yet", symbol: collection.symbol,
                             message: "Paste YouTube links with ⌘V, or add videos from Library.",
                             messageIdentifier: "emptyCollection", tint: collection.color.color, fillsPage: true) {
                Button("Add Videos…") { addingLinks = true }.buttonStyle(.borderedProminent).disabled(!canAddLinks)
            }
        } else {
            // No built-in course offered here; a library starts empty.
            ShieldEmptyState(title: "No videos yet", symbol: "play.rectangle.on.rectangle",
                             message: "Paste YouTube links with ⌘V or drop them here.",
                             messageIdentifier: "localImportPrerequisite", fillsPage: true) {
                Button("Add Videos…") { addingLinks = true }.buttonStyle(.borderedProminent).disabled(!canAddLinks)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        // Every page under Library (all videos, a collection,
        // an older download folder) has a way back to the Library's front page.
        if !isLibraryHome {
            ToolbarItem(placement: .navigation) {
                Button { goToLibraryHome() } label: {
                    Label("Library Home", systemImage: "chevron.left")
                }
                .help("Back to the Library's front page")
                .accessibilityIdentifier("backToLibraryHome")
            }
        }
        // The same blue + as Protection; it opens Add Videos directly.
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .primaryAction) { addButton }.sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
        } else {
            ToolbarItem(placement: .primaryAction) { addButton }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if model.studyExecutionAvailable && remaining > 0 && !showsHome {
                Button {
                    model.downloadVideos(in: collection?.id)
                } label: {
                    Label("Download \(min(remaining, ShieldViewModel.downloadBatchLimit))", systemImage: "arrow.down.circle")
                        .labelStyle(.titleAndIcon)
                }
                .help(downloadBlockedReason ?? "Download the videos that aren't saved yet")
                .disabled(!canDownload || (model.isShowingOlderLibrary && !model.studyCourseApproved))
                .accessibilityIdentifier("downloadRemaining")
            }
            Menu {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Show", systemImage: filter == .all ? "line.3.horizontal.decrease.circle"
                                                           : "line.3.horizontal.decrease.circle.fill")
            }
            .help("Show")
            .accessibilityIdentifier("libraryFilter")
            Menu { moreMenu } label: { Label("More", systemImage: "ellipsis") }
                .menuIndicator(.hidden)
                .help("More")
                .accessibilityIdentifier("downloadsMenu")
        }
    }

    private var addButton: AddMenuButton {
        AddMenuButton(items: [AddMenuItem(title: "Add Videos…", identifier: "addVideosItem", enabled: canAddLinks) {
            addingLinks = true
        }], help: canAddLinks ? "Add YouTube links (⌘V also works)" : "Available when the current task finishes",
           identifier: "addVideos")
    }

    @ViewBuilder private var moreMenu: some View {
        Button("New Collection…") { model.collectionEditor = .new }
            .disabled(!model.canAddCollection)
        if let collection {
            Button("Edit “\(collection.name)”…") { model.collectionEditor = .existing(collection) }
            Button("Delete “\(collection.name)”…", role: .destructive) { model.collectionPendingDelete = collection }
        }
        // A collection's videos share one library folder, so Finder shows that
        // folder with this collection's files selected.
        Button("Show in Finder") { showInFinder(collection?.videoIDs) }
            .disabled(model.savedFilesFolder == nil)
            .accessibilityIdentifier("showLibraryInFinder")
        if model.isShowingOlderLibrary && model.studyExecutionAvailable && !model.studyCourseApproved {
            Button("Allow Downloads for This Folder") { model.approveStudyCourse() }
                .disabled(busy)
                .accessibilityIdentifier("approveStudyCourse")
        }
        Divider()
        Button("Import MP4 Files…") { importingVideoID = nil; importKind = .media; importing = true }
            .disabled(!ShieldRuntime.allowsLocalMediaImport || model.studyManifestTitle == nil || busy)
        Button("Import Collection File…") { importKind = .collection; importing = true }
            .disabled(ShieldRuntime.isUIReview || busy)
        let older = model.savedCourses.filter { !$0.isLinkQueue && (model.olderLibraryCounts[$0.selectionKey] ?? 0) > 0 }
        if !older.isEmpty {
            Menu("Older Downloads") {
                ForEach(older, id: \.selectionKey) { course in
                    Button(course.courseTitle) { model.openSavedCourse(course) }
                }
            }
            .disabled(busy)
        }
        if model.canEnableExperimentalDownloads && !model.containedDownloadsAvailable {
            Divider()
            if model.experimentalDownloadsEnabled {
                Button("Turn Off Experimental Downloads") { model.setExperimentalDownloadsEnabled(false) }
            } else {
                Button("Enable Experimental Downloads…") { confirmingExperimentalDownloads = true }
                    .accessibilityIdentifier("enableExperimentalDownloads")
            }
        }
    }

    private var addPopover: some View {
        VStack(spacing: 0) {
            EditorSheetHeader(symbol: "plus", tint: .shieldAccent, title: "Add Videos",
                              subtitle: "To \(collection?.name ?? "Library")")
            Form {
                Section {
                    TextField("YouTube links", text: $linkText, prompt: Text("youtube.com/watch?v=…"), axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("youtubeLinkInput")
                }
            }
            .formStyle(.bubble)
            HStack {
                Button("Paste") {
                    if let value = NSPasteboard.general.string(forType: .string) {
                        linkText = linkText.isEmpty ? value : linkText + "\n" + value
                    }
                }
                .accessibilityIdentifier("pasteYouTubeLinks")
                Spacer()
                Button("Cancel") { addingLinks = false }.keyboardShortcut(.cancelAction)
                Button("Add") { addLinks(linkText) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.prominentWhenEnabled)
                    .disabled(linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !canAddLinks)
                    .accessibilityIdentifier("queueYouTubeLinks")
            }
            .shieldSheetFooter()
        }
        .frame(width: 460)
        .shieldSheet()
    }

    // MARK: Notice and status bar

    private var notice: NoticeBar? {
        if model.queueReadError {
            return NoticeBar(kind: .warning, text: "Your video list couldn't be read.",
                      action: ("Start Fresh…", { recoveringList = true }))
        } else if model.pendingLibraryRecovery != nil {
            return NoticeBar(kind: .warning, text: "The library index needs repair.",
                      action: ShieldRuntime.isUIReview ? nil : ("Rebuild…", { rebuildingLibrary = true }))
        } else if let problem = model.studyPersistenceError ?? model.collectionNotice {
            return NoticeBar(kind: .warning, text: problem, action: nil)
        } else if model.isShowingOlderLibrary {
            return NoticeBar(kind: .info, text: "An older download folder from an earlier version.",
                      action: busy ? nil : ("Back to Library", { model.openLibrary() }))
        } else if problems > 0 && !busy && !showsHome {
            return NoticeBar(kind: .warning,
                      text: "\(problems) video\(problems == 1 ? "" : "s") couldn't download.",
                      action: canDownload && retryable > 0 ? ("Retry All", { model.retryFailedVideos(in: collection?.id) }) : nil)
        } else if remaining > 0, model.studyExecutionAvailable, !showsHome, let reason = model.studyFetchBlockReason {
            return NoticeBar(kind: .info, text: reason.contains("blocks YouTube")
                      ? "Downloads are paused while YouTube is blocked." : reason, action: nil,
                      identifier: "downloadAvailability")
        }
        return nil
    }

    @ViewBuilder private var statusBar: some View {
        if model.isDownloading {
            let batch = model.studyJobs.filter { model.downloadBatchIDs.contains($0.id) }
            let total = max(1, model.downloadBatchIDs.count)
            let done = batch.count { ($0.isSaved && !model.redownloadingIDs.contains($0.id)) || $0.isFailed }
            let current = batch.first {
                switch $0.state { case .downloading, .validating: true; default: false }
            }
            BottomBar {
                ProgressView(value: Double(done), total: Double(total)).frame(width: 120)
                Text("Downloading \(min(done + 1, total)) of \(total)" +
                     (current.map { " · " + shortTitle($0, prefix: sharedPrefix) } ?? ""))
                    .lineLimit(1)
                Spacer()
                Button(stopping ? "Stopping…" : "Stop") { stopping = true; model.cancelDownloads() }
                    .disabled(stopping)
                    .accessibilityIdentifier("cancelDownloads")
            }
        } else if model.isImportingMedia {
            BottomBar {
                ProgressView().controlSize(.small)
                Text("Importing…")
                Spacer()
                Button("Cancel") { model.cancelMediaImport() }.accessibilityIdentifier("cancelMediaImport")
            }
        } else if let message = model.queueNotice {
            BottomBar {
                Image(systemName: model.queueNoticeIsProblem ? "exclamationmark.triangle.fill" : "checkmark.circle")
                    .foregroundStyle(model.queueNoticeIsProblem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                Text(message).lineLimit(2).accessibilityIdentifier("downloadQueueNotice")
                Spacer()
            }
        } else if model.isRestoringStudy {
            BottomBar {
                ProgressView().controlSize(.small)
                Text("Checking saved videos…")
                Spacer()
            }
        } else if let message = model.studyMessage, !message.hasPrefix("Checking saved") {
            BottomBar {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(message).lineLimit(2).accessibilityIdentifier("studyMessage")
                Spacer()
                Button { model.clearStudyMessage() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
        }
    }

    // MARK: Rows

    private func secondary(_ job: StudyJob) -> (text: String, problem: Bool)? {
        switch job.state {
        case .queued:
            return model.isDownloading && model.downloadBatchIDs.contains(job.id) ? ("Waiting…", false) : nil
        case .downloading: return (job.note ?? "Downloading…", false)
        case .validating: return ("Checking…", false)
        case .complete:
            if model.redownloadingIDs.contains(job.id) { return ("Downloading again…", false) }
            guard let position = model.playbackPositions[job.id] else { return nil }
            if position.finished { return ("Watched", false) }
            return ("Resume at \(PlaybackClock.text(position.seconds))", false)
        case .failed: return failure(job).map { ($0.text, true) }
        }
    }

    private func duration(_ job: StudyJob) -> String? {
        guard case .complete(let validation) = job.state, validation.duration.isFinite, validation.duration > 0 else { return nil }
        return PlaybackClock.text(validation.duration)
    }

    /// The video's own still once saved; before that a quiet tile with its number.
    @ViewBuilder private func badge(_ job: StudyJob, number: Int) -> some View {
        Group {
            if job.isSaved {
                VideoThumbnail(videoID: job.id, store: model.thumbnailStore, cornerRadius: 10)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        if job.isFailed {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        } else {
                            Text("\(number)").font(.callout.weight(.semibold).monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
            }
        }
        .frame(width: 92)
        .accessibilityHidden(true)
    }

    private func row(_ job: StudyJob, number: Int, title: String) -> some View {
        let detail = secondary(job)
        return HoverTracking(selected: selection == job.id) { active in
        HStack(spacing: 14) {
            badge(job, number: number)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium).lineLimit(2)
                if let detail {
                    Text(detail.text).font(.callout)
                        .foregroundStyle(detail.problem ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(2)
                        .help(detail.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // A fixed column, so hovering never shifts the title.
            HStack(spacing: 8) { trailing(job, active: active) }
                .frame(width: 124, alignment: .trailing)
            Menu { actions(job) } label: { Image(systemName: "ellipsis") }
                .ruleEditMenuStyle()
                .help("More")
                .accessibilityLabel("More actions for \(fullTitle(job))")
                .accessibilityIdentifier("videoActions-\(job.id)")
        }
        .frame(minHeight: 52)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        }
        .help(fullTitle(job))
    }

    @ViewBuilder private func trailing(_ job: StudyJob, active: Bool) -> some View {
        switch job.state {
        case .downloading:
            if let phase = model.downloadActivities[job.id], phase == .preparingMedia || phase == .validating || phase == .ready {
                ProgressView().controlSize(.small)
            } else if let progress = job.progress {
                ProgressView(value: progress).frame(width: 80)
                    .accessibilityLabel("\(fullTitle(job)) download")
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
            } else {
                ProgressView().controlSize(.small)
            }
        case .validating:
            ProgressView().controlSize(.small)
        case .complete(let validation):
            if active {
                if validation.transcriptPresent {
                    Button { onPlay(job.id, true) } label: { Image(systemName: "text.quote") }
                        .buttonStyle(.borderless)
                        .help("Transcript")
                        .disabled(ShieldRuntime.isUIReview)
                        .accessibilityLabel("Transcript for \(fullTitle(job))")
                        .accessibilityIdentifier("transcript-\(job.id)")
                }
                Button { onPlay(job.id, false) } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
                    .help("Play")
                    .disabled(ShieldRuntime.isUIReview)
                    .accessibilityLabel("Play \(fullTitle(job))")
                    .accessibilityIdentifier("play-\(job.id)")
            } else if let duration = duration(job) {
                Text(duration).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        case .failed:
            if active, let failure = failure(job), failure.action == .signIn {
                Button("Sign In…") { model.selectedSection = .diagnostics }
                    .controlSize(.small)
                    .help("Add your YouTube sign-in in Settings")
            } else if active, let failure = failure(job), failure.action == .remove, model.isShowingLinkQueue {
                Button { deletingVideoID = job.id } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete this video from your library")
                    .accessibilityLabel("Delete \(fullTitle(job))")
            } else if active, let failure = failure(job), failure.action == .retry || failure.action == .downloadAgain,
               model.canDownloadStudyCourse {
                Button { model.retryDownload(id: job.id) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(downloadBlockedReason ?? "Try again")
                    .disabled(!canDownload)
                    .accessibilityLabel("Retry \(fullTitle(job))")
                    .accessibilityIdentifier("retry-\(job.id)")
            }
        case .queued:
            if active, model.studyExecutionAvailable, model.canDownloadStudyCourse,
               !(model.isDownloading && model.downloadBatchIDs.contains(job.id)) {
                Button { model.downloadVideo(id: job.id) } label: { Image(systemName: "arrow.down.circle") }
                    .buttonStyle(.borderless)
                    .help(downloadBlockedReason ?? "Download")
                    .disabled(!canDownload)
                    .accessibilityLabel("Download \(fullTitle(job))")
                    .accessibilityIdentifier("download-\(job.id)")
            }
        }
    }

    /// Selects the saved files of `ids` in Finder, or opens the library folder
    /// for All Videos or when none of them is saved yet.
    private func showInFinder(_ ids: [String]?) {
        let files = ids.map(model.savedFiles(for:)) ?? []
        if !files.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(files) }
        else if let folder = model.savedFilesFolder { NSWorkspace.shared.open(folder) }
    }

    /// Double-click or Return: play what's saved, otherwise download it.
    private func primary(_ job: StudyJob) {
        switch job.state {
        case .complete: if !ShieldRuntime.isUIReview { onPlay(job.id, false) }
        case .queued: if canDownload { model.downloadVideo(id: job.id) }
        case .failed: if canDownload { model.retryDownload(id: job.id) }
        default: break
        }
    }

    @ViewBuilder private func actions(_ job: StudyJob) -> some View {
        switch job.state {
        case .complete(let validation):
            Button("Play") { onPlay(job.id, false) }.disabled(ShieldRuntime.isUIReview)
            if validation.transcriptPresent {
                Button("Show Transcript") { onPlay(job.id, true) }.disabled(ShieldRuntime.isUIReview)
            }
            Button("Show in Finder") { showInFinder([job.id]) }
                .disabled(model.savedFilesFolder == nil)
            if model.studyExecutionAvailable && model.canDownloadStudyCourse {
                // Older downloads were 480p and have no synced transcript.
                Button("Download Again") { model.downloadAgain(id: job.id) }
                    .disabled(!canDownload || model.isDownloading)
                    .help(downloadBlockedReason
                          ?? "Get it again at \(DiagnosticsView.qualityName(YTDLPRestrictedFetcher.savedQuality)), with a transcript that follows along. The saved copy stays until the new one checks out.")
                    .accessibilityIdentifier("downloadAgain-\(job.id)")
            }
        case .queued:
            if model.studyExecutionAvailable && model.canDownloadStudyCourse {
                Button("Download") { model.downloadVideo(id: job.id) }.disabled(!canDownload)
            }
        case .failed(let raw):
            if model.canDownloadStudyCourse {
                Button("Try Again") { model.retryDownload(id: job.id) }.disabled(!canDownload)
            }
            Button("Show Details…") { errorDetails = raw }
        default: EmptyView()
        }
        if model.isShowingLinkQueue {
            Divider()
            Button("Rename…") { renameText = model.savedTitle(job.id) ?? ""; renamingVideoID = job.id }
                .disabled(model.queueReadError)
                .accessibilityIdentifier("renameVideo-\(job.id)")
            Menu("Add to Collection") {
                ForEach(model.collectionLayout.collections) { item in
                    let member = item.videoIDs.contains(job.id)
                    Button {
                        if member { model.removeVideo(job.id, fromCollection: item.id) }
                        else { model.addVideos([job.id], toCollection: item.id) }
                    } label: {
                        if member { Label(item.name, systemImage: "checkmark") } else { Text(item.name) }
                    }
                }
                if !model.collectionLayout.collections.isEmpty { Divider() }
                Button("New Collection…") { model.collectionEditor = .newWith([job.id]) }
                    .disabled(!model.canAddCollection)
            }
            if let collection, collection.videoIDs.contains(job.id) {
                Button("Remove from “\(collection.name)”") { model.removeVideo(job.id, fromCollection: collection.id) }
                    .accessibilityIdentifier("removeFromCollection-\(job.id)")
            }
        }
        if !ShieldRuntime.isUIReview, ShieldRuntime.allowsLocalMediaImport, !job.isSaved {
            Button("Import MP4 for This Video…") {
                importingVideoID = job.id; importKind = .media; importing = true
            }
            .disabled(busy)
            .accessibilityIdentifier("importVideo-\(job.id)")
        }
        if model.isShowingLinkQueue {
            Divider()
            Button("Delete Video…", role: .destructive) { deletingVideoID = job.id }
                .disabled(busy)
                .accessibilityIdentifier("deleteVideo-\(job.id)")
        }
    }
}

// MARK: - Shared bars

/// What a Library notice says and offers. It shows as a banner in the
/// window's top-right corner with the others.
struct NoticeBar: View {
    enum Kind { case info, warning }
    let kind: Kind
    let text: String
    let action: (String, () -> Void)?
    var identifier: String? = nil
    /// Set by the window: the banner's ×.
    var onClose: (() -> Void)? = nil

    /// Changes whenever what it says or offers changes, so a hidden notice
    /// comes back when something new happens.
    var id: String { "\(kind)|\(text)|\(action?.0 ?? "")" }

    func closing(_ close: @escaping () -> Void) -> NoticeBar {
        var bar = self
        bar.onClose = close
        return bar
    }

    var body: some View {
        ShieldBanner(symbol: kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill",
                     tint: kind == .warning ? .orange : .blue,
                     title: kind == .warning ? "Library needs attention" : "Library",
                     message: text, onClose: onClose) {
            if let action {
                Button(action.0, action: action.1).buttonStyle(ShieldFilledButtonStyle())
            }
        }
        .accessibilityIdentifier(identifier ?? "libraryNotice")
    }
}

/// Activity strip at the bottom of a page while something runs.
struct BottomBar<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        HStack(spacing: 12) { content }
            .font(.callout)
            .controlSize(.small)
            .buttonStyle(ShieldPillButtonStyle())
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(minHeight: 36)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Collection editor

enum CollectionEditorTarget: Identifiable, Equatable {
    case new
    /// A new collection that starts with these videos ("Add to Collection ▸ New…").
    case newWith([String])
    case existing(StudyCollection)
    var id: String { collection?.id ?? "new" }
    var collection: StudyCollection? { if case .existing(let value) = self { value } else { nil } }
    var videoIDs: [String] { if case .newWith(let ids) = self { ids } else { [] } }
}

struct StudyCollectionEditor: View {
    let model: ShieldViewModel
    let existing: StudyCollection?
    var addingVideoIDs: [String] = []
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbol: String
    @State private var color: ShieldCategoryColor
    @State private var saveProblem: String?

    /// Spoken names for the icons (the list itself is `StudyCollection.symbols`).
    private static let iconNames = [
        "play.rectangle.fill": "Video", "books.vertical.fill": "Books", "graduationcap.fill": "Course",
        "book.fill": "Book", "pencil.and.ruler.fill": "Geometry", "function": "Math",
        "brain.head.profile": "Thinking", "lightbulb.fill": "Idea", "music.note": "Music", "film.fill": "Film",
        "tv.fill": "TV", "mic.fill": "Talk", "gamecontroller.fill": "Games", "sportscourt.fill": "Sports",
        "dumbbell.fill": "Fitness", "fork.knife": "Food", "globe": "World", "airplane": "Travel",
        "heart.fill": "Favorite", "star.fill": "Star", "flame.fill": "Hot", "bolt.fill": "Quick",
        "moon.fill": "Night", "folder.fill": "Folder",
    ]

    init(model: ShieldViewModel, existing: StudyCollection?, addingVideoIDs: [String] = []) {
        self.model = model
        self.existing = existing
        self.addingVideoIDs = addingVideoIDs
        _name = State(initialValue: existing?.name ?? "")
        _symbol = State(initialValue: existing?.symbol ?? "play.rectangle.fill")
        _color = State(initialValue: existing?.color ?? .orange)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameValid: Bool { !trimmedName.isEmpty && trimmedName.count <= StudyCollection.maximumNameLength }

    var body: some View {
        VStack(spacing: 0) {
            EditorSheetHeader(symbol: symbol, tint: color.color,
                              title: existing == nil ? "New Collection" : "Edit Collection", subtitle: "")
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. Algebra"))
                        .accessibilityIdentifier("collectionName")
                } footer: {
                    if trimmedName.count > StudyCollection.maximumNameLength {
                        Text("Use \(StudyCollection.maximumNameLength) characters or fewer.").foregroundStyle(.orange)
                    } else if let saveProblem {
                        Text(saveProblem).foregroundStyle(.orange)
                    }
                }
                Section("Color") {
                    HStack(spacing: 10) {
                        ForEach(ShieldCategoryColor.allCases, id: \.self) { option in
                            Button { color = option } label: {
                                Circle().fill(option.color.gradient)
                                    .frame(width: 22, height: 22)
                                    .overlay { if option == color { Circle().strokeBorder(.white, lineWidth: 2).padding(2) } }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(option.rawValue.capitalized)
                            .accessibilityAddTraits(option == color ? .isSelected : [])
                            .accessibilityIdentifier("collectionColor-\(option.rawValue)")
                        }
                    }
                    .padding(.vertical, 2)
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 10), spacing: 8) {
                        ForEach(StudyCollection.symbols, id: \.self) { option in
                            Button { symbol = option } label: {
                                Image(systemName: option)
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(width: 34, height: 34)
                                    .foregroundStyle(option == symbol ? .white : .primary)
                                    .background(option == symbol ? AnyShapeStyle(color.color.gradient)
                                                                 : AnyShapeStyle(Color.primary.opacity(0.07)),
                                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Self.iconNames[option] ?? "Icon")
                            .accessibilityAddTraits(option == symbol ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .formStyle(.bubble)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Create" : "Save") {
                    var collection = existing ?? .new(name: trimmedName, symbol: symbol, color: color)
                    collection.name = trimmedName
                    collection.symbol = symbol
                    collection.color = color
                    // Stay open with the reason if it couldn't be saved.
                    guard model.saveCollection(collection) else {
                        saveProblem = model.collectionNotice
                            ?? "You can have up to \(StudyCollection.maximumCount) collections. Delete one to make room."
                        return
                    }
                    if !addingVideoIDs.isEmpty { model.addVideos(addingVideoIDs, toCollection: collection.id) }
                    if existing == nil { model.selectedCollectionID = collection.id }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.prominentWhenEnabled)
                .disabled(!nameValid)
                .accessibilityIdentifier("saveCollection")
            }
            .shieldSheetFooter()
        }
        .frame(width: 460)
        .frame(minHeight: 380, idealHeight: 470, maxHeight: 620)
        .shieldSheet()
    }
}
