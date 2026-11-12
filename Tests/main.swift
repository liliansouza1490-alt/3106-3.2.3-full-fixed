import Foundation

// WallpaperLabModels calls the app-global log(); the harness has no UI, so
// route the lines to stderr instead.
func log(_ msg: String) {
    fputs("[3106] \(msg)\n", stderr)
}

// Harness stubs for the sandbox-grant chain: -1 means "no grant needed" and
// release() honors that guard, so the wallpaper scanner exercises its pure
// path logic without the device-only worse_query backend.
enum ContainerStore {
    static func grantContainerAccess(_ containerPath: String) -> Int64 { -1 }
}

enum SandboxAccess {
    static func release(_ handle: Int64) {}
}

// Standalone verification for the support matrix. Run with:
//   bash Tests/run_policy_tests.sh
//
// The device-only paths (worse_query, container-manager queries) are validated
// on hardware; this harness covers the pure policy logic that decides which
// backend is selected for each iOS version.

var checks = 0
var failures = 0

func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

func expectFalse(_ condition: Bool, _ message: String) {
    expect(!condition, message)
}

// iOS 17 kernel range
expect(ExploitSupportPolicy.supportsKernelExploit(major: 17, minor: 0, patch: 0), "17.0 kernel")
expect(ExploitSupportPolicy.supportsKernelExploit(major: 17, minor: 7, patch: 9), "17.7.x kernel")
expectFalse(ExploitSupportPolicy.supportsKernelExploit(major: 17, minor: 8, patch: 0), "17.8 not kernel")
expectFalse(ExploitSupportPolicy.supportsKernelExploit(major: 16, minor: 7, patch: 0), "16.x not kernel")

// iOS 18 kernel range
expect(ExploitSupportPolicy.supportsKernelExploit(major: 18, minor: 0, patch: 0), "18.0 kernel")
expect(ExploitSupportPolicy.supportsKernelExploit(major: 18, minor: 7, patch: 1), "18.7.1 kernel")
expectFalse(ExploitSupportPolicy.supportsKernelExploit(major: 18, minor: 7, patch: 2), "18.7.2 not kernel")

// bad_query range
expect(ExploitSupportPolicy.supportsBadQuery(major: 26, minor: 0, patch: 0), "26.0 bad_query")
expect(ExploitSupportPolicy.supportsBadQuery(major: 26, minor: 6, patch: 1), "26.6.1 bad_query")
expectFalse(ExploitSupportPolicy.supportsBadQuery(major: 26, minor: 6, patch: 2), "26.6.2 not bad_query")
expectFalse(ExploitSupportPolicy.supportsBadQuery(major: 26, minor: 7, patch: 0), "26.7 not bad_query")

// worse_query range (full upstream: 26.0–26.7.2 + 27.0–27.3)
expect(ExploitSupportPolicy.supportsWorseQuery(major: 26, minor: 0, patch: 0), "26.0 worse_query")
expect(ExploitSupportPolicy.supportsWorseQuery(major: 26, minor: 6, patch: 1), "26.6.1 worse_query")
expect(ExploitSupportPolicy.supportsWorseQuery(major: 26, minor: 6, patch: 9), "26.6.9 worse_query")
expect(ExploitSupportPolicy.supportsWorseQuery(major: 26, minor: 7, patch: 0), "26.7.0 worse_query")
expect(ExploitSupportPolicy.supportsWorseQuery(major: 26, minor: 7, patch: 2), "26.7.2 worse_query")
expectFalse(ExploitSupportPolicy.supportsWorseQuery(major: 26, minor: 7, patch: 3), "26.7.3 not worse_query")
expect(ExploitSupportPolicy.supportsWorseQuery(major: 27, minor: 0, patch: 0), "27.0 worse_query")
expect(ExploitSupportPolicy.supportsWorseQuery(major: 27, minor: 2, patch: 0), "27.2 worse_query")
expect(ExploitSupportPolicy.supportsWorseQuery(major: 27, minor: 2, patch: 1), "27.2.1 worse_query")
expect(ExploitSupportPolicy.supportsWorseQuery(major: 27, minor: 3, patch: 0), "27.3 worse_query verified on hardware")
expectFalse(ExploitSupportPolicy.supportsWorseQuery(major: 28, minor: 0, patch: 0), "28.0 not worse_query")

// Experimental + overall support
expectFalse(ExploitSupportPolicy.isExperimental(major: 27, minor: 3), "27.3 is fully supported, not experimental")
expectFalse(ExploitSupportPolicy.isExperimental(major: 27, minor: 2), "27.2 not experimental")

