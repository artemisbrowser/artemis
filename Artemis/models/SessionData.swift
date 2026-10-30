import Foundation

/// everything that makes up "your browser as you left it": the profiles (with
/// their favourites), the spaces (with their tabs, splits and appearance), and
/// which space was showing.
nonisolated struct BrowsingSession: Codable {
    /// bumped only for changes older builds can't read; decoding stays tolerant
    var version = 1
    var profiles: [ProfileData] = []
    var spaces: [SpaceData] = []
    /// the default profile's favourites, kept at the top level for older builds
    var essentialURLs: [String] = []
    var selectedSpaceID: UUID?

    init(
        profiles: [ProfileData] = [], spaces: [SpaceData] = [], essentialURLs: [String] = [],
        selectedSpaceID: UUID? = nil
    ) {
        self.profiles = profiles
        self.spaces = spaces
        self.essentialURLs = essentialURLs
        self.selectedSpaceID = selectedSpaceID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        profiles = try c.decodeIfPresent([ProfileData].self, forKey: .profiles) ?? []
        spaces = try c.decodeIfPresent([SpaceData].self, forKey: .spaces) ?? []
        essentialURLs = try c.decodeIfPresent([String].self, forKey: .essentialURLs) ?? []
        selectedSpaceID = try c.decodeIfPresent(UUID.self, forKey: .selectedSpaceID)
        migrateToProfiles()
    }

    /// a file from before profiles: the favourites become the default profile's,
    /// and each isolated or burner space becomes a profile of its own, so no
    /// space starts sharing logins it never shared
    mutating func migrateToProfiles() {
        if !profiles.contains(where: { $0.id == Profile.defaultID }) {
            profiles.insert(.makeDefault(essentialURLs: essentialURLs), at: 0)
        }
        for i in spaces.indices where spaces[i].profileID == nil {
            guard let jar = spaces[i].legacyIsolatedJar else {
                spaces[i].profileID = Profile.defaultID
                continue
            }
            if !profiles.contains(where: { $0.id == jar }) {
                profiles.append(
                    ProfileData(id: jar, name: spaces[i].name, icon: spaces[i].icon, essentialURLs: []))
            }
            spaces[i].profileID = jar
        }
        let known = Set(profiles.map(\.id))
        for i in spaces.indices where !known.contains(spaces[i].profileID ?? Profile.defaultID) {
            spaces[i].profileID = Profile.defaultID
        }
    }
}

/// one persisted tab.
///
/// `id` is the point: it is what lets anything — a session blob, a Shortcuts
/// entity, a sync record — refer to one specific tab across a relaunch.
nonisolated struct TabRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var url: String
    /// pinned tabs only: the page the tab is anchored to, which it can navigate
    /// away from without losing its pin
    var pinnedURL: String?
    var isPinned: Bool
    /// drives the auto-archive clock, which is why it has to survive a relaunch
    var lastAccessed: Date
    var createdAt: Date
    var modifiedAt: Date
    var keepsLoaded = false

    init(
        id: UUID = UUID(), url: String, pinnedURL: String? = nil, isPinned: Bool = false,
        lastAccessed: Date = Date(), createdAt: Date = Date(), modifiedAt: Date = Date(),
        keepsLoaded: Bool = false
    ) {
        self.id = id
        self.url = url
        self.pinnedURL = pinnedURL
        self.isPinned = isPinned
        self.lastAccessed = lastAccessed
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.keepsLoaded = keepsLoaded
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        url = try c.decode(String.self, forKey: .url)
        pinnedURL = try c.decodeIfPresent(String.self, forKey: .pinnedURL)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        let now = Date()
        lastAccessed = try c.decodeIfPresent(Date.self, forKey: .lastAccessed) ?? now
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? now
        keepsLoaded = try c.decodeIfPresent(Bool.self, forKey: .keepsLoaded) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, pinnedURL, isPinned, lastAccessed, createdAt, modifiedAt, keepsLoaded
    }
}

/// one persisted sidebar entry. every field decodes on its own terms and an
/// unknown `kind` is skipped, so a malformed tree costs the folders rather than
/// the session it sits in
nonisolated struct EntryData: Codable {
    var kind: String
    var id: UUID
    var name: String?
    var expanded: Bool?
    var children: [EntryData]?

    init(kind: String, id: UUID, name: String? = nil, expanded: Bool? = nil, children: [EntryData]? = nil) {
        self.kind = kind
        self.id = id
        self.name = name
        self.expanded = expanded
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name)
        expanded = try c.decodeIfPresent(Bool.self, forKey: .expanded)
        children = try c.decodeIfPresent([EntryData].self, forKey: .children)
    }

    private enum CodingKeys: String, CodingKey { case kind, id, name, expanded, children }
}

