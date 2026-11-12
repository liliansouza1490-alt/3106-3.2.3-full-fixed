import Foundation
import Combine

enum FileBrowserSortOrder: String, CaseIterable, Identifiable {
    static let storageKey = "browser.sort.order"

    case nameAscending
    case nameDescending
    case sizeDescending
    case sizeAscending
    case newestFirst
    case oldestFirst

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .nameAscending: return "browser.sort_name_ascending"
        case .nameDescending: return "browser.sort_name_descending"
        case .sizeDescending: return "browser.sort_size_descending"
        case .sizeAscending: return "browser.sort_size_ascending"
        case .newestFirst: return "browser.sort_newest"
        case .oldestFirst: return "browser.sort_oldest"
        }
    }

    var systemImage: String {
        switch self {
        case .nameAscending: return "textformat.abc"
        case .nameDescending: return "textformat.abc.dottedunderline"
        case .sizeDescending: return "arrow.down"
        case .sizeAscending: return "arrow.up"
        case .newestFirst: return "clock.arrow.circlepath"
        case .oldestFirst: return "clock"
        }
    }
}

enum FileBrowserSortPolicy {
    static func sorted<Record>(
        _ records: [Record],
        order: FileBrowserSortOrder,
        name: KeyPath<Record, String>,
        isDirectory: KeyPath<Record, Bool>,
        size: KeyPath<Record, Int64>,
        modifiedAt: KeyPath<Record, Date?>
    ) -> [Record] {
        records.sorted { left, right in
            let leftIsDirectory = left[keyPath: isDirectory]
            let rightIsDirectory = right[keyPath: isDirectory]
            if leftIsDirectory != rightIsDirectory {
                return leftIsDirectory
            }

            let leftName = left[keyPath: name]
            let rightName = right[keyPath: name]
            let nameOrder = leftName.localizedCaseInsensitiveCompare(rightName)

            switch order {
            case .nameAscending:
                return nameOrder == .orderedAscending
            case .nameDescending:
                return nameOrder == .orderedDescending
            case .sizeDescending, .sizeAscending:
                let leftSize = left[keyPath: size]
                let rightSize = right[keyPath: size]
                let leftKnown = leftSize >= 0
                let rightKnown = rightSize >= 0
                if leftKnown != rightKnown { return leftKnown }
                if leftSize != rightSize {
                    return order == .sizeDescending
                        ? leftSize > rightSize
                        : leftSize < rightSize
                }
            case .newestFirst, .oldestFirst:
                let leftDate = left[keyPath: modifiedAt]
                let rightDate = right[keyPath: modifiedAt]
                if leftDate == nil, rightDate != nil { return false }
                if leftDate != nil, rightDate == nil { return true }
                if let leftDate, let rightDate, leftDate != rightDate {
                    return order == .newestFirst
                        ? leftDate > rightDate
                        : leftDate < rightDate
                }
            }

            return nameOrder == .orderedAscending
        }
    }
}

struct FileBrowserDirectorySummary: Equatable {
    let byteCount: Int64
    let childCount: Int
    /// True when the walk hit the budget: byteCount is a floor, shown as "…"
    /// so the UI never implies an exact total for huge subtrees.
    let truncated: Bool

    init(byteCount: Int64, childCount: Int, truncated: Bool = false) {
        self.byteCount = byteCount
        self.childCount = childCount
        self.truncated = truncated
    }
}

enum FileBrowserMetadataScanner {
    static func directorySummary(
        at directory: URL,
        fileManager: FileManager = .default
    ) throws -> FileBrowserDirectorySummary {
        let rootValues = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw CocoaError(.fileReadInvalidFileName)
        }