expect(ExploitSupportPolicy.isSupported(major: 26, minor: 7, patch: 2, build: "any"), "26.7.2 supported")
expect(ExploitSupportPolicy.isSupported(major: 27, minor: 2, patch: 0, build: "any"), "27.2 supported")
expect(ExploitSupportPolicy.isSupported(major: 27, minor: 3, patch: 0, build: "any"), "27.3 experimental supported")
expectFalse(ExploitSupportPolicy.isSupported(major: 28, minor: 0, patch: 0, build: "any"), "28.0 unsupported")
expectFalse(ExploitSupportPolicy.isSupported(major: 16, minor: 7, patch: 0, build: "any"), "16.x unsupported")

// MARK: - App data browser regression checks

struct BrowserTestEntry {
    let id: String
    let path: String
}

let testUUID = "12345678-1234-1234-1234-1234567890AB"
expect(
    ContainerPresentationPolicy.classification(bundleID: testUUID) == .unidentified,
    "UUID container classified as unidentified"
)
expect(
    ContainerPresentationPolicy.classification(bundleID: "com.example.app") == .identified,
    "bundle id classified as identified"
)
expect(
    ContainerAccessPolicy.shouldRequestGrant(isRoot: true),
    "root browser requests a container grant"
)
expect(
    ContainerAccessPolicy.shouldRequestGrant(isRoot: false),
    "favorite subdirectory browser still requests a container grant"
)

let identifiedEntry = BrowserTestEntry(
    id: "com.example.app",
    path: "/private/var/mobile/Containers/Data/Application/\(testUUID)"
)
let unidentifiedEntry = BrowserTestEntry(
    id: "87654321-4321-4321-4321-BA0987654321",
    path: "/private/var/mobile/Containers/Data/Application/87654321-4321-4321-4321-BA0987654321"
)

let discoveredMerged = ContainerDiscoveryMerger.merge(
    enumerated: [unidentifiedEntry],
    identified: [identifiedEntry],
    path: { $0.path }
)
expect(discoveredMerged.count == 2, "discovery merger keeps identified and unidentified containers")

let catalogMerged = AppDataCatalogMerger.merge(
    identified: [identifiedEntry],
    fallback: [unidentifiedEntry],
    identifier: { $0.id },
    path: { $0.path }
)
expect(catalogMerged.count == 2, "catalog merger keeps unidentified fallback")

// Synthetic LaunchServices `bdsl` store: one Bundle record (0x250 layout)
// that points at a bundle id, a display name, and an app-data container.
func writeU32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
    data[offset] = UInt8(value & 0xff)
    data[offset + 1] = UInt8((value >> 8) & 0xff)
    data[offset + 2] = UInt8((value >> 16) & 0xff)
    data[offset + 3] = UInt8((value >> 24) & 0xff)
}

func writeString(_ data: inout Data, at offset: Int, id: UInt32, value: String) {
    let bytes = Array(value.utf8)
    writeU32(&data, offset, id)
    writeU32(&data, offset + 4, UInt32(bytes.count))
    data.replaceSubrange((offset + 8)..<(offset + 8 + bytes.count), with: bytes)
}

var store = Data(repeating: 0, count: 0x1000)
store.replaceSubrange(0..<4, with: Data([0x62, 0x64, 0x73, 0x6c])) // "bdsl"
store.replaceSubrange(0x200..<0x208, with: Data("<string>".utf8))

let recordOffset = 0x100
let body = recordOffset + 8
writeU32(&store, recordOffset + 4, 0x250)
writeU32(&store, body + 0x0c, 4)   // string id 1: bundle id
writeU32(&store, body + 0x6c, 8)   // string id 2: bundle name
writeU32(&store, body + 0x74, 12)  // string id 3: display name
writeU32(&store, body + 0x68, 16)  // string id 4: container path
writeU32(&store, body + 0x00, 0)   // no bundle path

writeString(&store, at: 0x300, id: 1, value: "com.example.app")
writeString(&store, at: 0x340, id: 2, value: "Example")
writeString(&store, at: 0x380, id: 3, value: "Example App")
writeString(
    &store,
    at: 0x3C0,
    id: 4,
    value: "/private/var/mobile/Containers/Data/Application/\(testUUID)"
)

