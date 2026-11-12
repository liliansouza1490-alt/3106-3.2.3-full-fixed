import Foundation

enum WallpaperLabError: Error, Equatable {
    case unsafeContainerRoot
    case posterStoreUnavailable
    case unsupportedPosterLayout
    case unsupportedPackage
    case unsafeArchive
    case symbolicLinkUnsupported
    case packageTooLarge
    case noDescriptors
    case accessDenied
    case backupFailed
    case installFailed
    case restoreFailed
}

extension WallpaperLabError: LocalizedError {
    var localizationKey: String {
        switch self {
        case .unsafeContainerRoot: return "wallpaper.error.unsafe_container"
        case .posterStoreUnavailable: return "wallpaper.error.store_unavailable"
        case .unsupportedPosterLayout: return "wallpaper.error.layout"
        case .unsupportedPackage: return "wallpaper.error.package"
        case .unsafeArchive: return "wallpaper.error.archive"
        case .symbolicLinkUnsupported: return "wallpaper.error.symlink"
        case .packageTooLarge: return "wallpaper.error.size"
        case .noDescriptors: return "wallpaper.error.no_descriptors"
        case .accessDenied: return "wallpaper.error.access"
        case .backupFailed: return "wallpaper.error.backup"
        case .installFailed: return "wallpaper.error.install"
        case .restoreFailed: return "wallpaper.error.restore"
        }
    }

    var errorDescription: String? {
        String(localized: String.LocalizationValue(localizationKey))
    }
}

enum WallpaperLabLimits {
    static let maximumArchiveBytes: Int64 = 512 * 1_024 * 1_024
    static let maximumExpandedBytes: Int64 = 768 * 1_024 * 1_024
    static let maximumEntryBytes: Int64 = 768 * 1_024 * 1_024
    static let maximumEntryCount = 20_000
    static let maximumDescriptorCount = 64
    static let maximumPathBytes = 4_096
}

struct WallpaperPosterLayout: Equatable {
    static let collectionsExtension = "com.apple.WallpaperKit.CollectionsPoster"
    static let photosExtension = "com.apple.PhotosUIPrivate.PhotosPosterProvider"
    static let mercuryExtension = "com.apple.MercuryPoster"

    let generation: String
    let storeURL: URL
    let extensionDescriptorDirectories: [String: URL]

    var supportsCollections: Bool {
        extensionDescriptorDirectories[Self.collectionsExtension] != nil
    }

    var supportsVideo: Bool {
        extensionDescriptorDirectories[Self.photosExtension] != nil
    }
}

struct WallpaperDescriptorSource: Equatable, Identifiable {
    let extensionIdentifier: String
    let directoryURL: URL
    let byteCount: Int64
    let fileCount: Int
    let isOrdered: Bool

    var id: String { "\(extensionIdentifier):\(directoryURL.path)" }
}

struct TendiesPayload: Equatable {
    let descriptors: [WallpaperDescriptorSource]
    let totalBytes: Int64
    let fileCount: Int
}

enum WallpaperLayoutScanner {
    static let storeRelativePath = "Library/Application Support/PRBPosterExtensionDataStore"

    typealias RootValidator = (URL) -> Bool