        let childCount = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).count
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            throw CocoaError(.fileReadUnknown)
        }

        // Budget: app containers can hold 50k-500k files under Library; an
        // unbounded walk per directory row stalled listings for tens of
        // seconds. Same limits as the cleaner/size-meter walkers.
        let budgetEntries = 12_000
        let budgetSeconds: TimeInterval = 0.5
        let startedAt = Date()

        var byteCount: Int64 = 0
        var visited = 0
        var truncated = false
        for case let itemURL as URL in enumerator {
            visited += 1
            if visited % 512 == 0 {
                if visited >= budgetEntries
                    || Date().timeIntervalSince(startedAt) >= budgetSeconds {
                    truncated = true
                    break
                }
            }
            guard let values = try? itemURL.resourceValues(forKeys: Set(keys)) else {
                continue
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true else { continue }
            let itemSize = Int64(max(0, values.fileSize ?? 0))
            let (sum, overflow) = byteCount.addingReportingOverflow(itemSize)
            byteCount = overflow ? Int64.max : sum
        }

        return FileBrowserDirectorySummary(
            byteCount: byteCount,
            childCount: childCount,
            truncated: truncated
        )
    }
}

// MARK: - Favorites

/// One favorited folder. The JSON shape (`id` / `path` / `name`) is
/// intentionally identical to 3105 2.0's `fileBrowserFavorites`, so favorites
/// survive an upgrade from the old app.
struct FileFavorite: Codable, Identifiable, Hashable {
    let id: UUID
    let path: String
    let name: String
}

final class FileFavoritesStore: ObservableObject {
    static let shared = FileFavoritesStore()
    static let storageKey = "fileBrowserFavorites"

    @Published private(set) var favorites: [FileFavorite] = []

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func load() {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            favorites = []
            return
        }
        let decoded = (try? decoder.decode([FileFavorite].self, from: data)) ?? []
        var seen = Set<String>()
        favorites = decoded.compactMap { favorite in
            let path = Self.normalize(favorite.path)
            guard !path.isEmpty, seen.insert(path).inserted else { return nil }
            return FileFavorite(id: favorite.id, path: path, name: favorite.name)
        }
    }

    func add(path: String, name: String) {
        let normalized = Self.normalize(path)
        guard !normalized.isEmpty, !contains(path: normalized) else { return }
        let displayName = name.isEmpty
            ? (normalized as NSString).lastPathComponent
            : name
        favorites.append(FileFavorite(id: UUID(), path: normalized, name: displayName))
        save()
    }

    func remove(path: String) {
        let normalized = Self.normalize(path)
        favorites.removeAll { $0.path == normalized }
        save()
    }

    func contains(path: String) -> Bool {
        let normalized = Self.normalize(path)
        return favorites.contains { $0.path == normalized }
    }

    private func save() {
        guard let data = try? encoder.encode(favorites) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// `/var` and `/private/var` are the same location. Normalizing both keeps
    /// a folder favorited once no matter which spelling the browser used.
    static func normalize(_ path: String) -> String {
        var normalized = (path as NSString).standardizingPath
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        if normalized == "/var" || normalized.hasPrefix("/var/") {
            normalized = "/private" + normalized
        }
        return normalized
    }
}

/// Resolves the container root that owns a favorited folder, so the file
/// browser can open the favorite with the correct sandbox grant boundary.
enum FileFavoriteContainerRoot {
    private static let roots = [
        "/var/mobile/Containers/Data/Application",
        "/var/mobile/Containers/Data/PluginKitPlugin",
        "/var/mobile/Containers/Data/InternalDaemon",
        "/var/mobile/Containers/Data/System",
        "/var/mobile/Containers/Shared/AppGroup",
        "/var/containers/Shared/SystemGroup",
    ]

    static func containerPath(for rawPath: String) -> String? {
        let normalized = FileFavoritesStore.normalize(rawPath)
        let withoutPrivate = normalized.hasPrefix("/private/var/")
            ? String(normalized.dropFirst("/private".count))
            : normalized
        for root in roots {
            guard withoutPrivate == root || withoutPrivate.hasPrefix(root + "/") else {
                continue
            }
            let remainder = withoutPrivate.dropFirst(root.count)
            let component = remainder.split(separator: "/").first.map(String.init) ?? ""
            let rootPath = normalized.hasPrefix("/private/")
                ? "/private" + root
                : root
            return component.isEmpty ? rootPath : rootPath + "/" + component
        }
        return nil
    }
}