let snapshot = LaunchServicesStore.parse(store)
expect(snapshot != nil, "LaunchServices parser accepts a synthetic bdsl store")
if let snapshot {
    expect(
        snapshot.containerBundleIDs.values.contains("com.example.app"),
        "LaunchServices parser maps a container to its bundle id"
    )
    expect(
        snapshot.displayName(forBundleID: "com.example.app") == "Example App",
        "LaunchServices parser decodes the display name"
    )
    expect(snapshot.containerPaths.count == 1, "LaunchServices parser reports one container")
    expect(
        snapshot.bundleID(forContainerPath: identifiedEntry.path) == "com.example.app",
        "LaunchServices snapshot lookup canonicalizes the path"
    )
}

expect(
    LaunchServicesStore.canonicalContainerPath(
        "/var/mobile/Containers/Data/Application/\(testUUID)/"
    ) == "/private/var/mobile/Containers/Data/Application/\(testUUID)",
    "container path canonicalization"
)
expect(
    LaunchServicesStore.isDataContainerPath(identifiedEntry.path),
    "app data container path is recognized"
)
expect(
    LaunchServicesStore.isPath(
        "/private/var/mobile/Containers/Data/Application/\(testUUID)/Library/Caches",
        containedIn: "/var/mobile/Containers/Data/Application/\(testUUID)"
    ),
    "path containment treats /var and /private/var as the same tree"
)
expectFalse(
    LaunchServicesStore.isPath(
        "/private/var/mobile/Containers/Data/Application/\(testUUID)X",
        containedIn: "/var/mobile/Containers/Data/Application/\(testUUID)"
    ),
    "path containment does not match a sibling prefix"
)

// URL-level containment must not depend on resolvingSymlinksInPath(): inside
// the sandbox that call can stop early and return mixed spellings for the
// same tree (issue #2), so every raw/resolved spelling pair has to pass.
do {
    let root = URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/\(testUUID)")
        .appendingPathComponent("Library/Application Support/WallpaperLab/Packages/.importing-x/Extracted", isDirectory: true)
    let child = URL(fileURLWithPath: "/private/var/mobile/Containers/Data/Application/\(testUUID)")
        .appendingPathComponent("Library/Application Support/WallpaperLab/Packages/.importing-x/Extracted/descriptors", isDirectory: true)
    expect(
        WallpaperLayoutScanner.isContained(child, in: root),
        "URL containment accepts /private/var child under /var root (issue #2 mix)"
    )
    let outside = root.deletingLastPathComponent()
        .appendingPathComponent("Other/elsewhere", isDirectory: true)
    expectFalse(
        WallpaperLayoutScanner.isContained(outside, in: root),
        "URL containment still rejects paths outside the root"
    )
}

// MARK: - Favorites store checks

let favoritesSuite = "3106.favorites.tests.\(UUID().uuidString)"
if let defaults = UserDefaults(suiteName: favoritesSuite) {
    defaults.removePersistentDomain(forName: favoritesSuite)
    let favorites = FileFavoritesStore(defaults: defaults)
    favorites.add(
        path: "/var/mobile/Containers/Data/Application/\(testUUID)/",
        name: "Test Folder"
    )
    expect(favorites.favorites.count == 1, "favorites add stores one item")
    expect(
        favorites.contains(
            path: "/private/var/mobile/Containers/Data/Application/\(testUUID)"
        ),
        "favorites normalize /var and /private/var"
    )
    expect(
        favorites.contains(
            path: "/var/mobile/Containers/Data/Application/\(testUUID)/"
        ),
        "favorites tolerate a trailing slash"
    )

    let reloadedFavorites = FileFavoritesStore(defaults: defaults)
    expect(reloadedFavorites.favorites.count == 1, "favorites persist across relaunch")

    reloadedFavorites.add(
        path: "/var/mobile/Containers/Data/Application/\(testUUID)",
        name: "Duplicate"
    )
    expect(reloadedFavorites.favorites.count == 1, "favorites dedupe the same path")

    reloadedFavorites.remove(
        path: "/var/mobile/Containers/Data/Application/\(testUUID)"
    )
    expect(reloadedFavorites.favorites.isEmpty, "favorites remove deletes the entry")
    defaults.removePersistentDomain(forName: favoritesSuite)
} else {
    expect(false, "favorites test defaults unavailable")
}

expect(
    FileFavoriteContainerRoot.containerPath(
        for: "/private/var/mobile/Containers/Data/Application/\(testUUID)/Documents"
    ) == "/private/var/mobile/Containers/Data/Application/\(testUUID)",
    "favorite container root resolves an application folder"
)
expect(
    FileFavoriteContainerRoot.containerPath(
        for: "/private/var/mobile/Containers/Shared/AppGroup/\(testUUID)/Library"
    ) == "/private/var/mobile/Containers/Shared/AppGroup/\(testUUID)",
    "favorite container root resolves an app group folder"
)
expect(
    FileFavoriteContainerRoot.containerPath(
        for: "/private/var/mobile/Library/Preferences"
    ) == nil,
    "favorite container root ignores non-container paths"
)