/// codable snapshot of a space (urls only — web views are rebuilt lazily)
nonisolated struct SpaceData: Codable {
    var id: UUID
    var name: String
    var icon: String
    var appearance: SpaceAppearance
    /// absent in files written before profiles; `BrowsingSession` migrates those
    var profileID: UUID?
    /// a pre-profile file's own cookie jar, read only so migration can turn it
    /// into a profile: an isolated space keeps its logins, a burner gets an empty jar
    var legacyIsolatedJar: UUID?
    /// split views, panes stored as indices into [pinned…, today…]. absent in
    /// legacy data → no splits
    var splitGroups: [SplitGroupData]

    /// v2: the tabs, in [pinned…, today…] order, each with a stable id. The v1
    /// parallel arrays above are still written from this so an older build opens
    /// the file, and still read when this is absent
    var tabs: [TabRecord]
    /// v2 replacement for `selectedIndex`, which meant nothing once a tab could
    /// be dropped from the middle of the list
    var selectedTabID: UUID?
    /// v3: the sidebar tree. absent → a flat list, rebuilt from `tabs`. An empty
    /// folder persists here; a split below two panes deliberately does not
    var pinnedEntries: [EntryData]
    var todayEntries: [EntryData]
    var requiresUnlock: Bool

    init(
        id: UUID, name: String, icon: String, appearance: SpaceAppearance,
        profileID: UUID? = nil,
        splitGroups: [SplitGroupData] = [], tabs: [TabRecord] = [], selectedTabID: UUID? = nil,
        pinnedEntries: [EntryData] = [], todayEntries: [EntryData] = [],
        requiresUnlock: Bool = false
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.appearance = appearance
        self.profileID = profileID
        self.splitGroups = splitGroups
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.pinnedEntries = pinnedEntries
        self.todayEntries = todayEntries
        self.requiresUnlock = requiresUnlock
    }

    // tolerant decoding: new fields and the legacy `themeIndex` both handled,
    // so older saved data never fails to load
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "circle.fill"
        if let appearance = try c.decodeIfPresent(SpaceAppearance.self, forKey: .appearance) {
            self.appearance = appearance
        } else {
            let legacy = try c.decodeIfPresent(Int.self, forKey: .themeIndex) ?? 0
            appearance = SpacePreset.appearance(forLegacyIndex: legacy)
        }
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
        switch try c.decodeIfPresent(String.self, forKey: .containerMode) {
        case "isolated": legacyIsolatedJar = try c.decodeIfPresent(UUID.self, forKey: .containerID)
        case "ephemeral": legacyIsolatedJar = UUID()
        default: break
        }
        splitGroups = try c.decodeIfPresent([SplitGroupData].self, forKey: .splitGroups) ?? []
        pinnedEntries = (try? c.decode([EntryData].self, forKey: .pinnedEntries)) ?? []
        todayEntries = (try? c.decode([EntryData].self, forKey: .todayEntries)) ?? []
        requiresUnlock = try c.decodeIfPresent(Bool.self, forKey: .requiresUnlock) ?? false

        if let records = try c.decodeIfPresent([TabRecord].self, forKey: .tabs) {
            tabs = records
            selectedTabID = try c.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        } else {
            // a v1 file: build records from the parallel arrays, minting the ids
            // this format never had. Order is [pinned…, today…], the same order
            // `selectedIndex` and the split pane indices are relative to
            let pinnedURLs = try c.decodeIfPresent([String].self, forKey: .pinnedURLs) ?? []
            let pinnedAnchorURLs =
                try c.decodeIfPresent([String].self, forKey: .pinnedAnchorURLs) ?? []
            let todayURLs = try c.decodeIfPresent([String].self, forKey: .todayURLs) ?? []
            let todayLastAccessed =
                try c.decodeIfPresent([Date].self, forKey: .todayLastAccessed) ?? []
            let selectedIndex = try c.decodeIfPresent(Int.self, forKey: .selectedIndex) ?? 0
            tabs =
                pinnedURLs.enumerated().map { i, url in
                    TabRecord(
                        url: url,
                        pinnedURL: pinnedAnchorURLs.indices.contains(i)
                            ? pinnedAnchorURLs[i] : url,
                        isPinned: true)
                }
                + todayURLs.enumerated().map { i, url in
                    TabRecord(
                        url: url,
                        lastAccessed: todayLastAccessed.indices.contains(i)
                            ? todayLastAccessed[i] : Date())
                }
            selectedTabID = tabs.indices.contains(selectedIndex) ? tabs[selectedIndex].id : nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(icon, forKey: .icon)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(tabs, forKey: .tabs)
        try c.encodeIfPresent(selectedTabID, forKey: .selectedTabID)
        // v1 mirror, derived rather than stored, so the two can't drift
        let pinned = tabs.filter(\.isPinned)
        let today = tabs.filter { !$0.isPinned }
        try c.encode(pinned.map(\.url), forKey: .pinnedURLs)
        try c.encode(pinned.map { $0.pinnedURL ?? $0.url }, forKey: .pinnedAnchorURLs)
        try c.encode(today.map(\.url), forKey: .todayURLs)
        try c.encode(today.map(\.lastAccessed), forKey: .todayLastAccessed)
        try c.encode(
            selectedTabID.flatMap { id in tabs.firstIndex { $0.id == id } } ?? 0,
            forKey: .selectedIndex)
        try c.encodeIfPresent(profileID, forKey: .profileID)
        // an older build reads a profile as the isolated container of the same id
        if let profileID, profileID != Profile.defaultID {
            try c.encode("isolated", forKey: .containerMode)
            try c.encode(profileID, forKey: .containerID)
        }
        try c.encode(splitGroups, forKey: .splitGroups)
        try c.encode(pinnedEntries, forKey: .pinnedEntries)
        try c.encode(todayEntries, forKey: .todayEntries)
        if requiresUnlock { try c.encode(true, forKey: .requiresUnlock) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, icon, appearance, themeIndex
        case pinnedURLs, pinnedAnchorURLs, todayURLs, todayLastAccessed, selectedIndex
        case profileID, containerMode, containerID, splitGroups
        case tabs, selectedTabID
        case pinnedEntries, todayEntries, requiresUnlock
    }
}

/// a profile as the session file stores it
nonisolated struct ProfileData: Codable {
    var id: UUID
    var name: String
    var icon: String
    var essentialURLs: [String]
    /// absent until set, and for the default profile, whose choices live in the app-wide keys
    var searchEngine: String?
    var searchSuggestions: Bool?
    var archiveAfterHours: Double?

    static func makeDefault(essentialURLs: [String] = []) -> ProfileData {
        ProfileData(
            id: Profile.defaultID, name: "Default", icon: "person.crop.circle.fill",
            essentialURLs: essentialURLs)
    }
}

/// how a split tiles its panes along one axis. a layout is a *tree* of these:
/// each split node stacks its children along its axis, and a child can itself be
/// another split — so columns-of-rows (and rows-of-columns) give arbitrary 2-D
/// tilings (2×2, "3 across the top + 1 spanning the bottom", …) up to four panes.
nonisolated enum SplitOrientation: String, Codable, CaseIterable, Identifiable {
    case columns  // children side by side, vertical dividers
    case rows     // children stacked, horizontal dividers

    var id: String { rawValue }

    var label: String {
        switch self {
        case .columns: "Side by side"
        case .rows: "Stacked"
        }
    }

    /// SF Symbol for the orientation toggle in the split's sidebar block
    var symbol: String {
        switch self {
        case .columns: "rectangle.split.2x1"
        case .rows: "rectangle.split.1x2"
        }
    }

    var flipped: SplitOrientation { self == .columns ? .rows : .columns }

    // MARK: - Settings

    static let defaultKey = "defaultSplitOrientation"
    static var defaultForNewSplits: SplitOrientation {
        let raw = UserDefaults.standard.string(forKey: defaultKey)
        return raw.flatMap(SplitOrientation.init(rawValue:)) ?? .columns
    }
}

/// codable snapshot of one split-tree node. a leaf names its pane by tab id;
/// `tabIndex` is that pane's slot in the space's ordered tab list (pinned…,
/// today…), written for builds that predate the id and read when it's absent.
nonisolated indirect enum SplitNodeData: Codable {
    case leaf(tabID: UUID?, tabIndex: Int)
    case split(axis: SplitOrientation, children: [Child])

    struct Child: Codable {
        var node: SplitNodeData
        var ratio: Double
    }

    // hand-written to keep the synthesized shape while every field decodes
    // tolerantly: a leaf written by an older build carries no `tabID`
    private enum CaseKey: String, CodingKey { case leaf, split }
    private enum LeafKey: String, CodingKey { case tabID, tabIndex }
    private enum SplitKey: String, CodingKey { case axis, children }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CaseKey.self)
        if let leaf = try? c.nestedContainer(keyedBy: LeafKey.self, forKey: .leaf) {
            self = .leaf(
                tabID: try leaf.decodeIfPresent(UUID.self, forKey: .tabID),
                tabIndex: try leaf.decodeIfPresent(Int.self, forKey: .tabIndex) ?? -1)
            return
        }
        let split = try c.nestedContainer(keyedBy: SplitKey.self, forKey: .split)
        self = .split(
            axis: try split.decodeIfPresent(SplitOrientation.self, forKey: .axis) ?? .columns,
            children: try split.decodeIfPresent([Child].self, forKey: .children) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CaseKey.self)
        switch self {
        case .leaf(let id, let index):
            var leaf = c.nestedContainer(keyedBy: LeafKey.self, forKey: .leaf)
            try leaf.encodeIfPresent(id, forKey: .tabID)
            try leaf.encode(index, forKey: .tabIndex)
        case .split(let axis, let children):
            var split = c.nestedContainer(keyedBy: SplitKey.self, forKey: .split)
            try split.encode(axis, forKey: .axis)
            try split.encode(children, forKey: .children)
        }
    }
}

