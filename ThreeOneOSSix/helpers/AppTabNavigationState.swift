import Foundation

enum AppSection: Int, CaseIterable, Identifiable {
    case home
    case new
    case sources
    case installed
    case files
    case search
    case cleaner
    case wallpapers
    case backup

    var id: Int { rawValue }
}

extension AppSection {
    var titleKey: String {
        switch self {
        case .home: return "tab.features"
        case .new: return "tab.new"
        case .sources: return "tab.sources"
        case .installed: return "tab.installed"
        case .files: return "tab.files"
        case .search: return "tab.search"
        case .cleaner: return "tab.cleaner"
        case .wallpapers: return "tab.wallpapers"
        case .backup: return "tab.backup"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "square.grid.2x2.fill"
        case .new: return "clock.fill"
        case .sources: return "shippingbox.fill"
        case .installed: return "tray.full.fill"
        case .files: return "folder.fill"
        case .search: return "magnifyingglass"
        case .cleaner: return "sparkles"
        case .wallpapers: return "photo.on.rectangle.angled"
        case .backup: return "externaldrive.badge.timemachine"
        }
    }
}

enum TabBarSelection {
    static let storageKey = "tabbar.selection"
    static let maxSections = 5
    /// home(0), files(4), search(5), cleaner(6), backup(8)
    static let defaultRaw = "0,4,5,6,8"
    static let legacyDefaultRaw = "0,1,2,3,4"

    static func sections(from raw: String) -> [AppSection] {
        let selected = Set(raw.split(separator: ",").compactMap { Int($0) })
        var result = AppSection.allCases.filter { section in
            section == .home || selected.contains(section.rawValue)
        }
        if result.count > maxSections {
            result = Array(result.prefix(maxSections))
        }
        return result
    }

    static func encode(_ sections: [AppSection]) -> String {
        sections.map { String($0.rawValue) }.joined(separator: ",")
    }
}

enum WallpaperFeatureSupportPolicy {
    static func isSupported(major: Int) -> Bool {
        switch major {
        case 17, 18, 26, 27:
            return true
        default:
            return false
        }
    }
}

struct OneShotPresentationGate: Equatable {
    private(set) var hasClaimed = false

    mutating func claim() -> Bool {
        guard !hasClaimed else { return false }
        hasClaimed = true
        return true
    }
}

struct FeatureVisibility: Equatable {
    static let cleanerStorageKey = "feature.cleaner.enabled"
    static let developerModeStorageKey = "feature.developer_mode.enabled"

    let selectedSections: [AppSection]
    let wallpapersSupported: Bool
    let developerModeEnabled: Bool

    init(
        selectedSections: [AppSection],
        wallpapersSupported: Bool,
        developerModeEnabled: Bool
    ) {
        self.selectedSections = selectedSections
        self.wallpapersSupported = wallpapersSupported
        self.developerModeEnabled = developerModeEnabled
    }

    var visibleSections: [AppSection] {
        // Fixed product shape: 功能 / 文件 / 搜索 / 清理 / 备份. Wallpapers,
        // repository and patch entry points live inside the feature hub
        // instead of the tab bar.
        [.home, .files, .search, .cleaner, .backup]
    }

    func isVisible(_ section: AppSection) -> Bool {
        visibleSections.contains(section)
    }
}

struct AppTabNavigationState: Equatable {
    private(set) var selectedTab: Int
    private(set) var filesTabs: FilesTabSession

    init(
        selectedTab: Int = 0,
        filesNavigationPath: [FileBrowserDestination] = []
    ) {
        self.selectedTab = selectedTab
        var session = FilesTabSession()
        session.setActiveNavigationPath(filesNavigationPath)
        filesTabs = session
    }

    mutating func select(_ tab: Int) {
        selectedTab = tab
    }

    mutating func setFilesNavigationPath(_ path: [FileBrowserDestination]) {
        filesTabs.setActiveNavigationPath(path)
    }

    var filesNavigationPath: [FileBrowserDestination] {
        filesTabs.activeTab?.navigationPath ?? []
    }

    mutating func setFilesTabs(_ session: FilesTabSession) {
        filesTabs = session
    }

    mutating func reconcileSelection(with visibility: FeatureVisibility) {
        guard let selectedSection = AppSection(rawValue: selectedTab),
              visibility.isVisible(selectedSection) else {
            selectedTab = AppSection.home.rawValue
            return
        }
    }
}

struct FileBrowserDestination: Hashable {
    let containerPath: String
    let startPath: String
    let title: String
    let bundleID: String?
    let readOnly: Bool

    init(
        containerPath: String,
        startPath: String,
        title: String,
        bundleID: String?,
        readOnly: Bool = false
    ) {
        self.containerPath = containerPath
        self.startPath = startPath
        self.title = title
        self.bundleID = bundleID
        self.readOnly = readOnly
    }
}

struct FilesTabState: Identifiable, Equatable {
    let id: UUID
    var customTitle: String?
    var navigationPath: [FileBrowserDestination]

    func displayTitle(defaultTitle: String) -> String {
        customTitle ?? navigationPath.last?.title ?? defaultTitle
    }

    var currentPath: String? {
        navigationPath.last?.startPath
    }
}

struct FilesTabSession: Equatable {
    private(set) var tabs: [FilesTabState]
    private(set) var selectedTabID: UUID

    init(initialTabID: UUID = UUID()) {
        tabs = [FilesTabState(id: initialTabID, customTitle: nil, navigationPath: [])]
        selectedTabID = initialTabID
    }

    var activeTab: FilesTabState? {
        tabs.first { $0.id == selectedTabID }
    }

    func navigationPath(for id: UUID) -> [FileBrowserDestination] {
        tabs.first { $0.id == id }?.navigationPath ?? []
    }

    mutating func setNavigationPath(_ path: [FileBrowserDestination], for id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].navigationPath = path
    }

    mutating func setActiveNavigationPath(_ path: [FileBrowserDestination]) {
        setNavigationPath(path, for: selectedTabID)
    }

    mutating func openTab(
        id: UUID = UUID(),
        navigationPath: [FileBrowserDestination] = []
    ) {
        tabs.append(FilesTabState(id: id, customTitle: nil, navigationPath: navigationPath))
        selectedTabID = id
    }

    mutating func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    mutating func renameTab(_ id: UUID, to name: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[index].customTitle = trimmed.isEmpty ? nil : trimmed
    }

    mutating func closeTab(_ id: UUID, replacementID: UUID = UUID()) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count == 1 {
            tabs = [FilesTabState(id: replacementID, customTitle: nil, navigationPath: [])]
            selectedTabID = replacementID
            return
        }

        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
    }

    mutating func closeOtherTabs(keeping id: UUID) {
        guard let keptTab = tabs.first(where: { $0.id == id }) else { return }
        tabs = [keptTab]
        selectedTabID = id
    }
}