// MARK: - Cleaner incremental callbacks

// Shape-compatible stand-in for the real type in LimitedCleanerService.
// CleanerCatalog only needs these fields for its pure scanning loop.
struct LimitedCleanerUsage: Equatable {
    let cacheBytes: Int64
    let temporaryBytes: Int64
    let removableItemCount: Int

    var totalBytes: Int64 { cacheBytes + temporaryBytes }
}

let cleanerApplications = [
    CleanerResolvedApplication(
        bundleID: "com.example.one",
        name: "One",
        containerPath: "/private/var/mobile/Containers/Data/Application/\(testUUID)",
        version: "1.0"
    ),
    CleanerResolvedApplication(
        bundleID: "com.example.two",
        name: "Two",
        containerPath: "/private/var/mobile/Containers/Data/Application/\(testUUID)",
        version: "1.0"
    ),
    CleanerResolvedApplication(
        bundleID: "com.example.three",
        name: "Three",
        containerPath: "/private/var/mobile/Containers/Data/Application/\(testUUID)",
        version: "1.0"
    ),
]
var cleanerScanned = Set<String>()
var cleanerApplicationCallbacks: [String] = []
var cleanerRecordCallbacks: [String] = []
let cleanerRecords = CleanerCatalog.scanNewApplications(
    cleanerApplications,
    scannedBundleIDs: &cleanerScanned,
    shouldIncludeBundleID: { _ in true },
    activateContainer: { $0.containerPath },
    isValidContainerPath: { _ in true },
    usageForContainer: { _ in
        LimitedCleanerUsage(cacheBytes: 10, temporaryBytes: 2, removableItemCount: 1)
    },
    onApplication: { cleanerApplicationCallbacks.append($0) },
    onRecord: { cleanerRecordCallbacks.append($0.bundleID) }
)
expect(cleanerApplicationCallbacks.count == 3, "cleaner reports every examined app")
expect(cleanerRecordCallbacks.count == 3, "cleaner reports every app with removable data")
expect(cleanerRecords.count == 3, "cleaner returns every record")

var cleanerEmptyScanned = Set<String>()
var cleanerEmptyApplications: [String] = []
let cleanerEmptyRecords = CleanerCatalog.scanNewApplications(
    [cleanerApplications[0]],
    scannedBundleIDs: &cleanerEmptyScanned,
    shouldIncludeBundleID: { _ in true },
    activateContainer: { $0.containerPath },
    isValidContainerPath: { _ in true },
    usageForContainer: { _ in
        LimitedCleanerUsage(cacheBytes: 0, temporaryBytes: 0, removableItemCount: 0)
    },
    onApplication: { cleanerEmptyApplications.append($0) },
    onRecord: { _ in }
)
expect(cleanerEmptyApplications.count == 1, "cleaner still reports an app with no removable data")
expect(cleanerEmptyRecords.isEmpty, "cleaner does not return an empty record")
expect(cleanerEmptyScanned.isEmpty, "cleaner does not mark an empty app as scanned")

// LaunchServices fast container catalog: build, filter and disk cache.
do {
    let appA = "/private/var/mobile/Containers/Data/Application/11111111-1111-1111-1111-111111111111"
    let appB = "/private/var/mobile/Containers/Data/Application/22222222-2222-2222-2222-222222222222"
    let plugin = "/private/var/mobile/Containers/Data/PluginKitPlugin/33333333-3333-3333-3333-333333333333"
    let snapshot = LaunchServicesSnapshot(
        containerBundleIDs: [
            appA: "com.example.alpha",
            appB: "com.example.beta",
            plugin: "com.example.alpha.widget"
        ],
        displayNames: [
            "com.example.alpha": "Alpha",
            "com.example.beta": "Beta",
            "com.example.alpha.widget": "Alpha Widget"
        ],
        bundleNames: [:],
        containerPaths: [appA, appB, plugin, appB],
        bundlePaths: [:],
        layoutLabel: "test",
        mappedContainerCount: 3,
        decodedNameCount: 3
    )
    let catalog = ContainerCatalogBuilder.build(
        from: snapshot,
        signature: "sig-1",
        osBuild: "27.0"
    )
    expect(catalog.entries.count == 3, "catalog keeps each container once")
    expect(catalog.entries.contains { $0.bundleID == "com.example.alpha" && $0.displayName == "Alpha" },
           "catalog decodes display names")
    expect(catalog.entries.contains { $0.kind == .extensionContainer && $0.bundleID == "com.example.alpha.widget" },
           "catalog marks plugin containers")

    let catalogRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("3106-catalog-tests-\(UUID().uuidString).json")
    do {
        try ContainerCatalogCache.save(catalog, rootURL: catalogRoot)
        let loaded = ContainerCatalogCache.load(signature: "sig-1", rootURL: catalogRoot)
        expect(loaded?.entries.count == 3, "catalog cache round-trips")
        expect(ContainerCatalogCache.load(signature: "other", rootURL: catalogRoot) == nil,
               "catalog cache rejects a different store signature")
        ContainerCatalogCache.clear(rootURL: catalogRoot)
    } catch {
        expect(false, "catalog cache test failed: \(error)")
    }
}