/// codable snapshot of a split group. carries the tiling `tree`; older blobs
/// (pre-tiling) instead hold flat `tabIDs`/`tabIndices` + `orientation` +
/// `ratios`, which `effectiveRoot` synthesizes into a flat split.
nonisolated struct SplitGroupData: Codable {
    var id: UUID
    var tree: SplitNodeData?
    // legacy flat layout (still written for downgrade safety, read for migration)
    var tabIDs: [UUID]
    var tabIndices: [Int]
    var orientation: SplitOrientation
    var ratios: [Double]
    /// the link source + target as tab ids, with the indices older builds read
    var linkSourceID: UUID?
    var linkTargetID: UUID?
    var linkSourceIndex: Int?
    var linkTargetIndex: Int?

    init(
        id: UUID, tree: SplitNodeData?, tabIDs: [UUID], tabIndices: [Int],
        orientation: SplitOrientation, ratios: [Double], linkSourceID: UUID?,
        linkTargetID: UUID?, linkSourceIndex: Int?, linkTargetIndex: Int?
    ) {
        self.id = id
        self.tree = tree
        self.tabIDs = tabIDs
        self.tabIndices = tabIndices
        self.orientation = orientation
        self.ratios = ratios
        self.linkSourceID = linkSourceID
        self.linkTargetID = linkTargetID
        self.linkSourceIndex = linkSourceIndex
        self.linkTargetIndex = linkTargetIndex
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        tree = try c.decodeIfPresent(SplitNodeData.self, forKey: .tree)
        tabIDs = try c.decodeIfPresent([UUID].self, forKey: .tabIDs) ?? []
        tabIndices = try c.decodeIfPresent([Int].self, forKey: .tabIndices) ?? []
        orientation = try c.decodeIfPresent(SplitOrientation.self, forKey: .orientation) ?? .columns
        ratios = try c.decodeIfPresent([Double].self, forKey: .ratios) ?? []
        linkSourceID = try c.decodeIfPresent(UUID.self, forKey: .linkSourceID)
        linkTargetID = try c.decodeIfPresent(UUID.self, forKey: .linkTargetID)
        linkSourceIndex = try c.decodeIfPresent(Int.self, forKey: .linkSourceIndex)
        linkTargetIndex = try c.decodeIfPresent(Int.self, forKey: .linkTargetIndex)
    }

    private enum CodingKeys: String, CodingKey {
        case id, tree, tabIDs, tabIndices, orientation, ratios
        case linkSourceID, linkTargetID, linkSourceIndex, linkTargetIndex
    }
}

