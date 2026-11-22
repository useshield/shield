import SwiftUI
import UniformTypeIdentifiers

// Import a whole list of websites at once: paste text or choose a
// text file, review what Shield found, and block it: until turned off (like
// New Block), permanently (like Lock In Forever), or outside allowed hours
// (like New Daily Schedule). It only ever ADDS blocking, through those same
// service commands, so the usual rules hold: it applies at once, and removing
// any of these websites later waits 24 hours (a permanent one's only within
// its 72-hour correction window).

/// Finds the websites in pasted text or a text file: bare addresses (one per
/// line, or separated by commas or spaces), links, and "Name<tab>link" lines.
/// Sentences, headings and links to single pages are left out.
enum WebsiteListImport {
    /// At most this many lists per import (each up to one rule's limit). The
    /// service also refuses more websites than it can block at once.
    static let maximumLists = 50

    struct Found: Equatable {
        /// Websites as the user would type them (no www. twins), sorted.
        var sites: [String] = []
        /// Links to a page on a site that isn't listed itself. Shield blocks
        /// whole websites, so importing one would block every page there.
        var pageLinks: [String] = []
        /// Services the Mac and many apps depend on, never imported in bulk.
        var leftOutServices: [String] = []
        /// Lines with nothing that looked like a website address.
        var ignoredLines = 0
    }

    static let maximumTextBytes = 4_000_000

    /// Parents shared by unrelated services (the same set the service keeps
    /// out of browser policy). A list naming one is almost always a link to a
    /// page there, and blocking the whole thing would break the Mac or study
    /// tools. They can still be added one at a time with New Block.
    static let leftOutParents: Set<String> = [
        "google.com", "googleapis.com", "gstatic.com", "googleusercontent.com", "apple.com", "icloud.com",
        "microsoft.com", "live.com", "office.com", "amazonaws.com", "cloudfront.net", "akamaihd.net",
        "akamaized.net", "fastly.net", "github.com", "githubusercontent.com", "cloudflare.com", "azureedge.net",
    ]

    private enum Token: Equatable {
        case site(String)
        case page(String)
    }