    static func scan(
        containerURL rawContainerURL: URL,
        rootValidator: RootValidator,
        requiredExtensionIdentifiers: Set<String>? = nil,
        allowSyntheticLayout: Bool = false,
        fileManager: FileManager = .default
    ) throws -> WallpaperPosterLayout {
        // `/var` and `/private/var` are the same location, but FileManager
        // enumerators return the `/private` spelling. Resolve symlinks and
        // then force the `/private` prefix explicitly; on iOS,
        // resolvingSymlinksInPath() alone can leave `/var` unchanged.
        let containerPath = LaunchServicesStore.canonicalContainerPath(
            rawContainerURL.standardizedFileURL.resolvingSymlinksInPath().path
        )
        let containerURL = URL(fileURLWithPath: containerPath, isDirectory: true)
        guard containerURL.isFileURL,
              containerURL.path.hasPrefix("/"),
              containerURL.path != "/",
              rootValidator(containerURL) else {
            throw WallpaperLabError.unsafeContainerRoot
        }
        let accessGrant = ContainerStore.grantContainerAccess(containerURL.path)
        defer { SandboxAccess.release(accessGrant) }
        try validateDirectory(containerURL, fileManager: fileManager)
        log("wallpaper: scan root=\(containerURL.path)")

        let storeURL = containerURL.appendingPathComponent(
            storeRelativePath,
            isDirectory: true
        )
        guard isContained(storeURL, in: containerURL),
              fileManager.fileExists(atPath: storeURL.path) else {
            throw WallpaperLabError.posterStoreUnavailable
        }
        try validatePathComponents(
            relativePath: storeRelativePath,
            root: containerURL,
            fileManager: fileManager
        )

        let generationURLs = try fileManager.contentsOfDirectory(
            at: storeURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard Int(url.lastPathComponent) != nil else { return false }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }.sorted {
            (Int($0.lastPathComponent) ?? -1) > (Int($1.lastPathComponent) ?? -1)
        }

        if generationURLs.isEmpty {
            log(
                "wallpaper: no numeric generation dirs store=\(storeURL.path); " +
                    "trying recursive/synthetic layout"
            )
        }

        var candidateLayouts: [WallpaperPosterLayout] = []
        for generationURL in generationURLs {
            let extensionsURL = generationURL.appendingPathComponent("Extensions", isDirectory: true)
            guard fileManager.fileExists(atPath: extensionsURL.path) else { continue }
            try validateDirectory(extensionsURL, fileManager: fileManager)

            var descriptorDirectories: [String: URL] = [:]
            let extensions = try fileManager.contentsOfDirectory(
                at: extensionsURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            for extensionURL in extensions {
                let values = try extensionURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                guard validExtensionIdentifier(extensionURL.lastPathComponent) else { continue }
                let descriptorsURL = extensionURL.appendingPathComponent(
                    "descriptors",
                    isDirectory: true
                )
                guard fileManager.fileExists(atPath: descriptorsURL.path) else { continue }
                try validateDirectory(descriptorsURL, fileManager: fileManager)
                descriptorDirectories[extensionURL.lastPathComponent] = descriptorsURL
            }

            if !descriptorDirectories.isEmpty {
                candidateLayouts.append(WallpaperPosterLayout(
                    generation: generationURL.lastPathComponent,
                    storeURL: storeURL,
                    extensionDescriptorDirectories: descriptorDirectories
                ))
            }
        }
        if let preferred = preferredLayout(
            candidateLayouts,
            requested: Set((requiredExtensionIdentifiers ?? []).filter(validExtensionIdentifier))
        ) {
            log(
                "wallpaper: layout generation=\(preferred.generation) " +
                    "extensions=\(preferred.extensionDescriptorDirectories.keys.sorted())"
            )
            return preferred
        }

        log(
            "wallpaper: no descriptor dirs store=\(storeURL.path) " +
                "generations=\(generationURLs.map(\.lastPathComponent))"
        )

        // iOS 27.3 beta can nest the store differently. First try to find any
        // `descriptors` directory recursively (read-only; safe for packages).
        if let recursive = recursiveDescriptorLayout(
            storeURL: storeURL,
            fileManager: fileManager
        ) {
            log(
                "wallpaper: recursive layout generation=\(recursive.generation) " +
                    "extensions=\(recursive.extensionDescriptorDirectories.keys.sorted())"
            )
            return recursive
        }

        guard allowSyntheticLayout else {
            throw WallpaperLabError.unsupportedPosterLayout
        }

        if let treeLayout = logStoreTree(
            storeURL: storeURL,
            fileManager: fileManager
        ) {
            log(
                "wallpaper: tree layout generation=\(treeLayout.generation) " +
                    "extensions=\(treeLayout.extensionDescriptorDirectories.keys.sorted())"
            )
            return treeLayout
        }
        if let fallbackLayout = descriptorLayoutByPathEnumeration(
            storeURL: storeURL,
            fileManager: fileManager
        ) {
            log(
                "wallpaper: fallback layout generation=\(fallbackLayout.generation) " +
                    "extensions=\(fallbackLayout.extensionDescriptorDirectories.keys.sorted())"
            )
            return fallbackLayout
        }
        guard let generationURL = syntheticGenerationURL(
            storeURL: storeURL,
            numericGeneration: generationURLs.first,
            fileManager: fileManager
        ) else {
            throw WallpaperLabError.unsupportedPosterLayout
        }

        let requested = (requiredExtensionIdentifiers ?? [])
            .filter(validExtensionIdentifier)
        let identifiers = requested.isEmpty
            ? [WallpaperPosterLayout.collectionsExtension]
            : requested.sorted()

        let extensionsURL = generationURL.appendingPathComponent("Extensions", isDirectory: true)
        var grants: [Int64] = []
        defer {
            for grant in grants { SandboxAccess.release(grant) }
        }
        for path in [generationURL, extensionsURL] {
            let grant = ContainerStore.grantContainerAccess(path.path)
            if grant >= 0 { grants.append(grant) }
        }

        var created: [String: URL] = [:]
        do {
            try fileManager.createDirectory(
                at: extensionsURL,
                withIntermediateDirectories: true
            )
            for identifier in identifiers {
                let extensionURL = extensionsURL.appendingPathComponent(
                    identifier,
                    isDirectory: true
                )
                let descriptorsURL = extensionURL.appendingPathComponent(
                    "descriptors",
                    isDirectory: true
                )
                let grant = ContainerStore.grantContainerAccess(extensionURL.path)
                if grant >= 0 { grants.append(grant) }
                try fileManager.createDirectory(
                    at: descriptorsURL,
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: descriptorsURL.path) {
                    created[identifier] = descriptorsURL
                }
            }
        } catch {
            log("wallpaper: synthetic layout failed error=\(error)")
            throw WallpaperLabError.posterStoreUnavailable
        }

        guard !created.isEmpty else {
            throw WallpaperLabError.unsupportedPosterLayout
        }
        log(
            "wallpaper: synthetic layout generation=\(generationURL.lastPathComponent) " +
                "extensions=\(created.keys.sorted())"
        )
        return WallpaperPosterLayout(
            generation: generationURL.lastPathComponent,
            storeURL: storeURL,
            extensionDescriptorDirectories: created
        )
    }

    private static func recursiveDescriptorLayout(
        storeURL: URL,
        fileManager: FileManager
    ) -> WallpaperPosterLayout? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: storeURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                log("wallpaper: tree enumerate failed \(url.path) error=\(error.localizedDescription)")
                return true
            }
        ) else { return nil }

        var directories: [String: URL] = [:]
        var generation = "61"
        while let item = enumerator.nextObject() as? URL {
            guard item.lastPathComponent == "descriptors" else { continue }
            let values = try? item.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true,
                  values?.isSymbolicLink != true else { continue }
            let identifier = item.deletingLastPathComponent().lastPathComponent
            guard validExtensionIdentifier(identifier) else { continue }
            directories[identifier] = item

            let components = item.pathComponents
            if let extensionsIndex = components.firstIndex(of: "Extensions"),
               extensionsIndex > 0,
               let numeric = Int(components[extensionsIndex - 1]) {
                generation = String(numeric)
            }
        }
        guard !directories.isEmpty else { return nil }
        log("wallpaper: enumerator found \(directories.count) descriptor directories")
        return WallpaperPosterLayout(
            generation: generation,
            storeURL: storeURL,
            extensionDescriptorDirectories: directories
        )
    }

    /// Prefer a generation that already contains every provider the package
    /// needs. Without this, a stale higher generation can win and the install
    /// lands where PosterBoard never looks.
    private static func preferredLayout(
        _ layouts: [WallpaperPosterLayout],
        requested: Set<String>
    ) -> WallpaperPosterLayout? {
        guard let first = layouts.first else { return nil }
        guard !requested.isEmpty else { return first }

        var best = first
        var bestScore = requested.intersection(
            Set(first.extensionDescriptorDirectories.keys)
        ).count
        for layout in layouts.dropFirst() {
            let score = requested.intersection(
                Set(layout.extensionDescriptorDirectories.keys)
            ).count
            if score > bestScore {
                best = layout
                bestScore = score
            }
        }
        return best
    }

    private static func syntheticGenerationURL(
        storeURL: URL,
        numericGeneration: URL?,
        fileManager: FileManager
    ) -> URL? {
        if let numericGeneration { return numericGeneration }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let children = (try? fileManager.contentsOfDirectory(
            at: storeURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        let directories = children.filter { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }
        if let withExtensions = directories.first(where: {
            fileManager.fileExists(
                atPath: $0.appendingPathComponent("Extensions", isDirectory: true).path
            )
        }) {
            return withExtensions
        }
        let fallback = storeURL.appendingPathComponent("61", isDirectory: true)
        do {
            log("wallpaper: creating synthetic generation \(fallback.path)")
            try fileManager.createDirectory(at: fallback, withIntermediateDirectories: true)
            return fallback
        } catch {
            log("wallpaper: cannot create generation directory \(fallback.path) error=\(error)")
            return directories.first
        }
    }

    /// The diagnostic tree and the descriptor discovery share one enumerator:
    /// the direct `fileExists`/`contentsOfDirectory` calls can be denied by the
    /// sandbox while this traversal succeeds. Returning the layout from the
    /// same pass avoids a second enumeration that may fail at a different
    /// moment.
    @discardableResult
    private static func logStoreTree(
        storeURL: URL,
        fileManager: FileManager
    ) -> WallpaperPosterLayout? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: storeURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                log("wallpaper: tree error \(url.path) error=\(error.localizedDescription)")
                return true
            }
        ) else { return nil }
        var count = 0
        var descriptorDirectories: [String: URL] = [:]
        var generation = "61"
        while let item = enumerator.nextObject() as? URL {
            let relative = relativePath(of: item, under: storeURL)
            let depth = relative.split(separator: "/").count
            if depth > 6 {
                enumerator.skipDescendants()
                continue
            }
            count += 1
            if count > 1_000 {
                log("wallpaper: tree truncated at 1000 entries")
                break
            }
            let values = try? item.resourceValues(forKeys: Set(keys))
            let kind: String
            if values?.isSymbolicLink == true {
                kind = "link"
            } else if values?.isDirectory == true {
                kind = "dir"
            } else {
                kind = "file"
            }
            log("wallpaper: tree \(kind) \(relative)")

            guard item.lastPathComponent == "descriptors" else { continue }
            let identifier = item.deletingLastPathComponent().lastPathComponent
            guard validExtensionIdentifier(identifier) else { continue }
            descriptorDirectories[identifier] = item
            let components = item.pathComponents
            if let extensionsIndex = components.firstIndex(of: "Extensions"),
               extensionsIndex > 0,
               let numeric = Int(components[extensionsIndex - 1]) {
                generation = String(numeric)
            }
        }
        log("wallpaper: tree descriptor candidates=\(descriptorDirectories.count)")
        guard !descriptorDirectories.isEmpty else { return nil }
        return WallpaperPosterLayout(
            generation: generation,
            storeURL: storeURL,
            extensionDescriptorDirectories: descriptorDirectories
        )
    }

    /// A second, deliberately simple pass over the same store. The tree pass
    /// proves the enumerator can see `descriptors`; this fallback only relies
    /// on the path suffix and does not inspect resource values.
    private static func descriptorLayoutByPathEnumeration(
        storeURL: URL,
        fileManager: FileManager
    ) -> WallpaperPosterLayout? {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: storeURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { url, error in
                log("wallpaper: fallback enumerate error \(url.path) \(error.localizedDescription)")
                return true
            }
        ) else { return nil }

        var directories: [String: URL] = [:]
        var generation = "61"
        while let item = enumerator.nextObject() as? URL {
            let path = item.path
            guard path.hasSuffix("/descriptors") ||
                    item.lastPathComponent == "descriptors" else {
                continue
            }
            let parent = (path as NSString).deletingLastPathComponent
            let identifier = (parent as NSString).lastPathComponent
            guard validExtensionIdentifier(identifier) else {
                log("wallpaper: fallback descriptor parent skipped \(identifier)")
                continue
            }
            directories[identifier] = item
            let components = item.pathComponents
            if let extensionsIndex = components.firstIndex(of: "Extensions"),
               extensionsIndex > 0,
               let numeric = Int(components[extensionsIndex - 1]) {
                generation = String(numeric)
            }
        }
        log("wallpaper: fallback descriptor candidates=\(directories.count)")
        guard !directories.isEmpty else { return nil }
        return WallpaperPosterLayout(
            generation: generation,
            storeURL: storeURL,
            extensionDescriptorDirectories: directories
        )
    }

    static func validExtensionIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255, value.contains(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }

    static func validateDirectory(
        _ url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw WallpaperLabError.posterStoreUnavailable
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw WallpaperLabError.symbolicLinkUnsupported
        }
        guard values.isDirectory == true else {
            throw WallpaperLabError.unsupportedPosterLayout
        }
    }

    static func validatePathComponents(
        relativePath: String,
        root: URL,
        fileManager: FileManager = .default
    ) throws {
        var cursor = root
        for component in relativePath.split(separator: "/").map(String.init) {
            cursor.appendPathComponent(component, isDirectory: true)
            guard isContained(cursor, in: root) else {
                throw WallpaperLabError.unsafeContainerRoot
            }
            try validateDirectory(cursor, fileManager: fileManager)
        }
    }

    /// FileManager may return `/private/var` children for a `/var` root (or
    /// the reverse). Strip either spelling instead of relying on one exact
    /// prefix; a mismatch used to make the recursive scan skip everything.
    private static func relativePath(of item: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let itemPath = item.standardizedFileURL.path

        func strip(_ prefix: String, from value: String) -> String? {
            if value == prefix { return "" }
            guard value.hasPrefix(prefix + "/") else { return nil }
            return String(value.dropFirst(prefix.count + 1))
        }

        if let relative = strip(rootPath, from: itemPath) { return relative }

        let alternateRoot = rootPath.hasPrefix("/private/")
            ? String(rootPath.dropFirst("/private".count))
            : "/private" + rootPath
        if let relative = strip(alternateRoot, from: itemPath) { return relative }

        let alternateItem = itemPath.hasPrefix("/private/")
            ? String(itemPath.dropFirst("/private".count))
            : "/private" + itemPath
        if let relative = strip(rootPath, from: alternateItem) { return relative }

        return item.lastPathComponent
    }

    static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        func canonical(_ url: URL) -> String {
            LaunchServicesStore.canonicalContainerPath(
                url.standardizedFileURL.resolvingSymlinksInPath().path
            )
        }
        return canonical(lhs) == canonical(rhs)
    }

    static func isContained(_ candidate: URL, in root: URL) -> Bool {
        // resolvingSymlinksInPath() can stop early inside the sandbox and
        // return mixed spellings for the same tree (issue #2), so containment
        // must not depend on the resolved forms matching. Accept either
        // spelling on either side; the resolved paths only add extra accepted
        // forms on top of the raw canonical ones.
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if LaunchServicesStore.isPath(candidatePath, containedIn: rootPath) { return true }
        return LaunchServicesStore.isPath(
            candidate.standardizedFileURL.resolvingSymlinksInPath().path,
            containedIn: rootPath
        ) || LaunchServicesStore.isPath(
            candidatePath,
            containedIn: root.standardizedFileURL.resolvingSymlinksInPath().path
        ) || LaunchServicesStore.isPath(
            candidate.standardizedFileURL.resolvingSymlinksInPath().path,
            containedIn: root.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }
}

