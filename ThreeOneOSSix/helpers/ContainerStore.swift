import Foundation
import Darwin
import UIKit

// MARK: - Models

struct InstalledApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let containerPath: String
    let version: String
    let icon: UIImage?

    var id: String { bundleID }
    var displayName: String {
        AppDisplayNamePolicy.resolve(bundleID: bundleID, candidates: [name])
    }

    static func == (lhs: InstalledApp, rhs: InstalledApp) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct FileEntry: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64
    let modifiedAt: Date?
    let childCount: Int?

    var id: String { path }
    var sizeText: String {
        guard size >= 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    init(
        name: String,
        path: String,
        isDirectory: Bool,
        size: Int64,
        modifiedAt: Date? = nil,
        childCount: Int? = nil
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.childCount = childCount
    }

    func withDirectorySummary(_ summary: FileBrowserDirectorySummary?) -> FileEntry {
        FileEntry(
            name: name,
            path: path,
            isDirectory: isDirectory,
            size: summary?.byteCount ?? -2,
            modifiedAt: modifiedAt,
            childCount: summary?.childCount
        )
    }
}

// MARK: - Store

enum ContainerStore {
    static let appDataRoot = "/var/mobile/Containers/Data/Application"
    static let systemDataRoot = "/var/mobile/Containers/Data/System"
    private static var requiresSandboxGrant: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26
    }
    private static let applicationBundleRoots: [(path: String, nested: Bool)] = [
        ("/var/containers/Bundle/Application", true),
        ("/Applications", false),
        ("/System/Applications", false)
    ]
    static let researchAppIdentifiers = [
        "com.apple.mobilesafari", "com.apple.mobilenotes", "com.apple.Maps",
        "com.apple.facetime", "com.apple.iBooks", "com.apple.podcasts",
        "com.apple.PosterBoard", "com.apple.mobilemail", "com.apple.weather",
        "com.apple.camera", "com.apple.Health", "com.apple.Fitness",
        "com.apple.tips", "com.apple.Passbook", "com.apple.reminders",
        "com.apple.stocks", "com.apple.news", "com.apple.Home", "com.apple.tv",
        "com.apple.shortcuts", "com.apple.freeform", "com.apple.calculator",
        "com.apple.MobileSMS", "com.apple.InCallService", "com.apple.Preferences",
        "com.apple.springboard", "com.apple.Photos", "com.apple.AppStore",
        "com.apple.Music", "com.apple.Bridge", "com.apple.Clock",
        "com.apple.VoiceMemos", "com.apple.Translate", "com.apple.measure",
        "com.apple.compass", "com.apple.Magnifier", "com.apple.DocumentsApp"
    ]

    static func resolveAppContainerPath(bundleID: String) -> String? {
        guard (try? PatchPathValidator.canonicalBundleIdentifier(bundleID)) == bundleID else {
            return nil
        }
        // iOS 27.2+: containermanager path↔identifier index is the most reliable
        // source once the metadata plist / xattr are gone. Try it first on 27+.
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        if major >= 27 {
            if let mapped = worse_query_identifier_paths()[bundleID],
               isApplicationContainerPath(mapped) {
                log("patch: container index resolved \(bundleID) (iOS 27)")
                return mapped
            }
            if let reverse = worse_query_path_identifiers().first(where: { $0.value == bundleID })?.key,
               isApplicationContainerPath(reverse) {
                log("patch: reverse container index resolved \(bundleID) (iOS 27)")
                return reverse
            }
        }
        // The LaunchServices store pairs a bundle id with its data container
        // even when MCM activation and the metadata plist are unavailable.
        if let mapped = launchServicesSnapshot()?.containerPath(forBundleID: bundleID),
           isApplicationContainerPath(mapped) {
            log("patch: LaunchServices store resolved \(bundleID)")
            return mapped
        }
        var lookupError: NSString?
        if let path = MCMActivateContainerPath(2, bundleID, false, &lookupError),
           isApplicationContainerPath(path) {
            log("patch: MHA-C2 resolved \(bundleID)")
            return path
        }
        let detail = lookupError.map(String.init) ?? "unavailable"
        log("patch: MHA-C2 could not resolve \(bundleID), detail=\(detail)")

        // Fallback for all versions: containermanager index.
        if let mapped = worse_query_identifier_paths()[bundleID],
           isApplicationContainerPath(mapped) {
            log("patch: container index resolved \(bundleID)")
            return mapped
        }
        if let reverse = worse_query_path_identifiers().first(where: { $0.value == bundleID })?.key,
           isApplicationContainerPath(reverse) {
            log("patch: reverse container index resolved \(bundleID)")
            return reverse
        }

        // Fallback for iOS builds where MCM refuses to hand out sandbox
        // tokens (e.g. iOS 18.1.x): scan the app-data root with the inode
        // walk and read each container's MCM metadata plist directly. The
        // raw reads only succeed when the sandbox escape is active.
        if let scanned = resolveAppContainerPathByMetadataScan(bundleID: bundleID) {
            log("patch: filesystem metadata scan resolved \(bundleID)")
            return scanned
        }
        return nil
    }

    static func resolveAppContainerPathByMetadataScan(bundleID: String) -> String? {
        // iOS < 26: kernel R/W is enough, no need to require full sandbox escape
        if KernelExploit.requiresSandboxEscape, !KernelExploit.hasSandboxAccess() {
            log("patch: metadata scan skipped — sandbox access not active")
            return nil
        }
        let dirs = enumerateDirectories(path: appDataRoot)
        guard !dirs.isEmpty else {
            log("patch: metadata scan unavailable — no containers enumerated")
            return nil
        }
        for dir in dirs {
            guard UUID(uuidString: (dir as NSString).lastPathComponent) != nil else { continue }
            guard let metadata = readContainerMetadata(containerPath: dir),
                  metadata.bundleID == bundleID else { continue }
            let canonical = ContainerDiscoveryMerger.canonicalPath(dir)
            guard isApplicationContainerPath(canonical) else { continue }
            return canonical
        }
        return nil
    }

    // MARK: Primary — MobileInstallation / LSApplicationWorkspace

    static func installedAppsFromAPI() -> [InstalledApp] {
        let raw = installedAppInfo() as? [String: [String: Any]] ?? [:]
        let snapshot = launchServicesSnapshot()
        var apps: [InstalledApp] = []
        var missingContainer = 0
        for (bundleID, info) in raw {
            var containerPath = info["container"] as? String ?? ""
            // `containerURL` can be the bundle container, which is not app
            // data. Prefer the LaunchServices store's data-container path.
            if !containerPath.isEmpty && !isApplicationContainerPath(containerPath) {
                containerPath = ""
            }
            if containerPath.isEmpty,
               let mapped = snapshot?.containerPath(forBundleID: bundleID),
               isApplicationContainerPath(mapped) {
                containerPath = mapped
            }
            if containerPath.isEmpty {
                var lookupError: NSString?
                if let resolved = MCMActivateContainerPath(2, bundleID, false, &lookupError),
                   isApplicationContainerPath(resolved) {
                    containerPath = resolved
                } else {
                    missingContainer += 1
                }
            }
            // Skip entries we cannot browse — empty path is dropped by mergers anyway.
            guard !containerPath.isEmpty else { continue }
            apps.append(InstalledApp(
                bundleID: bundleID,
                name: AppDisplayNamePolicy.resolve(
                    bundleID: bundleID,
                    candidates: [info["name"] as? String, snapshot?.displayName(forBundleID: bundleID)]
                ),
                containerPath: containerPath,
                version: info["version"] as? String ?? "",
                icon: info["icon"] as? UIImage
            ))
        }
        log("browser: LS/API apps=\(apps.count) raw=\(raw.count) missingContainer=\(missingContainer) launchServices=\(snapshot?.mappedContainerCount ?? 0)")
        return apps
    }

    static func applicationBundleMetadataCatalog() -> [String: ApplicationBundleMetadata] {
        var catalog: [String: ApplicationBundleMetadata] = [:]
        for root in applicationBundleRoots {
            for metadata in applicationBundleMetadata(at: root.path, nested: root.nested) {
                catalog[metadata.bundleID] = metadata
            }
        }
        log("browser: app-bundle metadata resolved \(catalog.count) names")
        return catalog
    }

    static func applyingBundleMetadata(
        to apps: [InstalledApp],
        catalog: [String: ApplicationBundleMetadata]
    ) -> [InstalledApp] {
        apps.map { app in
            guard let metadata = catalog[app.bundleID] else { return app }
            return InstalledApp(
                bundleID: app.bundleID,
                name: AppDisplayNamePolicy.resolve(
                    bundleID: app.bundleID,
                    candidates: [metadata.displayName, app.name]
                ),
                containerPath: app.containerPath,
                version: app.version.isEmpty ? metadata.version : app.version,
                icon: app.icon
            )
        }
    }

    static func dynamicAppIdentifiers() -> [String] {
        var enumerationError: NSString?
        let identifiers = MCMEnumerateIdentifiersForClass(2, 1_024, &enumerationError)
        let enumerationDetail = enumerationError.map { String($0) } ?? "none"
        log("browser: MCM class-2 identifiers=\(identifiers.count) detail=\(enumerationDetail)")
        return identifiers
    }

    /// Activate class-2 containers for many bundle IDs concurrently. The MCM
    /// XPC round-trip (containermanagerd) is the dominant cost of a cold
    /// scan; a bounded concurrent pool (conservative cap 4 — the private
    /// framework's reentrancy is unverified, so keep parallelism modest)
    /// cuts wall-clock roughly 3-4x on a device with 150+ apps. Returns
    /// activation results keyed by bundle ID (failures map to nil) plus the
    /// containermanagerd error strings for the stage-2 failure logs.
    static func activateContainersParallel(
        _ identifiers: [String],
        maxConcurrent: Int = 4
    ) -> (paths: [String: String?], errors: [String: String]) {
        var results = [String: String?]()
        var errors = [String: String]()
        guard !identifiers.isEmpty else { return (results, errors) }
        let lock = NSLock()
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = max(1, maxConcurrent)
        for bundleID in identifiers {
            queue.addOperation {
                var lookupError: NSString?
                let activatedPath = MCMActivateContainerPath(2, bundleID, false, &lookupError)
                lock.lock()
                results[bundleID] = activatedPath
                if activatedPath == nil, let detail = lookupError as String?, !detail.isEmpty {
                    errors[bundleID] = detail
                }
                lock.unlock()
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return (results, errors)
    }

    static func installedAppsFromMCM(
        identifiers: [String]? = nil,
        bundleMetadata: [String: ApplicationBundleMetadata] = [:]
    ) -> [InstalledApp] {
        let identifiers = identifiers ?? dynamicAppIdentifiers()
        let snapshot = launchServicesSnapshot()

        // Stage 1 (parallel): activate every class-2 container. The XPC round
        // trips dominate; LSApplicationProxy lookups stay serial afterwards
        // because the private-framework query is not concurrency-safe.
        let activation = activateContainersParallel(identifiers)
        let activations = activation.paths

        // Stage 2 (serial): validate paths and assemble app records.
        var apps: [InstalledApp] = []
        for (index, bundleID) in identifiers.enumerated() {
            let activatedPath = activations[bundleID] ?? nil
            let containerPath = activatedPath.flatMap {
                isApplicationContainerPath($0) ? $0 : nil
            } ?? snapshot?.containerPath(forBundleID: bundleID)
            guard let containerPath,
                  isApplicationContainerPath(containerPath) else {
                let detail = activation.errors[bundleID] ?? "no path"
                if index < 3 { log("mcm[\(index)]: \(bundleID) -> \(detail)") }
                continue
            }
            if index < 3 { log("mcm[\(index)]: \(bundleID) -> \(containerPath)") }

            let rawInfo = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]
            let metadata = bundleMetadata[bundleID]
            apps.append(InstalledApp(
                bundleID: bundleID,
                name: AppDisplayNamePolicy.resolve(
                    bundleID: bundleID,
                    candidates: [
                        metadata?.displayName,
                        rawInfo["name"] as? String,
                        snapshot?.displayName(forBundleID: bundleID),
                    ]
                ),
                containerPath: containerPath,
                version: rawInfo["version"] as? String ?? metadata?.version ?? "",
                icon: rawInfo["icon"] as? UIImage
            ))
        }
        log("browser: MCM resolved \(apps.count)/\(identifiers.count) app paths")
        return apps
    }

    // MARK: LaunchServices store discovery

    static func installedAppsFromMHACandidates(
        identifiers: [String],
        bundleMetadata: [String: ApplicationBundleMetadata] = [:],
        progress: (([InstalledApp]) -> Void)? = nil
    ) -> [InstalledApp] {
        guard !identifiers.isEmpty else {
            log("browser: MHA catalog returned no bundle candidates")
            return []
        }

        let snapshot = launchServicesSnapshot()
        // Two-stage pass (same rationale as installedAppsFromMCM): parallel
        // MCM activation, then serial metadata assembly. Progress callbacks
        // fire per batch of 8 resolved apps as before.
        let activation = activateContainersParallel(identifiers)
        let activations = activation.paths
        var apps: [InstalledApp] = []
        for (index, bundleID) in identifiers.enumerated() {
            let activatedPath = activations[bundleID] ?? nil
            let containerPath = activatedPath.flatMap {
                isApplicationContainerPath($0) ? $0 : nil
            } ?? snapshot?.containerPath(forBundleID: bundleID)
            guard let containerPath,
                  isApplicationContainerPath(containerPath) else {
                if index < 3 {
                    let detail = activation.errors[bundleID]
                        ?? (activatedPath == nil ? "no path" : "invalid app-data path")
                    log("mha-candidate[\(index)]: \(bundleID) -> \(detail)")
                }
                continue
            }

            let rawInfo = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]
            let metadata = bundleMetadata[bundleID]
            apps.append(InstalledApp(
                bundleID: bundleID,
                name: AppDisplayNamePolicy.resolve(
                    bundleID: bundleID,
                    candidates: [
                        metadata?.displayName,
                        rawInfo["name"] as? String,
                        snapshot?.displayName(forBundleID: bundleID),
                    ]
                ),
                containerPath: containerPath,
                version: rawInfo["version"] as? String ?? metadata?.version ?? "",
                icon: rawInfo["icon"] as? UIImage
            ))
            if apps.count <= 5 {
                log("browser: MHA-C2 resolved \(bundleID) -> \(containerPath)")
            }
            if apps.count.isMultiple(of: 8) {
                progress?(apps)
            }
        }

        progress?(apps)
        log("browser: MHA-C2 resolved \(apps.count)/\(identifiers.count) bundle candidates")
        return apps
    }

    private static func applicationBundleMetadata(
        at rootPath: String,
        nested: Bool
    ) -> [ApplicationBundleMetadata] {
        let handle = grantContainerAccess(rootPath)
        defer {
            if handle >= 0 { SandboxAccess.release(handle) }
        }

        let fileManager = FileManager.default
        guard let rootEntries = try? fileManager.contentsOfDirectory(atPath: rootPath) else {
            log("browser: app-bundle metadata unavailable root=\(rootPath) grant=\(handle)")
            return []
        }

        let bundlePaths: [String]
        if nested {
            bundlePaths = rootEntries.prefix(2_048).flatMap { entry -> [String] in
                guard UUID(uuidString: entry) != nil else { return [] }
                let containerPath = (rootPath as NSString).appendingPathComponent(entry)
                let children = (try? fileManager.contentsOfDirectory(atPath: containerPath)) ?? []
                return children.prefix(16).compactMap { child in
                    guard child.hasSuffix(".app") else { return nil }
                    return (containerPath as NSString).appendingPathComponent(child)
                }
            }
        } else {
            bundlePaths = rootEntries.prefix(2_048).compactMap { entry in
                guard entry.hasSuffix(".app") else { return nil }
                return (rootPath as NSString).appendingPathComponent(entry)
            }
        }

        return bundlePaths.compactMap { bundlePath in
            let infoPath = (bundlePath as NSString).appendingPathComponent("Info.plist")
            let infoSize = (try? fileManager.attributesOfItem(atPath: infoPath)[.size] as? NSNumber)?
                .int64Value ?? 0
            guard infoSize > 0, infoSize <= 2 * 1_024 * 1_024 else { return nil }
            guard let plistData = try? Data(contentsOf: URL(fileURLWithPath: infoPath)) else {
                return nil
            }
            return ApplicationBundleMetadataReader.metadata(
                from: plistData,
                localizedInfo: Bundle(path: bundlePath)?.localizedInfoDictionary
            )
        }
    }

    // MARK: LaunchServices store snapshot
    //
    // On iOS 27.2+ the container identifier xattr and the root-owned metadata
    // plist are no longer readable, and MCM cannot always pair a path with its
    // bundle id. lsd's CSStore keeps that pairing and lives in an Internal
    // Daemon container, so read it there first. The parser is a Swift port of
    // WQ Files' WQLaunchServices.m (GPL-3.0-or-later); see NOTICE.md.

    private struct LaunchServicesStoreCandidate {
        let url: URL
        let parentPath: String
        let modifiedAt: Date
        let size: Int
    }

    private static let launchServicesSnapshotLock = NSLock()
    private static let launchServicesCatalogLock = NSLock()
    private static var launchServicesSnapshotCache: (signature: String, snapshot: LaunchServicesSnapshot?)?
    private static var launchServicesActiveCandidate: LaunchServicesStoreCandidate?
    private static var launchServicesSnapshotMissAt: Date?
    private static let launchServicesSnapshotMissRetry: TimeInterval = 60 * 60

    private static let launchServicesStorePathKey = "browser.launchServicesStorePath"
    private static let launchServicesStoreMissKey = "browser.launchServicesStoreMissedAt"
    private static let launchServicesStoreMissRetry: TimeInterval = 24 * 60 * 60

    /// Drops the in-memory snapshot and the "store not found" backoff. Call
    /// when the user explicitly refreshes a screen.
    static func refreshLaunchServicesSnapshot() {
        launchServicesSnapshotLock.lock()
        launchServicesSnapshotCache = nil
        launchServicesActiveCandidate = nil
        launchServicesSnapshotMissAt = nil
        launchServicesSnapshotLock.unlock()

        launchServicesCatalogLock.lock()
        ContainerCatalogCache.clear()
        UserDefaults.standard.removeObject(forKey: launchServicesStorePathKey)
        UserDefaults.standard.removeObject(forKey: launchServicesStoreMissKey)
        launchServicesCatalogLock.unlock()

        filesystemContainerCacheLock.lock()
        filesystemContainerCache = nil
        filesystemContainerCacheLock.unlock()
    }

    static func launchServicesSnapshot() -> LaunchServicesSnapshot? {
        launchServicesSnapshotLock.lock()
        defer { launchServicesSnapshotLock.unlock() }

        let now = Date()
        if launchServicesSnapshotCache == nil,
           let missAt = launchServicesSnapshotMissAt,
           now.timeIntervalSince(missAt) < launchServicesSnapshotMissRetry {
            return nil
        }
        if launchServicesSnapshotCache == nil,
           let missedAt = UserDefaults.standard.object(forKey: launchServicesStoreMissKey) as? Date,
           now.timeIntervalSince(missedAt) < launchServicesStoreMissRetry {
            return nil
        }

        let candidates = launchServicesStoreCandidates()
        guard let newest = candidates.max(by: { left, right in
            if left.modifiedAt != right.modifiedAt {
                return left.modifiedAt < right.modifiedAt
            }
            return left.size < right.size
        }) else {
            launchServicesSnapshotCache = nil
            launchServicesActiveCandidate = nil
            launchServicesSnapshotMissAt = now
            log("browser: LaunchServices store not found")
            return nil
        }
        launchServicesActiveCandidate = newest

        let signature = "\(newest.url.path)|\(newest.size)|\(newest.modifiedAt.timeIntervalSince1970)"
        if let cached = launchServicesSnapshotCache, cached.signature == signature {
            return cached.snapshot
        }

        let handle = requiresSandboxGrant ? grantContainerAccess(newest.parentPath) : -1
        defer {
            if handle >= 0 { SandboxAccess.release(handle) }
        }
        guard let data = try? Data(contentsOf: newest.url, options: .mappedIfSafe),
              data.count <= LaunchServicesStore.maximumStoreBytes else {
            log("browser: LaunchServices store read failed \(newest.url.lastPathComponent)")
            launchServicesSnapshotCache = (signature, nil)
            return nil
        }
        guard let snapshot = LaunchServicesStore.parse(data) else {
            log("browser: LaunchServices store parse failed \(newest.url.lastPathComponent) bytes=\(data.count)")
            launchServicesSnapshotCache = (signature, nil)
            return nil
        }

        launchServicesSnapshotCache = (signature, snapshot)
        launchServicesSnapshotMissAt = nil
        log("browser: LaunchServices layout=\(snapshot.layoutLabel) containers=\(snapshot.mappedContainerCount) names=\(snapshot.decodedNameCount) bytes=\(data.count)")
        return snapshot
    }

    private static func activeLaunchServicesStoreCandidate() -> LaunchServicesStoreCandidate? {
        launchServicesSnapshotLock.lock()
        defer { launchServicesSnapshotLock.unlock() }
        return launchServicesActiveCandidate
    }

    private static func rememberedLaunchServicesStoreCandidate() -> LaunchServicesStoreCandidate? {
        guard let path = UserDefaults.standard.string(forKey: launchServicesStorePathKey) else {
            return nil
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let sizeNumber = attributes[.size] as? NSNumber,
              sizeNumber.intValue >= LaunchServicesStore.minimumStoreBytes,
              sizeNumber.intValue <= LaunchServicesStore.maximumStoreBytes,
              let modifiedAt = attributes[.modificationDate] as? Date,
              let headerHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            UserDefaults.standard.removeObject(forKey: launchServicesStorePathKey)
            return nil
        }
        let magic = (try? headerHandle.read(upToCount: 4)) ?? Data()
        try? headerHandle.close()
        guard magic == Data([0x62, 0x64, 0x73, 0x6c]) else {
            UserDefaults.standard.removeObject(forKey: launchServicesStorePathKey)
            return nil
        }
        return LaunchServicesStoreCandidate(
            url: URL(fileURLWithPath: path),
            parentPath: (path as NSString).deletingLastPathComponent,
            modifiedAt: modifiedAt,
            size: sizeNumber.intValue
        )
    }

    private static func launchServicesStoreCandidates() -> [LaunchServicesStoreCandidate] {
        if let remembered = rememberedLaunchServicesStoreCandidate() {
            return [remembered]
        }
        if let missedAt = UserDefaults.standard.object(forKey: launchServicesStoreMissKey) as? Date,
           Date().timeIntervalSince(missedAt) < launchServicesStoreMissRetry {
            return []
        }

        var candidates: [LaunchServicesStoreCandidate] = []
        var visited = Set<String>()

        // lsd's store lives under the Internal Daemon containers on iOS 27.
        // System containers and the legacy locations remain as fallbacks.
        // Container inspection runs concurrently: each probe is an
        // independent stat/read sequence and a device can carry dozens of
        // daemon containers, so the serial walk was a measurable chunk of
        // the cold scan.
        let inspectLock = NSLock()
        func inspectDirectoryConcurrent(_ rawPath: String) {
            let directory = canonicalLookupPath(rawPath)
            inspectLock.lock()
            guard visited.insert(directory).inserted else {
                inspectLock.unlock()
                return
            }
            inspectLock.unlock()

            // A root traversal grant is enough to enumerate the daemon
            // container; the per-container Caches path may need its own.
            let handle = requiresSandboxGrant ? grantContainerAccess(directory) : -1
            defer {
                if handle >= 0 { SandboxAccess.release(handle) }
            }

            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            for name in names where name.hasPrefix("com.apple.LaunchServices-")
                && name.hasSuffix(".csstore") {
                let path = (directory as NSString).appendingPathComponent(name)
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                      let sizeNumber = attributes[.size] as? NSNumber,
                      sizeNumber.intValue >= LaunchServicesStore.minimumStoreBytes,
                      sizeNumber.intValue <= LaunchServicesStore.maximumStoreBytes,
                      let modifiedAt = attributes[.modificationDate] as? Date else {
                    continue
                }
                guard let headerHandle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
                    continue
                }
                let magic = (try? headerHandle.read(upToCount: 4)) ?? Data()
                try? headerHandle.close()
                guard magic == Data([0x62, 0x64, 0x73, 0x6c]) else { continue }
                inspectLock.lock()
                candidates.append(LaunchServicesStoreCandidate(
                    url: URL(fileURLWithPath: path),
                    parentPath: directory,
                    modifiedAt: modifiedAt,
                    size: sizeNumber.intValue
                ))
                inspectLock.unlock()
            }
        }

        let daemonRoots = [
            "/var/mobile/Containers/Data/InternalDaemon",
            systemDataRoot,
        ]
        for root in daemonRoots {
            var containers = enumerateDirectoriesWithTraversalGrant(path: root)
            if containers.isEmpty {
                containers = enumerateDirectories(path: root)
            }
            let cachePaths = containers.map {
                ($0 as NSString).appendingPathComponent("Library/Caches")
            }
            DispatchQueue.concurrentPerform(iterations: cachePaths.count) { index in
                inspectDirectoryConcurrent(cachePaths[index])
            }
        }
        inspectDirectoryConcurrent("/var/db/lsd")
        inspectDirectoryConcurrent("/var/mobile/Library/Caches")

        if let best = candidates.max(by: { left, right in
            if left.modifiedAt != right.modifiedAt {
                return left.modifiedAt < right.modifiedAt
            }
            return left.size < right.size
        }) {
            UserDefaults.standard.set(best.url.path, forKey: launchServicesStorePathKey)
            UserDefaults.standard.removeObject(forKey: launchServicesStoreMissKey)
        } else {
            UserDefaults.standard.set(Date(), forKey: launchServicesStoreMissKey)
        }
        return candidates
    }

    /// Cache-only lookup used for the first paint. Never searches for the store,
    /// so it cannot block the main thread on a cold start.
    static func cachedLaunchServicesCatalog() -> ContainerCatalogSnapshot? {
        // Deliberately lock-free: this runs on the first paint and must never
        // wait for a background catalog rebuild. The cache file is written
        // atomically, and a missing/mid-write file simply returns nil.
        let started = CFAbsoluteTimeGetCurrent()
        guard let newest = rememberedLaunchServicesStoreCandidate() else { return nil }
        let signature = "\(newest.url.path)|\(newest.size)|\(newest.modifiedAt.timeIntervalSince1970)|\(AppInfo.osBuild)"
        let snapshot = ContainerCatalogCache.load(signature: signature)
        if let snapshot {
            log(
                "browser: catalog cache load entries=\(snapshot.entries.count) " +
                    "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - started))s"
            )
        }
        return snapshot
    }

    /// The instant path for App Data and the cleaner: build the list straight
    /// from lsd's database and reuse a compact on-disk catalog when the store
    /// has not changed. No filesystem enumeration is performed here.
    static func launchServicesCatalog() -> ContainerCatalogSnapshot? {
        launchServicesCatalogLock.lock()
        defer { launchServicesCatalogLock.unlock() }
        let started = CFAbsoluteTimeGetCurrent()

        // Fast path: a remembered store plus a matching compact cache needs
        // neither a store search nor an 18 MB parse.
        if let remembered = rememberedLaunchServicesStoreCandidate() {
            let signature = "\(remembered.url.path)|\(remembered.size)|\(remembered.modifiedAt.timeIntervalSince1970)|\(AppInfo.osBuild)"
            if let cached = ContainerCatalogCache.load(signature: signature) {
                log(
                    "browser: catalog cache hit entries=\(cached.entries.count) " +
                        "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - started))s"
                )
                return cached
            }
        }

        guard let snapshot = launchServicesSnapshot() else {
            log("browser: catalog unavailable — LaunchServices store not found")
            return nil
        }
        guard let newest = activeLaunchServicesStoreCandidate() else {
            log("browser: catalog unavailable — no active LaunchServices store")
            return nil
        }

        let signature = "\(newest.url.path)|\(newest.size)|\(newest.modifiedAt.timeIntervalSince1970)|\(AppInfo.osBuild)"
        if let cached = ContainerCatalogCache.load(signature: signature) {
            log(
                "browser: catalog cache hit entries=\(cached.entries.count) " +
                    "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - started))s"
            )
            return cached
        }

        let catalog = ContainerCatalogBuilder.build(
            from: snapshot,
            signature: signature,
            osBuild: AppInfo.osBuild
        )
        guard !catalog.entries.isEmpty else {
            log("browser: catalog empty — database mapped no app containers")
            return nil
        }
        do {
            try ContainerCatalogCache.save(catalog)
            log(
                "browser: catalog built entries=\(catalog.entries.count) " +
                    "elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - started))s"
            )
        } catch {
            log("browser: catalog cache write failed error=\(error.localizedDescription)")
        }
        return catalog
    }

    /// App Data rows straight from the LaunchServices catalog. Version and
    /// icon are filled in later by the API/MCM passes.
    static func installedAppsFromCatalog(
        _ catalog: ContainerCatalogSnapshot? = nil,
        includeExtensions: Bool = false
    ) -> [InstalledApp] {
        guard let catalog = catalog ?? launchServicesCatalog() else { return [] }
        return apps(from: catalog, includeExtensions: includeExtensions)
    }

    static func installedAppsFromCachedCatalog(
        includeExtensions: Bool = false
    ) -> [InstalledApp] {
        guard let catalog = cachedLaunchServicesCatalog() else { return [] }
        return apps(from: catalog, includeExtensions: includeExtensions)
    }

    private static func apps(
        from catalog: ContainerCatalogSnapshot,
        includeExtensions: Bool
    ) -> [InstalledApp] {
        catalog.entries.compactMap { entry in
            if !includeExtensions, entry.kind != .application { return nil }
            return InstalledApp(
                bundleID: entry.bundleID,
                name: entry.displayName,
                containerPath: entry.containerPath,
                version: "",
                icon: nil
            )
        }
    }

    static func launchServicesStoreIdentifiers() -> [String] {
        var identifiers: [String] = []
        var seenIdentifiers = Set<String>()
        if let snapshot = launchServicesSnapshot(), !snapshot.containerBundleIDs.isEmpty {
            for bundleID in snapshot.containerBundleIDs.values where seenIdentifiers.insert(bundleID).inserted {
                guard ContainerBundleCandidateResolver.isValidBundleIdentifier(bundleID),
                      !bundleID.hasPrefix("group."),
                      !bundleID.hasPrefix("systemgroup.") else {
                    continue
                }
                identifiers.append(bundleID)
            }
            // The snapshot already gives us the path->id mapping. Re-reading
            // the same 18 MB store here cost several seconds on every tab
            // switch; only fall back to the raw store scan if the snapshot
            // produced nothing.
            if !identifiers.isEmpty {
                log(
                    "browser: LaunchServices identifiers=\(identifiers.count) " +
                        "layout=\(snapshot.layoutLabel) (snapshot)"
                )
                return identifiers
            }
        }

        var cachePaths: [String] = []
        var seenCachePaths = Set<String>()

        func addCachePath(_ rawPath: String) {
            let path = ContainerDiscoveryMerger.canonicalPath(rawPath)
            guard !path.isEmpty, seenCachePaths.insert(path).inserted else { return }
            cachePaths.append(path)
        }

        var leasedCachePaths = Set<String>()
        var serviceLookupError: NSString?
        if let servicePath = MCMActivateContainerPath(
            10,
            "com.apple.lsd",
            false,
            &serviceLookupError
        ) {
            let cachePath = (servicePath as NSString).appendingPathComponent("Library/Caches")
            addCachePath(cachePath)
            leasedCachePaths.insert(ContainerDiscoveryMerger.canonicalPath(cachePath))
        } else if requiresSandboxGrant {
            let detail = serviceLookupError.map { String($0) } ?? "no path"
            log("browser: MCM com.apple.lsd activation unavailable detail=\(detail)")
        }

        let traversedSystemDirectories = enumerateDirectoriesWithTraversalGrant(path: systemDataRoot)
        let systemDirectories = traversedSystemDirectories.isEmpty
            ? enumerateDirectories(path: systemDataRoot)
            : traversedSystemDirectories
        for directory in systemDirectories {
            // Attempt the raw metadata read even without a traversal grant:
            // it succeeds when the sandbox escape is active, which is the
            // only path left when MCM/bad_query grants are denied.
            guard readContainerMetadata(containerPath: directory)?.bundleID == "com.apple.lsd" else {
                continue
            }
            addCachePath((directory as NSString).appendingPathComponent("Library/Caches"))
        }

        // Older and Simulator layouts keep the same store outside the MCM
        // service-container layout. They are harmless fallbacks on device.
        addCachePath("/var/db/lsd")
        addCachePath("/var/mobile/Library/Caches")

        let maximumCandidateCount = 65_536

        for cachePath in cachePaths where identifiers.count < maximumCandidateCount {
            let hasLease = leasedCachePaths.contains(
                ContainerDiscoveryMerger.canonicalPath(cachePath)
            )
            let handle: Int64
            if hasLease || !requiresSandboxGrant {
                handle = -1
            } else {
                handle = grantContainerAccess(cachePath)
                if handle < 0 {
                    log("browser: LaunchServices traversal grant failed \(cachePath) -> \(handle)")
                    continue
                }
            }
            defer {
                if handle >= 0 { SandboxAccess.release(handle) }
            }

            let names = (try? FileManager.default.contentsOfDirectory(atPath: cachePath)) ?? []
            for name in names where identifiers.count < maximumCandidateCount {
                guard name.hasPrefix("com.apple.LaunchServices-"),
                      name.hasSuffix("-v2.csstore") else {
                    continue
                }
                let storePath = (cachePath as NSString).appendingPathComponent(name)
                guard let size = (try? FileManager.default.attributesOfItem(atPath: storePath)[.size]) as? NSNumber,
                      size.uint64Value > 0,
                      size.uint64Value <= 64 * 1_024 * 1_024,
                      let data = try? Data(contentsOf: URL(fileURLWithPath: storePath), options: .mappedIfSafe) else {
                    continue
                }
                let remaining = maximumCandidateCount - identifiers.count
                let extracted = LaunchServicesCandidateExtractor.identifiers(from: data, limit: remaining)
                for identifier in extracted where seenIdentifiers.insert(identifier).inserted {
                    identifiers.append(identifier)
                }
                log("browser: LaunchServices store \(name) bytes=\(data.count) candidates=\(identifiers.count)")
            }
        }

        log("browser: LaunchServices store total candidates=\(identifiers.count)")
        return identifiers
    }

    /// Canonical form used by the container-manager identifier map, which
    /// spells the /var alias as /private/var.
    static func canonicalLookupPath(_ path: String) -> String {
        let clean = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        if clean == "/var" || clean.hasPrefix("/var/") {
            return "/private" + clean
        }
        return clean
    }

    static func isApplicationContainerPath(_ path: String) -> Bool {
        let canonicalRoot = ContainerDiscoveryMerger.canonicalPath(appDataRoot)
        let canonicalPath = ContainerDiscoveryMerger.canonicalPath(path)
        guard canonicalPath.hasPrefix(canonicalRoot + "/") else { return false }
        return UUID(uuidString: (canonicalPath as NSString).lastPathComponent) != nil
    }

    // MARK: Filesystem discovery

    static func enumerateDirectories(
        path: String,
        maxInode: Int64 = 2_000_000,
        token: ScanToken? = nil,
        progress: ((Int64, Int64) -> Void)? = nil
    ) -> [String] {
        let clean = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard clean.hasPrefix("/") else { return [] }
        if token?.isCancelled == true { return [] }

        if let names = try? FileManager.default.contentsOfDirectory(atPath: clean), !names.isEmpty {
            return names.map { (clean as NSString).appendingPathComponent($0) }
        }

        // faster fallback: fsgetpath inode enumeration with cancellation.
        // The dynamic baseline probes the live allocation watermark first so
        // the sweep stops near the real top inode instead of walking all
        // 2,000,000 slots.
        let wantsPrivatePrefix = clean.hasPrefix("/private/")
        let dynamicCeiling = Pathleak.dynamicMaxInode(directory: clean, ceiling: UInt64(max(1, maxInode)), token: token)
        let leaked = Pathleak.list(
            directory: clean,
            maxInode: dynamicCeiling,
            token: token,
            progress: progress
        )
        if !leaked.isEmpty {
            log("enumerate: pathleak for \(clean) -> \(leaked.count) entries")
            return wantsPrivatePrefix ? leaked.map { "/private" + $0 } : leaked
        }
        if token?.isCancelled == true { return [] }

        var pathC = clean.utf8CString.map { Int8($0) }
        guard let result = bad_query_list(&pathC, maxInode) else {
            log("enumerate: NULL for \(clean)")
            return []
        }
        defer { free(result) }
        let list = String(cString: result).components(separatedBy: "\n").filter { !$0.isEmpty }
        if !list.isEmpty {
            log("enumerate: inode fallback for \(clean) -> \(list.count) entries")
        } else {
            log("enumerate: FileManager+inode unavailable for \(clean)")
        }
        progress?(Int64(max(1, maxInode)), Int64(max(1, maxInode)))
        return list
    }

    static func enumerateDirectoriesWithTraversalGrant(
        path: String,
        token: ScanToken? = nil,
        progress: ((Int64, Int64) -> Void)? = nil
    ) -> [String] {
        if !requiresSandboxGrant {
            if let names = try? FileManager.default.contentsOfDirectory(atPath: path), !names.isEmpty {
                return names.map { (path as NSString).appendingPathComponent($0) }
            }
            return enumerateDirectories(path: path, token: token, progress: progress)
        }

        let handle = grantContainerAccess(path)
        if handle >= 0 {
            defer { SandboxAccess.release(handle) }
            if let names = try? FileManager.default.contentsOfDirectory(atPath: path), !names.isEmpty {
                return names.map { (path as NSString).appendingPathComponent($0) }
            }
        } else {
            log("browser: root traversal grant failed \(path) -> \(handle)")
        }

        return enumerateDirectories(path: path, token: token, progress: progress)
    }

    static func readContainerMetadata(containerPath: String) -> ContainerMetadata? {
        let metadataPath = metadataPath(for: containerPath)

        var data: Data?
        if let fd = fopen(metadataPath, "r") {
            var buffer = [UInt8](repeating: 0, count: 65536)
            var bytes: [UInt8] = []
            while true {
                let n = fread(&buffer, 1, buffer.count, fd)
                if n <= 0 { break }
                bytes.append(contentsOf: buffer[0..<n])
            }
            fclose(fd)
            if !bytes.isEmpty { data = Data(bytes) }
        }
        if data == nil { data = try? Data(contentsOf: URL(fileURLWithPath: metadataPath)) }

        guard let validData = data,
              let plist = try? PropertyListSerialization.propertyList(from: validData, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        let bundleID = plist["MCMMetadataIdentifier"] as? String ?? ""
        var displayName = ""
        if let info = plist["MCMMetadataInfo"] as? [String: Any] {
            displayName = (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? ""
        }
        return ContainerMetadata(bundleID: bundleID, displayName: displayName)
    }

    static func metadataPath(for containerPath: String) -> String {
        (containerPath as NSString).appendingPathComponent(
            ".com.apple.mobile_container_manager.metadata.plist"
        )
    }

    static func grantContainerAccess(_ containerPath: String) -> Int64 {
        guard requiresSandboxGrant else { return -1 }
        return SandboxAccess.grant(path: containerPath)
    }

    private static let filesystemContainerCacheLock = NSLock()
    private static var filesystemContainerCache: (timestamp: Date, apps: [InstalledApp])?
    private static let filesystemContainerCacheTTL: TimeInterval = 10

    /// The Files tab and the Cleaner both need the same app list. Without a
    /// short cache, switching tabs re-runs the 6-13 second inode scan twice.
    static func containersFromFilesystem(
        refresh: Bool = false,
        token: ScanToken? = nil,
        progress: ((Int64, Int64) -> Void)? = nil
    ) -> [InstalledApp] {
        filesystemContainerCacheLock.lock()
        if !refresh,
           let cache = filesystemContainerCache,
           Date().timeIntervalSince(cache.timestamp) < filesystemContainerCacheTTL {
            let apps = cache.apps
            filesystemContainerCacheLock.unlock()
            log("browser: filesystem cache hit \(apps.count) containers")
            return apps
        }
        filesystemContainerCacheLock.unlock()

        let apps = discoverFilesystemContainers(token: token, progress: progress)
        if token?.isCancelled == true { return apps }
        filesystemContainerCacheLock.lock()
        filesystemContainerCache = (Date(), apps)
        filesystemContainerCacheLock.unlock()
        return apps
    }

    private static func discoverFilesystemContainers(
        token: ScanToken? = nil,
        progress: ((Int64, Int64) -> Void)? = nil
    ) -> [InstalledApp] {
        let grantedDirectories = enumerateDirectoriesWithTraversalGrant(
            path: appDataRoot,
            token: token,
            progress: progress
        )
        var dirs: [String]
        if grantedDirectories.isEmpty {
            dirs = enumerateDirectories(path: appDataRoot, token: token, progress: progress)
            log("browser: filesystem root=\(appDataRoot) inode fallback enumerated \(dirs.count) containers")
        } else {
            dirs = grantedDirectories
            log("browser: filesystem root=\(appDataRoot) traversal enumerated \(dirs.count) containers")
        }
        if token?.isCancelled == true { return [] }

        let snapshot = launchServicesSnapshot()
        if let snapshot {
            let root = canonicalLookupPath(appDataRoot)
            var seen = Set(dirs.map { canonicalLookupPath($0) })
            var added = 0
            for path in snapshot.containerPaths where path.hasPrefix(root + "/") {
                let canonical = canonicalLookupPath(path)
                guard seen.insert(canonical).inserted,
                      FileManager.default.fileExists(atPath: path) else {
                    continue
                }
                dirs.append(path)
                added += 1
            }
            if added > 0 {
                log("browser: LaunchServices added \(added) containers missed by the scan")
            }
        }

        // Warm containermanager path↔identifier index once (critical on iOS 26.7+/27.x
        // where the metadata plist and identifier xattr are unreadable).
        let pathIDIndex: NSDictionary
        if SandboxAccess.backend == .worseQuery {
            pathIDIndex = worse_query_path_identifiers() as NSDictionary
        } else {
            pathIDIndex = [:]
        }
        let apps = dirs.compactMap { dir -> InstalledApp? in
            let uuid = (dir as NSString).lastPathComponent
            guard UUID(uuidString: uuid) != nil else { return nil }
            if let bundleID = snapshot?.bundleID(forContainerPath: dir),
               ContainerBundleCandidateResolver.isValidBundleIdentifier(bundleID),
               !bundleID.hasPrefix("systemgroup.") {
                return InstalledApp(
                    bundleID: bundleID,
                    name: snapshot?.displayName(forBundleID: bundleID) ?? "",
                    containerPath: dir,
                    version: "",
                    icon: nil
                )
            }
            // iOS 27.2+: resolve UUID container → bundle id via containermanager
            // before falling back to a UUID placeholder (which breaks patch inject).
            let canonical = canonicalLookupPath(dir)
            let mappedRaw = (pathIDIndex[canonical] as? String) ?? (pathIDIndex[dir] as? String)
            if let mappedID = mappedRaw,
               ContainerBundleCandidateResolver.isValidBundleIdentifier(mappedID),
               !mappedID.hasPrefix("systemgroup.") {
                return InstalledApp(
                    bundleID: mappedID,
                    name: snapshot?.displayName(forBundleID: mappedID) ?? "",
                    containerPath: dir,
                    version: "",
                    icon: nil
                )
            }
            let fallback = ContainerIdentityResolver.fallbackIdentity(containerPath: dir)
            return InstalledApp(
                bundleID: fallback.bundleID,
                name: fallback.displayName,
                containerPath: dir,
                version: "",
                icon: nil
            )
        }
        log("browser: filesystem accepted \(apps.count)/\(dirs.count) app containers")
        return apps
    }

    static func inferredApp(
        for fallback: InstalledApp,
        knownAppsByBundleID: [String: InstalledApp],
        launchServicesIdentifiers: Set<String>
    ) -> InstalledApp? {
        guard UUID(uuidString: fallback.bundleID) != nil else { return fallback }

        // LaunchServices is the strongest source on iOS 27.2+: it pairs the
        // container path with its bundle id directly, without MCM, the
        // identifier xattr, or the root-owned metadata plist.
        if let snapshot = launchServicesSnapshot(),
           let mappedID = snapshot.bundleID(forContainerPath: fallback.containerPath),
           ContainerBundleCandidateResolver.isValidBundleIdentifier(mappedID),
           !mappedID.hasPrefix("systemgroup.") {
            let info = appInfoForBundleID(mappedID) as? [String: Any] ?? [:]
            return InstalledApp(
                bundleID: mappedID,
                name: AppDisplayNamePolicy.resolve(
                    bundleID: mappedID,
                    candidates: [snapshot.displayName(forBundleID: mappedID), info["name"] as? String]
                ),
                containerPath: fallback.containerPath,
                version: info["version"] as? String ?? "",
                icon: info["icon"] as? UIImage
            )
        }

        // iOS 27.2: path → identifier from containermanager is the most
        // reliable source once the xattr and metadata plist are unavailable.
        if let mappedID = worse_query_path_identifiers()[canonicalLookupPath(fallback.containerPath)],
           ContainerBundleCandidateResolver.isValidBundleIdentifier(mappedID),
           !mappedID.hasPrefix("systemgroup.") {
            let info = appInfoForBundleID(mappedID) as? [String: Any] ?? [:]
            return InstalledApp(
                bundleID: mappedID,
                name: AppDisplayNamePolicy.resolve(
                    bundleID: mappedID,
                    candidates: [info["name"] as? String ?? ""]
                ),
                containerPath: fallback.containerPath,
                version: info["version"] as? String ?? "",
                icon: info["icon"] as? UIImage
            )
        }

        // Read the MCM metadata plist directly. With the sandbox escape
        // active the raw read succeeds even when every MCM/bad_query grant
        // is denied; without it the read simply fails and we fall through.
        if let metadata = readContainerMetadata(containerPath: fallback.containerPath) {
            let bundleID = metadata.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            if ContainerBundleCandidateResolver.isValidBundleIdentifier(bundleID),
               !bundleID.hasPrefix("systemgroup.") {
                let info = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]
                let resolvedName = metadata.displayName.isEmpty
                    ? (info["name"] as? String ?? bundleID)
                    : metadata.displayName
                return InstalledApp(
                    bundleID: bundleID,
                    name: resolvedName,
                    containerPath: fallback.containerPath,
                    version: info["version"] as? String ?? "",
                    icon: info["icon"] as? UIImage
                )
            }
        }

        let handle = grantContainerAccess(fallback.containerPath)
        defer {
            if handle >= 0 { SandboxAccess.release(handle) }
        }

        let libraryPath = (fallback.containerPath as NSString).appendingPathComponent("Library")
        let savedStatePath = (libraryPath as NSString).appendingPathComponent("Saved Application State")
        let preferencesPath = (libraryPath as NSString).appendingPathComponent("Preferences")
        let savedStates = (try? FileManager.default.contentsOfDirectory(atPath: savedStatePath)) ?? []
        let preferences = (try? FileManager.default.contentsOfDirectory(atPath: preferencesPath)) ?? []
        let strongCandidates = ContainerBundleCandidateResolver.candidates(
            savedStateNames: savedStates,
            preferenceFileNames: []
        )
        let candidates = ContainerBundleCandidateResolver.candidates(
            savedStateNames: savedStates,
            preferenceFileNames: preferences
        )

        func resolvedApp(from candidates: [String], source: String) -> InstalledApp? {
            for bundleID in candidates {
                if let known = knownAppsByBundleID[bundleID] {
                    return InstalledApp(
                        bundleID: bundleID,
                        name: known.name,
                        containerPath: fallback.containerPath,
                        version: known.version,
                        icon: known.icon
                    )
                }

                let info = appInfoForBundleID(bundleID) as? [String: Any] ?? [:]
                guard info["found"] as? Bool == true else { continue }
                return InstalledApp(
                    bundleID: bundleID,
                    name: info["name"] as? String ?? bundleID,
                    containerPath: fallback.containerPath,
                    version: info["version"] as? String ?? "",
                    icon: info["icon"] as? UIImage
                )
            }

            guard let bundleID = ContainerBundleCandidateResolver.confirmedCandidate(
                candidates: candidates,
                launchServicesIdentifiers: launchServicesIdentifiers
            ) else {
                return nil
            }
            let uuid = (fallback.containerPath as NSString).lastPathComponent
            log("browser: content+LaunchServices confirmed \(uuid) -> \(bundleID) source=\(source)")
            return InstalledApp(
                bundleID: bundleID,
                name: bundleID,
                containerPath: fallback.containerPath,
                version: "",
                icon: nil
            )
        }

        if let app = resolvedApp(from: candidates, source: "state/preferences") {
            return app
        }
        if let bundleID = strongCandidates.first {
            return InstalledApp(
                bundleID: bundleID,
                name: bundleID,
                containerPath: fallback.containerPath,
                version: "",
                icon: nil
            )
        }

        let artifactPaths = [
            (libraryPath as NSString).appendingPathComponent("SplashBoard/Snapshots"),
            (libraryPath as NSString).appendingPathComponent("Caches/Snapshots"),
            (libraryPath as NSString).appendingPathComponent("Cookies"),
            (libraryPath as NSString).appendingPathComponent("WebKit")
        ]
        let artifactNames = artifactPaths.flatMap {
            (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []
        }
        let artifactCandidates = ContainerBundleCandidateResolver.candidates(
            savedStateNames: [],
            preferenceFileNames: [],
            artifactNames: artifactNames
        )
        if let app = resolvedApp(from: artifactCandidates, source: "artifacts") {
            return app
        }

        let uuid = (fallback.containerPath as NSString).lastPathComponent
        let preview = (candidates + artifactCandidates).prefix(6).joined(separator: ",")
        log("browser: unresolved \(uuid) metadata=unavailable savedStates=\(savedStates.count) preferences=\(preferences.count) artifacts=\(artifactNames.count) candidates=[\(preview)]")
        return nil
    }

    static func inferUnidentifiedApps(
        in apps: [InstalledApp],
        knownApps: [InstalledApp],
        launchServicesIdentifiers: Set<String> = []
    ) -> [InstalledApp] {
        let knownByBundleID = Dictionary(knownApps.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        var inferredCount = 0
        let result = apps.enumerated().map { index, app -> InstalledApp in
            guard UUID(uuidString: app.bundleID) != nil,
                  let inferred = autoreleasepool(invoking: {
                      inferredApp(
                        for: app,
                        knownAppsByBundleID: knownByBundleID,
                        launchServicesIdentifiers: launchServicesIdentifiers
                      )
                  }) else {
                return app
            }
            inferredCount += 1
            if inferredCount <= 5 {
                log("browser: inferred \((app.containerPath as NSString).lastPathComponent) -> \(inferred.bundleID)")
            }
            return inferred
        }
        let unresolvedCount = result.filter { UUID(uuidString: $0.bundleID) != nil }.count
        log("browser: inferred identities for \(inferredCount)/\(apps.count) merged containers; unresolved=\(unresolvedCount)")
        return result
    }

    // MARK: File browsing

    static func listFiles(at path: String) -> [FileEntry] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: path) else {
            log("listFiles: FAILED for \(path) errno=\(errno)")
            return []
        }
        var entries: [FileEntry] = []
        for item in items {
            if item.hasPrefix(".") { continue }
            let full = (path as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
            let attributes = try? fm.attributesOfItem(atPath: full)
            let size = isDir.boolValue
                ? -1
                : (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            entries.append(
                FileEntry(
                    name: item,
                    path: full,
                    isDirectory: isDir.boolValue,
                    size: size,
                    modifiedAt: attributes?[.modificationDate] as? Date
                )
            )
        }
        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func readTextFile(at path: String, limit: Int = 200_000) -> String {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return "Unable to read file."
        }
        let truncated = data.prefix(limit)
        if let text = String(data: truncated, encoding: .utf8) {
            return data.count > limit ? text + "\n… [truncated]" : text
        }
        if let text = String(data: truncated, encoding: .utf16) {
            return data.count > limit ? text + "\n… [truncated]" : text
        }
        return "Binary data (\(data.count) bytes) — not text."
    }
}