    static func parse(_ text: String) -> Found {
        var sites = Set<String>()
        var pages = Set<String>()
        var services = Set<String>()
        var ignored = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let pieces = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," || $0 == ";" || $0 == "|" })
            var lineSites: [String] = []
            var linkSites: [String] = []
            var hasLink = false
            var words = 0
            for piece in pieces {
                let isLink = piece.contains("://")
                hasLink = hasLink || isLink
                switch token(String(piece)) {
                case .site(let host):
                    if isLink { linkSites.append(host) } else { lineSites.append(host) }
                case .page(let host):
                    pages.insert(host)
                case nil:
                    words += 1
                }
            }
            // On a line with a link ("TV.Jest<tab>https://tv.jest.one/") only the
            // link counts: the rest is its name. A sentence that happens to
            // mention "shield.app" isn't a list entry either.
            let found = hasLink ? linkSites : (words >= 4 ? [] : lineSites)
            if found.isEmpty && !hasLink && lineSites.isEmpty { ignored += 1 }
            for host in found {
                if leftOutParents.contains(host) { services.insert(host) } else { sites.insert(host) }
            }
        }
        // A page link whose site is imported anyway adds nothing to report.
        let leftPages = pages.filter { !sites.contains($0) && !leftOutParents.contains($0) }
        return Found(sites: sites.sorted(), pageLinks: leftPages.sorted(),
                     leftOutServices: services.union(pages.filter(leftOutParents.contains)).sorted(),
                     ignoredLines: ignored)
    }

    /// One piece of a line: a website, a link to a page, or neither.
    private static func token(_ raw: String) -> Token? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>()[]{}`*,.;:!?"))
        guard !trimmed.isEmpty else { return nil }
        var hostPart: Substring
        var isPage = false
        if let scheme = trimmed.range(of: "://") {
            let rest = trimmed[scheme.upperBound...]
            let end = rest.firstIndex(where: { "/?#".contains($0) }) ?? rest.endIndex
            hostPart = rest[..<end]
            let tail = rest[end...]
            isPage = !(tail.isEmpty || tail == "/")
            if let at = hostPart.lastIndex(of: "@") { hostPart = hostPart[hostPart.index(after: at)...] }
        } else {
            let end = trimmed.firstIndex(where: { "/?#".contains($0) }) ?? trimmed.endIndex
            hostPart = trimmed[..<end]
            let tail = trimmed[end...]
            isPage = !(tail.isEmpty || tail == "/")
        }
        if let colon = hostPart.firstIndex(of: ":") {
            guard hostPart[hostPart.index(after: colon)...].allSatisfy(\.isNumber) else { return nil }
            hostPart = hostPart[..<colon]
        }
        guard let host = site(String(hostPart)) else { return nil }
        return isPage ? .page(host) : .site(host)
    }

    /// A website address as Shield stores it, or nil: lowercased, no trailing
    /// dot, a real-looking ending (letters, two or more), www. dropped from a
    /// two-part site (its twin is added back automatically).
    static func site(_ raw: String) -> String? {
        var host = raw.lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last,
              (last.count >= 2 && last.allSatisfy { $0.isASCII && $0.isLetter }) || last.hasPrefix("xn--"),
              PolicyValidation.validDomain(host) else { return nil }
        if labels.count == 3 && labels[0] == "www" { host.removeFirst(4) }
        return host
    }

    /// The sites split into lists that each fit one rule, www. twins included.
    static func lists(_ sites: [String], maximum: Int = PolicyValidation.maximumDomains) -> [Set<String>] {
        var lists: [Set<String>] = []
        var current = Set<String>()
        for site in sites.sorted() {
            let entries = WebsiteListParser.withWWW([site])
            if current.count + entries.count > maximum, !current.isEmpty {
                lists.append(current)
                current = []
            }
            current.formUnion(entries)
        }
        if !current.isEmpty { lists.append(current) }
        return lists
    }

    /// "Streaming sites", then "Streaming sites (2)" and so on, within 64 characters.
    static func title(_ name: String, part: Int, of count: Int) -> String {
        let trimmed = ShieldCategoryLayout.cleanName(name)
        guard count > 1, part > 1 else { return trimmed }
        let suffix = " (\(part))"
        return String(trimmed.prefix(64 - suffix.count)) + suffix
    }

    /// "a.com, b.com and 3 more"
    static func sample(_ items: [String], limit: Int = 4) -> String {
        guard items.count > limit else { return items.joined(separator: ", ") }
        return items.prefix(limit).joined(separator: ", ") + " and \(items.count - limit) more"
    }
}

// MARK: - Sheet

struct ImportListEditor: View {
    /// How the imported websites are blocked (Nov 13: hours were the only choice).
    enum Kind: Hashable, CaseIterable {
        case untilTurnedOff, permanent, allowedHours

        var label: String {
            switch self {
            case .untilTurnedOff: "Until turned off"
            case .permanent: "Permanent"
            case .allowedHours: "Allowed hours"
            }
        }
    }

    let model: ShieldViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var categoryID: String
    @State private var name = ""
    @State private var kind = Kind.untilTurnedOff
    @State private var understandsForever = false
    @State private var text = ""
    @State private var start = 14 * 60
    @State private var end = 20 * 60
    @State private var choosingFile = false
    @State private var fileProblem: String?
    @State private var showingSites = false
    @State private var awaiting: UUID?
    @State private var problem: String?
    /// The text parsed once per change (a pasted file can be megabytes; the
    /// sheet redraws on every keystroke in Name and every status update).
    @State private var found = WebsiteListImport.Found()
    @State private var lists: [Set<String>] = []
    /// The text `found` was read from; Import waits until it matches.
    @State private var parsedText: String?

    init(model: ShieldViewModel, categoryID: String?) {
        self.model = model
        _categoryID = State(initialValue: categoryID.flatMap { $0 == ShieldCategoryLayout.locationID ? nil : $0 }
                            ?? ShieldCategoryLayout.otherID)
    }

    private var window: AllowedAccessWindow? { AllowedAccessWindow(startMinutes: start, endMinutes: end) }
    private var nameValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 64
    }
    private func canImport(_ found: WebsiteListImport.Found) -> Bool {
        !found.sites.isEmpty && lists.count <= WebsiteListImport.maximumLists && nameValid
            && awaiting == nil && model.canSubmitPolicy && parsedText == text
            && (kind != .allowedHours || window != nil) && (kind != .permanent || understandsForever)
    }

    private var footerText: String {
        switch kind {
        case .untilTurnedOff: "Blocking starts right away. Turning it off or removing websites takes 24 hours."
        case .permanent: "Blocking starts right away and never ends. A mistake can be corrected for 72 hours."
        case .allowedHours: "Blocking starts right away. Removing websites later takes 24 hours."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            EditorSheetHeader(symbol: "list.bullet.rectangle", tint: .shieldAccent, title: "Import Website List", subtitle: "")
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.callout.monospaced())
                        .frame(height: 120)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Websites to import")
                        .accessibilityIdentifier("importListText")
                    HStack {
                        Button("Choose File…") { choosingFile = true }
                            .accessibilityIdentifier("importListChooseFile")
                        if !text.isEmpty {
                            Button("Clear") { text = ""; fileProblem = nil }
                        }
                        Spacer()
                    }
                } header: {
                    Text("Websites")
                } footer: {
                    if let fileProblem {
                        Text(fileProblem).foregroundStyle(.orange)
                    }
                }
                if !text.isEmpty { results(found, lists: lists) }
                Section {
                    TextField("Name", text: $name, prompt: Text("Streaming sites"))
                        .accessibilityIdentifier("importListName")
                } header: {
                    Text("Name")
                }
                Section {
                    Picker("Block", selection: $kind) {
                        ForEach(Kind.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .accessibilityIdentifier("importListKind")
                    if kind == .permanent {
                        Toggle("I understand this never ends", isOn: $understandsForever)
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("importListConfirmPermanent")
                    }
                } header: {
                    Text("Blocking")
                }
                if kind == .allowedHours {
                    Section {
                        HoursPicker(model: model, title: "Allow from", minutes: $start)
                        HoursPicker(model: model, title: "Allow until", minutes: $end)
                        if let window {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Allowed " + ScheduleText.short(window)).font(.headline)
                                AllowedHoursBar(window: window, height: 10)
                                HourAxisLabels()
                            }
                            .padding(.vertical, 4)
                        } else {
                            Text("Start and end must differ.").foregroundStyle(.orange)
                        }
                    } header: {
                        Text("Allowed hours")
                    } footer: {
                        if model.scheduleCalendar.timeZone.identifier != TimeZone.current.identifier {
                            Text("Times are \(model.scheduleTimeZoneDescription).")
                        }
                    }
                }
                Section { CategoryPicker(model: model, selection: $categoryID) }
                EditorSubmissionStatus(model: model, awaiting: awaiting, problem: problem)
            }
            .formStyle(.bubble)
            .scrollContentBackground(.hidden)
            .disabled(awaiting != nil && model.submissionState != .unconfirmed(awaiting!))

            HStack {
                Text(footerText)
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(awaiting == nil ? "Cancel" : "Close") { dismiss() }.keyboardShortcut(.cancelAction)
                // Not the default button: Return while typing must never commit.
                Button(found.sites.isEmpty ? "Import" : "Import \(found.sites.count) Website\(found.sites.count == 1 ? "" : "s")") {
                    guard canImport(found) else { return }
                    problem = nil
                    switch kind {
                    case .allowedHours:
                        guard let window else { return }
                        awaiting = model.importSchedules(name: name, sites: found.sites, allowed: window,
                                                         categoryID: categoryID)
                    case .untilTurnedOff, .permanent:
                        awaiting = model.importBlocks(name: name, sites: found.sites, permanent: kind == .permanent,
                                                      categoryID: categoryID)
                    }
                    if awaiting == nil { problem = model.backendActionMessage }
                }
                .buttonStyle(.prominentWhenEnabled)
                .disabled(!canImport(found))
                .accessibilityIdentifier("confirmImportList")
            }
            .shieldSheetFooter()
        }
        .onChange(of: kind) { understandsForever = false }
        // Typing re-reads the list after a short pause, not on every key.
        .task(id: text) {
            if parsedText != nil { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            found = WebsiteListImport.parse(text)
            lists = WebsiteListImport.lists(found.sites)
            parsedText = text
        }
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 680, minHeight: 480, idealHeight: 720, maxHeight: 860)
        .shieldSheet()
        .environment(\.timeZone, model.scheduleCalendar.timeZone)
        .dismissOnConfirmation(model, awaiting: $awaiting, problem: $problem)
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.plainText, .text, .commaSeparatedText]) { result in
            if case .success(let url) = result { load(url) }
        }
    }

    @ViewBuilder private func results(_ found: WebsiteListImport.Found, lists: [Set<String>]) -> some View {
        Section {
            if found.sites.isEmpty {
                Text("No website addresses found.").foregroundStyle(.orange)
            } else {
                DisclosureRow(title: "\(found.sites.count) website\(found.sites.count == 1 ? "" : "s") found",
                              identifier: "importListFound", isExpanded: $showingSites) {
                    ScrollView {
                        Text(found.sites.joined(separator: "\n"))
                            .font(.callout.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                    .padding(.top, 4)
                }
                if lists.count > WebsiteListImport.maximumLists {
                    Text("That's more websites than Shield can import at once. Split the list and import it in parts.")
                        .font(.callout).foregroundStyle(.orange)
                } else if lists.count > 1 {
                    Text("That's more than one list holds, so Shield makes \(lists.count) lists, all blocked the same way.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if !found.pageLinks.isEmpty {
                Label("Left out \(found.pageLinks.count) link\(found.pageLinks.count == 1 ? "" : "s") to single pages "
                      + "(\(WebsiteListImport.sample(found.pageLinks))). Shield blocks whole websites, so add a site "
                      + "on its own line if you mean all of it.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !found.leftOutServices.isEmpty {
                Label("Left out \(WebsiteListImport.sample(found.leftOutServices)): the Mac and many apps rely on "
                      + (found.leftOutServices.count == 1 ? "it" : "them") + ". Use New Block to add one on purpose.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Found")
        }
    }

    /// "adult-sites_all.txt" → "adult sites all"; "Streaming sites - removed.txt"
    /// → "Streaming sites – removed" (a spaced dash stays a dash, never a gap).
    static func name(fromFile url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " - ", with: " \u{2013} ")
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return ShieldCategoryLayout.cleanName(base)
    }

    private func load(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0,
              size <= WebsiteListImport.maximumTextBytes,
              let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            fileProblem = "That file couldn't be read as text."
            return
        }
        fileProblem = nil
        text = contents
        if name.isEmpty {
            name = Self.name(fromFile: url)
        }
    }
}