// Backup center: originals, versions, verified writes, restore and journals.
do {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("3106-backup-tests-\(UUID().uuidString)", isDirectory: true)
    let center = BackupCenter(rootURL: root)
    let fileManager = FileManager.default
    let target = root.appendingPathComponent("target.txt")
    try Data("original".utf8).write(to: target)

    let original = try center.recordOriginalIfNeeded(target: target, feature: .file, reason: "test")
    expect(original.kind == .original, "backup records the first original")
    expect(original.sha256 == BackupCenter.hashData(Data("original".utf8)), "original hash matches")
    let originalAgain = try center.recordOriginalIfNeeded(target: target, feature: .file, reason: "again")
    expect(originalAgain.id == original.id, "original snapshot is immutable")

    let version = try center.createVersionSnapshot(target: target, feature: .file, reason: "before write")
    expect(version.kind == .version, "version snapshot is recorded")
    expect(version.sha256 == BackupCenter.hashData(Data("original".utf8)), "version holds the pre-write content")

    try VerifiedFileWriter.write(
        Data("updated".utf8),
        to: target,
        feature: .file,
        reason: "test write",
        center: center
    )
    expect((try? String(contentsOf: target, encoding: .utf8)) == "updated", "verified writer updates the file")

    try center.restore(original)
    expect((try? String(contentsOf: target, encoding: .utf8)) == "original", "restore returns the original content")

    try center.delete(version)
    expect(!center.records().contains { $0.id == version.id }, "version backup can be deleted")

    do {
        try center.delete(original)
        expect(false, "original backups cannot be deleted")
    } catch {
        expect(true, "original backups cannot be deleted")
    }

    let manual = try center.manualBackup(target: target, feature: .file, label: "manual")
    expect(manual.kind == .manual, "manual backup is recorded")

    let journalTarget = root.appendingPathComponent("journal.txt")
    try Data("before".utf8).write(to: journalTarget)
    let journalOriginal = try center.recordOriginalIfNeeded(
        target: journalTarget,
        feature: .file,
        reason: "journal"
    )
    let journalID = try center.beginJournal(
        target: journalTarget,
        feature: .file,
        backupRecordID: journalOriginal.id,
        reason: "crash simulation"
    )
    expect(center.pendingJournals().contains { $0.id == journalID }, "journal is listed as pending")
    try Data("after".utf8).write(to: journalTarget)
    let recovered = center.recoverPendingJournals()
    expect(recovered >= 1, "pending journal is recovered")
    expect((try? String(contentsOf: journalTarget, encoding: .utf8)) == "before",
           "journal recovery restores the backup")

    let symlink = root.appendingPathComponent("link.txt")
    try fileManager.createSymbolicLink(atPath: symlink.path, withDestinationPath: target.path)
    do {
        try VerifiedFileWriter.write(
            Data("x".utf8),
            to: symlink,
            feature: .file,
            reason: "symlink",
            center: center
        )
        expect(false, "verified writer refuses symlinks")
    } catch {
        expect(true, "verified writer refuses symlinks")
    }

    try? fileManager.removeItem(at: root)
} catch {
    expect(false, "backup center test failed: \(error)")
}

