import Foundation
import Darwin

// Owner-editable categories. Presentation only: a category is a name, icon,
// colour and a list of rule IDs. Creating, renaming, recolouring, moving rules
// or deleting a category never submits policy and never changes what is
// blocked. Blocking changes go through the service (see ShieldViewModel).

enum ShieldCategoryColor: String, Codable, CaseIterable, Sendable {
    case blue, indigo, purple, pink, red, orange, yellow, green, teal, brown, gray
}

struct ShieldCategory: Codable, Identifiable, Hashable, Sendable {
    static let maximumNameLength = 40
    /// SF Symbols offered by the category editor.
    static let symbols = [
        "bubble.left.and.bubble.right.fill", "play.rectangle.fill", "hand.raised.fill", "fork.knife",
        "lock.fill", "square.stack.fill", "gamecontroller.fill", "cart.fill", "newspaper.fill",
        "camera.fill", "music.note", "tv.fill", "photo.fill", "film.fill", "book.fill",
        "bag.fill", "creditcard.fill", "dice.fill", "sportscourt.fill", "heart.fill",
        "star.fill", "flame.fill", "bolt.fill", "moon.fill", "globe", "message.fill",
        "person.2.fill", "airplane", "car.fill", "cup.and.saucer.fill", "mappin.and.ellipse",
    ]

    /// What VoiceOver says for an icon choice, instead of the symbol's file name.
    static func spokenName(_ symbol: String) -> String {
        let names = [
            "bubble.left.and.bubble.right.fill": "Chat", "play.rectangle.fill": "Video", "hand.raised.fill": "Hand",
            "fork.knife": "Food", "lock.fill": "Lock", "square.stack.fill": "Stack", "gamecontroller.fill": "Games",
            "cart.fill": "Shopping cart", "newspaper.fill": "News", "camera.fill": "Camera", "music.note": "Music",
            "tv.fill": "TV", "photo.fill": "Photos", "film.fill": "Film", "book.fill": "Book", "bag.fill": "Bag",
            "creditcard.fill": "Card", "dice.fill": "Dice", "sportscourt.fill": "Sports", "heart.fill": "Heart",
            "star.fill": "Star", "flame.fill": "Flame", "bolt.fill": "Bolt", "moon.fill": "Moon", "globe": "Globe",
            "message.fill": "Messages", "person.2.fill": "People", "airplane": "Travel", "car.fill": "Car",
            "cup.and.saucer.fill": "Café", "mappin.and.ellipse": "Place",
        ]
        return names[symbol] ?? symbol.split(separator: ".").first.map(String.init)?.capitalized ?? symbol
    }

    let id: String
    var name: String
    var symbol: String
    var color: ShieldCategoryColor
    /// Rules and schedules placed here explicitly, by policy ID. A rule not
    /// listed in any category shows in its default category.
    var members: [String]

    var isBuiltIn: Bool { ShieldGroupKind(rawValue: id) != nil }

    static func builtIn(_ kind: ShieldGroupKind) -> Self {
        let color: ShieldCategoryColor = switch kind {
        case .social: .blue
        case .video: .pink
        case .adult: .indigo
        case .food: .teal
        case .location: .purple
        case .custom, .other: .gray
        }
        return Self(id: kind.rawValue, name: kind.title, symbol: kind.iconSymbol, color: color, members: [])
    }

    static func new(name: String, symbol: String, color: ShieldCategoryColor) -> Self {
        Self(id: "user-\(UUID().uuidString)", name: name, symbol: symbol, color: color, members: [])
    }
}

struct ShieldCategoryLayout: Codable, Equatable, Sendable {
    static let currentVersion = 1
    var version = Self.currentVersion
    /// Display order. A built-in category that is missing was deleted by the
    /// owner, except Other blocks and Location blocks, which always exist.
    var categories: [ShieldCategory]
    /// Names the user gave lists and schedules, by rule ID. Display
    /// only: the service keeps each rule's own title.
    var names: [String: String] = [:]
    /// Lists shown together as one card, each at least two rule IDs.
    /// Display only: every rule keeps its own owner, terms and websites.
    var combined: [[String]] = []

    static let `default` = Self(categories: ShieldGroupKind.allCases.map(ShieldCategory.builtIn))
    static let maximumNameLength = 64

    /// Whitespace runs (tabs, doubled spaces from file names) shown as one space.
    static func cleanName(_ name: String) -> String {
        String(name.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(maximumNameLength))
    }

    /// The name a rule is shown with: the user's, else its own cleaned title.
    func displayName(for ruleID: String, title: String) -> String {
        names[ruleID] ?? Self.cleanName(ShieldGrouping.title(title, policyID: ruleID))
    }

    /// The combined card a rule belongs to, if any.
    func combination(containing ruleID: String) -> [String]? {
        combined.first { $0.contains(ruleID) }
    }

    mutating func rename(_ ruleID: String, to name: String) {
        let clean = Self.cleanName(name)
        if clean.isEmpty { names[ruleID] = nil } else { names[ruleID] = clean }
    }