enum TendiesPackageInspector {
    static func inspectExtractedPackage(
        at packageURL: URL,
        fileManager: FileManager = .default
    ) throws -> TendiesPayload {
        // Use one spelling of the extraction root for the whole inspection so
        // children enumerated under it cannot diverge from the root itself.
        let packageURL = packageURL.standardizedFileURL
        try WallpaperLayoutScanner.validateDirectory(packageURL, fileManager: fileManager)
        log("wallpaper: inspecting package root=\(packageURL.path)")
        let descriptors = try collectDescriptorSources(
            in: packageURL,
            packageRoot: packageURL,
            fileManager: fileManager
        )
        log("wallpaper: collected \(descriptors.count) descriptor sources")

        guard !descriptors.isEmpty else { throw WallpaperLabError.noDescriptors }
        guard descriptors.count <= WallpaperLabLimits.maximumDescriptorCount else {
            throw WallpaperLabError.packageTooLarge
        }
        let totalBytes = descriptors.reduce(Int64(0)) { $0 + $1.byteCount }
        let fileCount = descriptors.reduce(0) { $0 + $1.fileCount }
        guard totalBytes <= WallpaperLabLimits.maximumExpandedBytes,
              fileCount <= WallpaperLabLimits.maximumEntryCount else {
            throw WallpaperLabError.packageTooLarge
        }
        return TendiesPayload(
            descriptors: descriptors,
            totalBytes: totalBytes,
            fileCount: fileCount
        )
    }