// Cleaner safety policy: protected-path blacklist with component prefixes.
do {
    // Core blacklist entries are always protected.
    for protected in [
        "/var/db", "/private/var/db", "/var/db/uuidtext",
        "/var/mobile/Library/Caches", "/var/mobile/Library/Safari",
        "/private/var/containers/Data/System",
        "/private/var/containers/Shared/SystemGroup",
        "/private/var/mobile/Containers/Data/InternalDaemon",
    ] {
        expect(CleanerSafetyPolicy.isProtectedSystemPath(protected), "protected: \(protected)")
    }

    // Component-prefix matching must not over-match sibling names.
    expectFalse(CleanerSafetyPolicy.isProtectedSystemPath("/var/database"),
                "sibling /var/database is not /var/db")
    expectFalse(CleanerSafetyPolicy.isProtectedSystemPath("/var/db2/x"),
                "sibling /var/db2/x is not /var/db")

    // Anything inside a protected tree is protected too.
    expect(CleanerSafetyPolicy.isProtectedSystemPath("/var/db/uuidtext/deep/file"),
           "descendant of /var/db/uuidtext is protected")

    // App containers are fair game for the cleaner.
    expectFalse(CleanerSafetyPolicy.isProtectedSystemPath(
        "/var/mobile/Containers/Data/Application/ABC123/Library/Caches"),
        "app container caches are cleanable")

    // Relative paths, "/" and traversal components are rejected outright.
    expect(CleanerSafetyPolicy.isProtectedSystemPath("relative/path"),
           "relative path treated as protected (refused)")
    expect(CleanerSafetyPolicy.isProtectedSystemPath("/"), "root refused")
    expect(CleanerSafetyPolicy.isProtectedSystemPath("/var/mobile/Containers/../db"),
           "traversal component refused")
}

// Cleaner safety policy: planned target construction.
do {
    let root = "/var/mobile/Containers/Data/Application/ABC123"
    let ok = CleanerSafetyPolicy.PlannedTarget.build(
        containerRoot: root, relativePath: "Library/Caches"
    )
    expect(ok != nil, "planned target builds for allowlist path")
    expect(ok?.absolutePath == root + "/Library/Caches", "planned target path join")

    expect(CleanerSafetyPolicy.PlannedTarget.build(
        containerRoot: root, relativePath: "../../etc") == nil,
        "traversal relative path refused")
    expect(CleanerSafetyPolicy.PlannedTarget.build(
        containerRoot: root, relativePath: "") == nil,
        "empty relative path refused")
}