/// codable sRGB color
nonisolated struct RGBA: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

/// a single colour blob in a mesh gradient: a normalised position on the
/// canvas (0…1 in each axis) and the colour radiating from it
nonisolated struct MeshPoint: Codable, Equatable, Hashable, Identifiable {
    var id: UUID = UUID()
    var x: Double
    var y: Double
    var color: RGBA

    enum CodingKeys: String, CodingKey { case id, x, y, color }
}

/// how a space paints its background
nonisolated enum SpaceFill: String, Codable, CaseIterable, Identifiable {
    case solid, gradient, glass
    var id: Self { self }
    var label: String {
        switch self {
        case .solid: "Solid"
        case .gradient: "Gradient"
        case .glass: "Glass"
        }
    }
}

/// a space's full background configuration — fill type, colors, gradient
/// angle, and film grain. drives both the window backdrop and the accent
nonisolated struct SpaceAppearance: Codable, Equatable {
    var fill: SpaceFill = .gradient
    var colors: [RGBA] = [RGBA(0.18, 0.14, 0.40), RGBA(0.30, 0.18, 0.48)]
    var angle: Double = 135  // gradient direction, degrees (legacy linear)
    var grain: Double = 0  // film-grain overlay, 0...1
    var glassBlur: Double = 0.6  // 0 = light frost … 1 = heavy frost
    var meshPoints: [MeshPoint] = []  // gradient fill paints these as a mesh
    var meshSharpness: Double = 4  // mesh blend tightness (2 soft … 10 distinct)

    enum CodingKeys: String, CodingKey {
        case fill, colors, angle, grain, glassBlur, meshPoints, meshSharpness
    }
}