    /// Some .tendies packages put a `VideoCAML` folder inside a generically
    /// named descriptor directory. Erosion treats that as a Photos provider
    /// descriptor; match that behavior instead of installing it as a
    /// collections poster.
    private static func descriptorFolderContainsVideoCAML(
        _ directory: URL,
        fileManager: FileManager
    ) -> Bool {
        let children = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.contains { $0.lastPathComponent == "VideoCAML" }
    }

    private static func collectDescriptorSources(
        in directory: URL,
        packageRoot: URL,
        fileManager: FileManager
    ) throws -> [WallpaperDescriptorSource] {
        guard WallpaperLayoutScanner.isContained(directory, in: packageRoot) else {
            log(
                "wallpaper: package directory outside root, skipping " +
                    "\(directory.path) root=\(packageRoot.path)"
            )
            return []
        }
        try WallpaperLayoutScanner.validateDirectory(directory, fileManager: fileManager)
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var result: [WallpaperDescriptorSource] = []

        for child in children where child.lastPathComponent != "__MACOSX" {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                log("wallpaper: package symlink skipped \(child.path)")
                continue
            }
            guard values.isDirectory == true else { continue }

            let name = child.lastPathComponent.lowercased()
            if name == "container" {
                let layout = try WallpaperLayoutScanner.scan(
                    containerURL: child,
                    rootValidator: { WallpaperLayoutScanner.sameDirectory($0, child) },
                    fileManager: fileManager
                )
                for (identifier, descriptorDirectory) in layout.extensionDescriptorDirectories
                    .sorted(by: { $0.key < $1.key }) {
                    result += try descriptorSources(
                        in: descriptorDirectory,
                        extensionIdentifier: identifier,
                        isOrdered: false,
                        packageRoot: packageRoot,
                        fileManager: fileManager
                    )
                }
            } else if name.contains("descriptor") {
                let extensionIdentifier: String
                if name.contains("video")
                    || name.contains("photos")
                    || descriptorFolderContainsVideoCAML(child, fileManager: fileManager) {
                    extensionIdentifier = WallpaperPosterLayout.photosExtension
                } else if name.contains("mercury") {
                    extensionIdentifier = WallpaperPosterLayout.mercuryExtension
                } else {
                    extensionIdentifier = WallpaperPosterLayout.collectionsExtension
                }
                result += try descriptorSources(
                    in: child,
                    extensionIdentifier: extensionIdentifier,
                    isOrdered: name.contains("ordered"),
                    packageRoot: packageRoot,
                    fileManager: fileManager
                )
            } else {
                result += try collectDescriptorSources(
                    in: child,
                    packageRoot: packageRoot,
                    fileManager: fileManager
                )
            }
        }
        return result
    }

    private static func descriptorSources(
        in directory: URL,
        extensionIdentifier: String,
        isOrdered: Bool,
        packageRoot: URL,
        fileManager: FileManager
    ) throws -> [WallpaperDescriptorSource] {
        guard WallpaperLayoutScanner.validExtensionIdentifier(extensionIdentifier),
              WallpaperLayoutScanner.isContained(directory, in: packageRoot) else {
            log(
                "wallpaper: descriptor source skipped dir=\(directory.path) " +
                    "root=\(packageRoot.path) " +
                    "dirResolved=\(directory.standardizedFileURL.resolvingSymlinksInPath().path) " +
                    "rootResolved=\(packageRoot.standardizedFileURL.resolvingSymlinksInPath().path) " +
                    "extension=\(extensionIdentifier)"
            )
            return []
        }
        try WallpaperLayoutScanner.validateDirectory(directory, fileManager: fileManager)
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var result: [WallpaperDescriptorSource] = []
        var regularFileCount = 0
        for child in children where child.lastPathComponent != "__MACOSX" {
            let values = try child.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                log("wallpaper: descriptor symlink skipped \(child.path)")
                continue
            }
            guard values.isDirectory == true else {
                if values.isRegularFile == true { regularFileCount += 1 }
                continue
            }
            let summary = try validateTree(
                at: child,
                packageRoot: packageRoot,
                fileManager: fileManager
            )
            result.append(
                WallpaperDescriptorSource(
                    extensionIdentifier: extensionIdentifier,
                    directoryURL: child,
                    byteCount: summary.bytes,
                    fileCount: summary.files,
                    isOrdered: isOrdered
                )
            )
        }
        // Some .tendies packages store the descriptor files directly under
        // `descriptors/` instead of one folder per descriptor. Treat the
        // folder itself as the descriptor so those packages are not rejected.
        if result.isEmpty, regularFileCount > 0 {
            let summary = try validateTree(
                at: directory,
                packageRoot: packageRoot,
                fileManager: fileManager
            )
            result.append(
                WallpaperDescriptorSource(
                    extensionIdentifier: extensionIdentifier,
                    directoryURL: directory,
                    byteCount: summary.bytes,
                    fileCount: summary.files,
                    isOrdered: isOrdered
                )
            )
            log("wallpaper: loose descriptor files in \(directory.path) treated as one descriptor")
        }
        return result
    }

    private static func validateTree(
        at directory: URL,
        packageRoot: URL,
        fileManager: FileManager
    ) throws -> (bytes: Int64, files: Int) {
        guard WallpaperLayoutScanner.isContained(directory, in: packageRoot) else {
            log(
                "wallpaper: validateTree root outside package, skipping " +
                    "\(directory.path) root=\(packageRoot.path)"
            )
            return (0, 0)
        }
        var bytes: Int64 = 0
        var files = 0
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw WallpaperLabError.unsupportedPackage
        }
        for case let itemURL as URL in enumerator {
            guard WallpaperLayoutScanner.isContained(itemURL, in: packageRoot) else {
                log(
                    "wallpaper: package item outside root, skipping " +
                        "\(itemURL.path) root=\(packageRoot.path)"
                )
                continue
            }
            guard itemURL.path.utf8.count <= WallpaperLabLimits.maximumPathBytes else {
                log("wallpaper: package item path too long, skipping \(itemURL.path)")
                continue
            }
            let values = try itemURL.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
            ])
            if values.isSymbolicLink == true {
                log("wallpaper: package symlink skipped \(itemURL.path)")
                continue
            }
            if values.isRegularFile == true {
                let size = Int64(values.fileSize ?? 0)
                guard size >= 0, size <= WallpaperLabLimits.maximumEntryBytes else {
                    throw WallpaperLabError.packageTooLarge
                }
                bytes += size
                files += 1
                guard bytes <= WallpaperLabLimits.maximumExpandedBytes,
                      files <= WallpaperLabLimits.maximumEntryCount else {
                    throw WallpaperLabError.packageTooLarge
                }
            } else if values.isDirectory != true {
                log("wallpaper: package special file skipped \(itemURL.path)")
                continue
            }
        }
        return (bytes, files)
    }
}