// Cleaner safety policy: identity snapshots (TOCTOU protection).
do {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("3106-policy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("probe.txt")
    try Data("v1".utf8).write(to: file)

    let snapshot = CleanerSafetyPolicy.FileIdentitySnapshot.capture(atPath: file.path)
    expect(snapshot.existed, "snapshot captures existing file")
    expect(snapshot.matchesCurrentPath(file.path), "unchanged file keeps identity")

    // Rewriting via a delete+recreate cycle changes the inode.
    try FileManager.default.removeItem(at: file)
    try Data("v2".utf8).write(to: file)
    expectFalse(snapshot.matchesCurrentPath(file.path),
                "recreated file has a new identity")

    // A snapshot of a missing path refuses an appearing file.
    let ghost = CleanerSafetyPolicy.FileIdentitySnapshot.capture(
        atPath: dir.appendingPathComponent("ghost.txt").path
    )
    expectFalse(ghost.existed, "missing file snapshot")
    try Data("x".utf8).write(to: dir.appendingPathComponent("ghost.txt"))
    expectFalse(ghost.matchesCurrentPath(dir.appendingPathComponent("ghost.txt").path),
                "file that appeared after snapshot is treated as changed")

    try? FileManager.default.removeItem(at: dir)
} catch {
    expect(false, "identity snapshot test failed: \(error)")
}

// Cleaner safety policy: three-stage confirmation gate ordering.
do {
    let gate = CleanerSafetyPolicy.ConfirmationGate()

    // Authorizing without the earlier stages must fail.
    expectFalse(gate.authorize(operationID: "op-1"), "authorize before begin fails")
    expectFalse(gate.acknowledgeScope(operationID: "op-1"), "ack before begin fails")

    expect(gate.begin(operationID: "op-1"), "begin accepts first operation")
    expectFalse(gate.begin(operationID: "op-2"), "begin rejects concurrent operation")

    // Cross-operation ids are refused at every stage.
    expectFalse(gate.acknowledgeScope(operationID: "op-2"), "ack with wrong id fails")
    expect(gate.acknowledgeScope(operationID: "op-1"), "ack with right id passes")
    expectFalse(gate.authorize(operationID: "op-2"), "authorize with wrong id fails")
    expect(gate.authorize(operationID: "op-1"), "authorize in order passes")

    gate.finish(operationID: "op-1")
    expect(gate.begin(operationID: "op-2"), "gate returns to idle after finish")

    gate.cancel()
    expect(gate.begin(operationID: "op-3"), "gate returns to idle after cancel")
}

// Cleaner history: persistence round-trip and aggregates.
do {
    let historyRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("3106-history-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: historyRoot, withIntermediateDirectories: true)
    CleanerHistory.setRootForTesting(historyRoot)
    defer {
        CleanerHistory.clear()
        CleanerHistory.setRootForTesting(nil)
        try? FileManager.default.removeItem(at: historyRoot)
    }
    CleanerHistory.clear()
    let empty = CleanerHistory.loadEntries()
    expect(empty.isEmpty, "history starts empty after clear")

    CleanerHistory.record(CleanerHistoryEntry(
        cleanedAppCount: 3, failedItemCount: 0, freedBytes: 1024
    ))
    CleanerHistory.record(CleanerHistoryEntry(
        cleanedAppCount: 1, failedItemCount: 2, freedBytes: 2048,
        crashLogsRemoved: 5, crashLogBytes: 512
    ))
    let entries = CleanerHistory.loadEntries()
    expect(entries.count == 2, "history persists both entries")
    expect(entries[0].freedBytes == 2048, "history is newest-first")
    expect(entries[0].totalFreedBytes == 2048 + 512, "crash-log bytes aggregate into totals")
    expect(CleanerHistory.totalFreedBytes(in: entries) == 1024 + 2048 + 512,
           "total freed bytes sums all entries")
    expect(CleanerHistory.totalCleanedApps(in: entries) == 4,
           "total cleaned apps sums all entries")

    CleanerHistory.clear()
    expect(CleanerHistory.loadEntries().isEmpty, "clear empties history")
}

// Activity history: persistence round-trip, ordering and cap.
do {
    let activityRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("3106-activity-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: activityRoot, withIntermediateDirectories: true)
    ActivityHistory.setRootForTesting(activityRoot)
    defer {
        ActivityHistory.clear()
        ActivityHistory.setRootForTesting(nil)
        try? FileManager.default.removeItem(at: activityRoot)
    }
    ActivityHistory.clear()
    expect(ActivityHistory.load().isEmpty, "activity starts empty after clear")

    ActivityHistory.log(.backup, feature: "savebackup", "com.a")
    ActivityHistory.log(.restore, feature: "savebackup", "com.a")
    ActivityHistory.log(.clean, feature: "cleaner", "apps=3 freed=1024")
    ActivityHistory.log(.write, feature: "gestalt", "preset:aod")

    let events = ActivityHistory.load()
    expect(events.count == 4, "activity persists all four events")
    expect(events[0].kind == .write, "activity is newest-first")
    expect(events.map(\.kind) == [.write, .clean, .restore, .backup],
           "activity kinds ordered newest-first")

    // The 300-entry cap keeps the newest slice.
    for index in 0..<310 {
        ActivityHistory.log(.write, feature: "stress", "entry-\(index)")
    }
    expect(ActivityHistory.load().count == 300, "activity caps at 300 entries")

    ActivityHistory.clear()
    expect(ActivityHistory.load().isEmpty, "clear empties activity")
}

// ── v3.2.1 verification block ──────────────────────────────────────────
// Real-logic verification for this release: AltStore adapter (real
// AltGallery manifest shape), update-check version comparison, the
// open-ended-range compatibility fix, and the 27.3 / 26.5 policy flips.
// These run in the bare CLI harness — no UIKit, no sandbox grants.

// 1) AltStoreSourceAdapter: a realistic AltGallery-shaped manifest.
do {
    let manifestJSON = """
    {
      "name": "AltGallery",
      "subtitle": "aggregate",
      "iconURL": "https://raw.githubusercontent.com/bebound/AltGallery/master/icon.png",
      "apps": [
        {
          "name": "Aidoku",
          "bundleIdentifier": "app.aidoku.Aidoku",
          "developerName": "Aidoku",
          "subtitle": "Manga reader",
          "localizedDescription": "An open source manga reader.",
          "iconURL": "https://raw.githubusercontent.com/bebound/AltGallery/master/aidoku.png",
          "versions": [
            {
              "version": "0.9.1",
              "date": "2026-10-01T00:00:00Z",
              "localizedDescription": "bugfixes",
              "downloadURL": "https://github.com/Aidoku/Aidoku/releases/download/v0.9-4/Aidoku.ipa",
              "size": 14753154,
              "minOSVersion": "15.0"
            }
          ]
        },
        {
          "name": "Duplicate Bundle",
          "bundleIdentifier": "app.aidoku.Aidoku",
          "versions": [
            {"version": "0.1", "downloadURL": "https://github.com/x/x/releases/download/v1/x.ipa"}
          ]
        },
        {
          "name": "Bad Link",
          "bundleIdentifier": "com.bad.link",
          "versions": [
            {"version": "1.0", "downloadURL": "http://insecure.example.com/x.ipa"}
          ]
        }
      ]
    }
    """
    let data = Data(manifestJSON.utf8)
    let repo = try AltStoreSourceAdapter.decode(
        data,
        sourceURL: URL(string: "https://raw.githubusercontent.com/bebound/AltGallery/refs/heads/master/all-apps.json")!
    )
    expect(repo.identifier == "altgallery", "adapter: repo identifier")
    expect(repo.packages.count == 1, "adapter: duplicate bundle deduped, insecure link skipped (3 apps -> 1)")
    let pkg = repo.packages[0]
    expect(pkg.identifier == "app.aidoku.Aidoku", "adapter: bundle id becomes package identifier")
    expect(pkg.kind == .ipa, "adapter: kind is .ipa")
    expect(pkg.version == "0.9.1", "adapter: newest version picked")
    expect(pkg.expectedSize == 14_753_154, "adapter: size carried through")
    expect(pkg.supportedOS.count == 1 && pkg.supportedOS[0].maximum == "99.0.0",
           "adapter: open range expressed via sentinel maximum")
    expect(pkg.downloadURL.scheme == "https", "adapter: download URL https")

    // Compatibility: 3.2.1 device must see the package as compatible
    // (regression for the nil-maximum bug that greyed every install).
    let compatibility = PackageCompatibilityEvaluator.evaluate(
        pkg.supportedOS, major: 27, minor: 0, patch: 1, build: "any"
    )
    expect(compatibility == .compatible, "adapter: open range evaluates compatible on 27.0.1")

    // Oversized manifest refused.
    let huge = Data(repeating: 65, count: PackageRepositoryLimits.maximumManifestBytes + 1)
    var threw = false
    _ = try? AltStoreSourceAdapter.decode(huge, sourceURL: repo.sourceURL)
    do {
        _ = try AltStoreSourceAdapter.decode(huge, sourceURL: repo.sourceURL)
    } catch {
        threw = true
    }
    expect(threw, "adapter: oversized manifest refused")
}

// 2) AppUpdateChecker version comparison (3.2.1 release gate).
do {
    expect(AppVersionComparison.isNewer("v3.2.1", than: "3.2.0"), "update: v-prefixed newer tag detected")
    expectFalse(AppVersionComparison.isNewer("v3.2.1", than: "3.2.1"), "update: same version not newer")
    expectFalse(AppVersionComparison.isNewer("3.2.0", than: "3.2.1"), "update: older tag not newer")
    expect(AppVersionComparison.isNewer("3.2.10", than: "3.2.9"), "update: numeric not lexicographic (10 > 9)")
    expect(AppVersionComparison.normalize(" v3.2.1 ") == "3.2.1", "update: normalize strips v and whitespace")
    expect(AppVersionComparison.isNewer("v4", than: "3.2.1"), "update: major bump detected")
}

// 3) Support policy flips (27.3 promoted, 26.5 layouts unchanged).
do {
    expect(ExploitSupportPolicy.supportsWorseQuery(major: 27, minor: 3, patch: 0),
           "policy: 27.3 verified & supported")
    expectFalse(ExploitSupportPolicy.isExperimental(major: 27, minor: 3),
                "policy: 27.3 no longer experimental")
    expectFalse(ExploitSupportPolicy.supportsWorseQuery(major: 26, minor: 7, patch: 3),
                "policy: 26.7.3 beyond worse_query ceiling")
    expect(ExploitSupportPolicy.supportsBadQuery(major: 26, minor: 6, patch: 1),
           "policy: 26.6.1 still bad_query")
    expectFalse(ExploitSupportPolicy.supportsBadQuery(major: 26, minor: 6, patch: 2),
                "policy: 26.6.2 past bad_query")
}

// 4) Version parsing edge used by PackageSystemVersion (sentinel path).
do {
    let maxRange = PackageOSRange(minimum: "15.0", maximum: "99.0.0", builds: nil)
    expect(PackageCompatibilityEvaluator.evaluate(
        [maxRange], major: 26, minor: 5, patch: 0, build: "b"
    ) == .compatible, "compat: sentinel maximum covers 26.5")
    expect(PackageCompatibilityEvaluator.evaluate(
        [maxRange], major: 14, minor: 0, patch: 0, build: "b"
    ) == .incompatible, "compat: below minimum (14.0 < 15.0) refused")
}

if failures == 0 {
    print("PASS: \(checks) policy checks")
    exit(0)
} else {
    print("FAILED: \(failures)/\(checks) checks")
    exit(1)
}