// tolerant decoding (extension keeps the memberwise init) so adding fields
// never invalidates a saved appearance
nonisolated extension SpaceAppearance {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fill = try c.decodeIfPresent(SpaceFill.self, forKey: .fill) ?? .gradient
        colors =
            try c.decodeIfPresent([RGBA].self, forKey: .colors)
            ?? [RGBA(0.18, 0.14, 0.40), RGBA(0.30, 0.18, 0.48)]
        angle = try c.decodeIfPresent(Double.self, forKey: .angle) ?? 135
        grain = try c.decodeIfPresent(Double.self, forKey: .grain) ?? 0
        glassBlur = try c.decodeIfPresent(Double.self, forKey: .glassBlur) ?? 0.6
        meshPoints = try c.decodeIfPresent([MeshPoint].self, forKey: .meshPoints) ?? []
        meshSharpness = try c.decodeIfPresent(Double.self, forKey: .meshSharpness) ?? 4
    }
}

/// quick-pick preset appearances shown as swatches in the editor — a spread of
/// starting points (mesh gradients, solids, glass; some grainy) for users to
/// load and then tweak into their own
nonisolated struct SpacePreset: Identifiable {
    let id: Int
    let name: String
    let appearance: SpaceAppearance

    static let all: [SpacePreset] = [
        // 3-colour soft purple, no grain — the house look
        .init(id: 0, name: "Nebula", appearance: .mesh(
            sharpness: 4, grain: 0,
            (0.25, 0.28, RGBA(0.12, 0.10, 0.32)),
            (0.72, 0.35, RGBA(0.42, 0.20, 0.64)),
            (0.50, 0.82, RGBA(0.50, 0.20, 0.52)))),
        // 4-colour warm embers, crisp + grainy
        .init(id: 1, name: "Ember", appearance: .mesh(
            sharpness: 5, grain: 0.5,
            (0.22, 0.30, RGBA(0.22, 0.06, 0.07)),
            (0.70, 0.24, RGBA(0.56, 0.16, 0.12)),
            (0.52, 0.80, RGBA(0.80, 0.38, 0.15)),
            (0.16, 0.78, RGBA(0.42, 0.16, 0.08)))),
        // 2-colour wide ocean blend (very soft), no grain
        .init(id: 2, name: "Tide", appearance: .mesh(
            sharpness: 2.5, grain: 0,
            (0.30, 0.30, RGBA(0.05, 0.13, 0.30)),
            (0.72, 0.72, RGBA(0.12, 0.42, 0.50)))),
        // 4-colour aurora, distinct bands (high sharpness) + grain
        .init(id: 3, name: "Aurora", appearance: .mesh(
            sharpness: 7, grain: 0.35,
            (0.20, 0.30, RGBA(0.05, 0.18, 0.14)),
            (0.58, 0.24, RGBA(0.10, 0.42, 0.34)),
            (0.82, 0.62, RGBA(0.16, 0.50, 0.44)),
            (0.34, 0.80, RGBA(0.30, 0.20, 0.52)))),
        // 3-colour sunset, mild grain
        .init(id: 4, name: "Sunset", appearance: .mesh(
            sharpness: 3, grain: 0.25,
            (0.22, 0.28, RGBA(0.18, 0.12, 0.40)),
            (0.70, 0.34, RGBA(0.66, 0.18, 0.46)),
            (0.52, 0.80, RGBA(0.82, 0.42, 0.20)))),
        // 2-colour rose bloom, light grain
        .init(id: 5, name: "Bloom", appearance: .mesh(
            sharpness: 3.5, grain: 0.2,
            (0.30, 0.32, RGBA(0.30, 0.08, 0.28)),
            (0.74, 0.70, RGBA(0.66, 0.22, 0.44)))),
        // flat deep navy, no grain
        .init(id: 6, name: "Ink", appearance: .solid(RGBA(0.07, 0.08, 0.16), grain: 0)),
        // flat charcoal with a heavy grain tooth
        .init(id: 7, name: "Charcoal", appearance: .solid(RGBA(0.13, 0.13, 0.15), grain: 0.7)),
    ]

    static func appearance(forLegacyIndex index: Int) -> SpaceAppearance {
        all[max(0, min(index, all.count - 1))].appearance
    }
}