    /// Shows these rules as one card named `name`, in one category. A rule
    /// already in another card leaves it.
    mutating func combine(_ ruleIDs: [String], name: String, in categoryID: String) {
        let ids = ruleIDs.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard ids.count > 1 else { return }
        combined = combined.map { $0.filter { !ids.contains($0) } }.filter { $0.count > 1 }
        combined.append(ids)
        place(ids, in: categoryID)
        rename(ids[0], to: name)
    }

    mutating func separate(_ ruleIDs: [String]) {
        combined.removeAll { !Set($0).isDisjoint(with: ruleIDs) }
    }
    static let otherID = ShieldGroupKind.other.rawValue
    /// Holds every block set to a place, and nothing else.
    static let locationID = ShieldGroupKind.location.rawValue

    /// Where a rule is shown: an explicit placement first, then its default
    /// category if the user kept it, otherwise Other blocks.
    func categoryID(for ruleID: String, defaultKind: ShieldGroupKind) -> String {
        if let placed = categories.first(where: { $0.members.contains(ruleID) }) { return placed.id }
        return categories.contains(where: { $0.id == defaultKind.rawValue }) ? defaultKind.rawValue : Self.otherID
    }

    func category(_ id: String) -> ShieldCategory? { categories.first { $0.id == id } }

    /// "Other blocks" always exists, IDs are unique and each rule has at most one placement.
    func normalized() -> Self {
        var seen = Set<String>()
        var placed = Set<String>()
        var result = categories.compactMap { category -> ShieldCategory? in
            guard seen.insert(category.id).inserted else { return nil }
            var category = category
            category.name = String(category.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(ShieldCategory.maximumNameLength))
            if category.name.isEmpty { category.name = ShieldGroupKind(rawValue: category.id)?.title ?? "Category" }
            // The old default name; one the user chose is kept.
            if category.id == Self.otherID && category.name == "Other blocks" { category.name = ShieldGroupKind.other.title }
            if !ShieldCategory.symbols.contains(category.symbol) { category.symbol = "square.stack.fill" }
            category.members = category.id == Self.locationID ? [] : category.members.filter { placed.insert($0).inserted }
            return category
        }
        if !result.contains(where: { $0.id == Self.otherID }) { result.append(.builtIn(.other)) }
        // Layouts saved before Location blocks existed get it before Other.
        if !result.contains(where: { $0.id == Self.locationID }) {
            result.insert(.builtIn(.location), at: result.firstIndex { $0.id == Self.otherID }!)
        }
        var cleanNames: [String: String] = [:]
        for (id, name) in names where !id.isEmpty {
            let clean = Self.cleanName(name)
            if !clean.isEmpty { cleanNames[id] = clean }
        }
        var grouped = Set<String>()
        let cleanCombined = combined
            .map { $0.filter { !$0.isEmpty && grouped.insert($0).inserted } }
            .filter { $0.count > 1 }
        return Self(version: Self.currentVersion, categories: result, names: cleanNames, combined: cleanCombined)
    }

    mutating func place(_ ruleIDs: [String], in categoryID: String) {
        guard categoryID != Self.locationID, categories.contains(where: { $0.id == categoryID }) else { return }
        for index in categories.indices {
            categories[index].members.removeAll { ruleIDs.contains($0) }
            if categories[index].id == categoryID { categories[index].members += ruleIDs }
        }
    }

    mutating func upsert(_ category: ShieldCategory) {
        if let index = categories.firstIndex(where: { $0.id == category.id }) {
            categories[index] = category
        } else if let other = categories.firstIndex(where: { $0.id == Self.otherID }) {
            categories.insert(category, at: other)
        } else {
            categories.append(category)
        }
        self = normalized()
    }

    /// Its rules return to their default category, or to Other blocks.
    mutating func delete(_ categoryID: String) {
        guard categoryID != Self.otherID, categoryID != Self.locationID else { return }
        categories.removeAll { $0.id == categoryID }
    }

    mutating func move(_ categoryID: String, by offset: Int) {
        guard let index = categories.firstIndex(where: { $0.id == categoryID }) else { return }
        let target = min(max(0, index + offset), categories.count - 1)
        guard target != index else { return }
        categories.insert(categories.remove(at: index), at: target)
    }
}

/// Local, owner-only file beside the download library. Not authority.
struct ShieldCategoryStore {
    let fileURL: URL

    func load() -> ShieldCategoryLayout {
        var metadata = stat()
        guard lstat(fileURL.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size <= 1_048_576,
              let data = try? Data(contentsOf: fileURL),
              let layout = try? JSONDecoder().decode(ShieldCategoryLayout.self, from: data),
              layout.version == ShieldCategoryLayout.currentVersion else {
            return .default
        }
        return layout.normalized()
    }

    func save(_ layout: ShieldCategoryLayout) throws {
        try ShieldRuntime.requireIsolatedWrite(to: fileURL)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFixtureStore(allowedRoot: directory).write(encoder.encode(layout.normalized()), to: fileURL)
    }
}

extension ShieldCategoryLayout {
    private enum CodingKeys: String, CodingKey { case version, categories, names, combined }

    /// Files saved before names and combined cards existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(version: try c.decode(Int.self, forKey: .version),
                  categories: try c.decode([ShieldCategory].self, forKey: .categories),
                  names: try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:],
                  combined: try c.decodeIfPresent([[String]].self, forKey: .combined) ?? [])
    }
}