nonisolated extension SpaceAppearance {
    /// a mesh-gradient appearance from (x, y, colour) blobs
    static func mesh(
        sharpness: Double, grain: Double, _ points: (Double, Double, RGBA)...
    ) -> SpaceAppearance {
        let pts = points.map { MeshPoint(x: $0.0, y: $0.1, color: $0.2) }
        return SpaceAppearance(
            fill: .gradient, colors: pts.map(\.color), angle: 135, grain: grain,
            meshPoints: pts, meshSharpness: sharpness)
    }

    static func solid(_ color: RGBA, grain: Double = 0) -> SpaceAppearance {
        SpaceAppearance(fill: .solid, colors: [color], grain: grain)
    }

    /// an incognito window's fixed look — a near-black mesh with a cold violet
    /// undertone, darker and quieter than any preset so the window reads at a
    /// glance. not in `SpacePreset.all`: it belongs to incognito, not the swatch row
    static let incognito: SpaceAppearance = .mesh(
        sharpness: 3, grain: 0.12,
        (0.28, 0.26, RGBA(0.05, 0.04, 0.09)),
        (0.74, 0.38, RGBA(0.13, 0.09, 0.22)),
        (0.46, 0.84, RGBA(0.09, 0.06, 0.16)))
}

/// one per-site Boost: custom CSS (and optionally JS) applied to a host, the
/// install-nothing cousin of an extension
nonisolated struct Boost: Codable, Identifiable {
    var id = UUID()
    var host: String
    var css: String = ""
    var js: String = ""
    var isEnabled: Bool = true
}

/// a complete, portable copy of an Artemis setup as one readable JSON document: profiles and their
/// favourites, spaces (tabs, splits, appearance), Boosts, per-site zoom, and the preference values
/// that aren't derivable from those
nonisolated struct BackupArchive: Codable {
    /// bumped when the shape changes in a way an older build can't read
    var formatVersion = 1
    var createdAt = Date()
    var appVersion: String = Bundle.main
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    var session: BrowsingSession
    var boosts: [Boost]
    var zoomLevels: [String: Double]
    /// the subset of defaults worth carrying — anything the user deliberately set
    var preferences: [String: BackupValue]

    /// preference values, narrowed to what a browser setting can actually be.
    /// `Any` wouldn't be Codable, and a JSON blob of `AnyCodable` makes the file
    /// unreadable by hand — which defeats the point of an inspectable backup
    enum BackupValue: Codable, Equatable {
        case bool(Bool)
        case number(Double)
        case string(String)

        init?(_ value: Any) {
            switch value {
            case let value as Bool: self = .bool(value)
            case let value as Double: self = .number(value)
            case let value as Int: self = .number(Double(value))
            case let value as String: self = .string(value)
            default: return nil
            }
        }

        var raw: Any {
            switch self {
            case .bool(let value): value
            case .number(let value): value
            case .string(let value): value
            }
        }
    }
}
