import Foundation

/// App save backup/restore (Erosion-CN AppDataBackupView parity): package an
/// app's `Documents` + `Library/Preferences` into a zip with a manifest,
/// export it, and restore it back into the app's (possibly new) container
/// after a reinstall. Restore re-matches the container by bundle ID, runs
/// the zip path-traversal checks (safeComponents), backs up the current
/// state before overwriting, and refuses protected bundle IDs.
enum AppSaveBackupService {

    struct SaveBackupManifest: Codable, Equatable {
        let bundleID: String
        let appName: String
        let createdAt: Date
        let appVersion: String
        let includesPreferences: Bool
    }

    struct BackupEntry: Identifiable, Equatable {
        let id: UUID
        let fileURL: URL
        let manifest: SaveBackupManifest
        let sizeBytes: Int64
    }

    enum SaveBackupError: Error, Equatable, LocalizedError {
        case protectedBundle
        case containerUnavailable
        case nothingToBackUp
        case manifestMissing
        case manifestBundleMismatch
        case invalidArchive
        case restoreTargetUnavailable

        var errorDescription: String? {
            switch self {
            case .protectedBundle: return "savebackup.error.protected"
            case .containerUnavailable: return "savebackup.error.no_container"
            case .nothingToBackUp: return "savebackup.error.empty"
            case .manifestMissing: return "savebackup.error.no_manifest"
            case .manifestBundleMismatch: return "savebackup.error.bundle_mismatch"
            case .invalidArchive: return "savebackup.error.invalid"
            case .restoreTargetUnavailable: return "savebackup.error.no_target"
            }
        }
    }

    static let protectedBundleIDs: Set<String> = [
        "com.qingtang.3106",
        "com.apple.springboard",
        "com.apple.Preferences",
        "com.apple.mobilephone",
        "com.apple.PosterBoard",
    ]

    static var backupsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("3106/SaveBackups", isDirectory: true)
    }

    // MARK: - Scanning

    /// Third-party apps eligible for save backups (identified only).
    static func eligibleApps() -> [InstalledApp] {
        let apps = ContainerStore.installedAppsFromCachedCatalog()
        if !apps.isEmpty {
            return apps.filter {
                ContainerPresentationPolicy.isIdentified(bundleID: $0.bundleID)
                    && !protectedBundleIDs.contains($0.bundleID)
                    && !$0.containerPath.isEmpty
            }
        }
        return []
    }

    // MARK: - Backup

    @discardableResult
    static func backup(app: InstalledApp, includePreferences: Bool = true) throws -> BackupEntry {
        guard !protectedBundleIDs.contains(app.bundleID) else {
            throw SaveBackupError.protectedBundle
        }
        guard ContainerStore.isApplicationContainerPath(app.containerPath) else {
            throw SaveBackupError.containerUnavailable
        }

        let grant = ContainerStore.grantContainerAccess(app.containerPath)
        defer {
            if grant >= 0 { SandboxAccess.release(grant) }
        }

        let documents = (app.containerPath as NSString).appendingPathComponent("Documents")
        let preferences = (app.containerPath as NSString)
            .appendingPathComponent("Library/Preferences")

        var sources: [URL] = []
        if FileManager.default.fileExists(atPath: documents) {
            sources.append(URL(fileURLWithPath: documents, isDirectory: true))
        }
        if includePreferences, FileManager.default.fileExists(atPath: preferences) {
            sources.append(URL(fileURLWithPath: preferences, isDirectory: true))
        }
        guard !sources.isEmpty else {
            throw SaveBackupError.nothingToBackUp
        }

        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)

        // Millisecond stamp: two backups of the same app within one second
        // must not collide (the writer refuses pre-existing destinations).
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let safeName = app.bundleID.replacingOccurrences(of: "/", with: "_")
        let archiveURL = backupsDirectory
            .appendingPathComponent("\(safeName)-\(stamp).3106save")

        // Manifest rides inside the zip under the canonical entry name
        // "BackupManifest.plist" — readManifest and restore both look for
        // exactly that name, so the staged file must carry it too. It lives
        // in a staging subdir so concurrent backups never share a filename.
        let manifest = SaveBackupManifest(
            bundleID: app.bundleID,
            appName: app.displayName,
            createdAt: Date(),
            appVersion: app.version,
            includesPreferences: includePreferences
        )
        let stagingDir = backupsDirectory
            .appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        let manifestURL = stagingDir.appendingPathComponent("BackupManifest.plist")
        let manifestData = try PropertyListEncoder().encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)

        // Write to a temp name, then swap in atomically (the writer refuses
        // pre-existing destinations, which also guards against clobbering).
        let tempURL = backupsDirectory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        _ = try ZIPArchiveWriter.write(
            items: sources + [manifestURL],
            to: tempURL
        )
        try FileManager.default.moveItem(at: tempURL, to: archiveURL)
        // Sidecar manifest: listing reads this small file instead of fully
        // extracting every archive (N saves = N full unzips per tab visit).
        let sidecarURL = archiveURL.deletingLastPathComponent()
            .appendingPathComponent(archiveURL.deletingPathExtension().lastPathComponent + ".manifest.plist")
        try? manifestData.write(to: sidecarURL, options: .atomic)
        ActivityHistory.log(.backup, feature: "savebackup", app.bundleID)

        let size = (try? archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        SoundEffects.play(.success)
        return BackupEntry(
            id: UUID(),
            fileURL: archiveURL,
            manifest: manifest,
            sizeBytes: Int64(size)
        )
    }

    // MARK: - Listing

    static func listBackups() -> [BackupEntry] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: backupsDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "3106save" }
            .compactMap { url -> BackupEntry? in
                guard let manifest = readManifestFast(from: url) else { return nil }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return BackupEntry(
                    id: UUID(),
                    fileURL: url,
                    manifest: manifest,
                    sizeBytes: Int64(size)
                )
            }
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
    }

    /// Read the manifest from the sidecar file when present; fall back to a
    /// full archive extract only for legacy archives without a sidecar.
    private static func readManifestFast(from archiveURL: URL) -> SaveBackupManifest? {
        let sidecarURL = archiveURL.deletingLastPathComponent()
            .appendingPathComponent(archiveURL.deletingPathExtension().lastPathComponent + ".manifest.plist")
        if let data = try? Data(contentsOf: sidecarURL),
           let manifest = try? PropertyListDecoder().decode(SaveBackupManifest.self, from: data) {
            return manifest
        }
        return readManifest(from: archiveURL)
    }

    static func delete(_ entry: BackupEntry) {
        try? FileManager.default.removeItem(at: entry.fileURL)
        let sidecarURL = entry.fileURL.deletingLastPathComponent()
            .appendingPathComponent(entry.fileURL.deletingPathExtension().lastPathComponent + ".manifest.plist")
        try? FileManager.default.removeItem(at: sidecarURL)
    }

    private static func readManifest(from archiveURL: URL) -> SaveBackupManifest? {
        // Extract just the manifest: run a full extract into a scratch dir
        // and read BackupManifest.plist (cheap enough; saves are small).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("3106-save-manifest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            _ = try ZIPArchiveExtractor.extract(archiveURL: archiveURL, into: scratch)
            let candidates = [
                scratch.appendingPathComponent("BackupManifest.plist"),
                // The writer nests by source last component; search shallow.
            ]
            var found: URL?
            for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
                found = candidate
                break
            }
            if found == nil {
                if let enumerator = FileManager.default.enumerator(at: scratch, includingPropertiesForKeys: nil) {
                    for case let url as URL in enumerator
                    where url.lastPathComponent == "BackupManifest.plist" {
                        found = url
                        break
                    }
                }
            }
            guard let manifestURL = found,
                  let data = try? Data(contentsOf: manifestURL),
                  let plist = try? PropertyListSerialization.propertyList(
                      from: data, options: [], format: nil
                  ) as? [String: Any],
                  let bundleID = plist["bundleID"] as? String else {
                return nil
            }
            return SaveBackupManifest(
                bundleID: bundleID,
                appName: plist["appName"] as? String ?? "",
                createdAt: plist["createdAt"] as? Date ?? Date.distantPast,
                appVersion: plist["appVersion"] as? String ?? "",
                includesPreferences: plist["includesPreferences"] as? Bool ?? true
            )
        } catch {
            return nil
        }
    }

    // MARK: - Restore

    /// Restore a save backup into the CURRENT container of the manifest's
    /// bundle ID (reinstall re-matches by bundle, not by UUID). The current
    /// Documents/Preferences are backed up automatically before overwrite.
    static func restore(_ entry: BackupEntry) throws {
        guard !protectedBundleIDs.contains(entry.manifest.bundleID) else {
            throw SaveBackupError.protectedBundle
        }
        // Resolve the current container fresh — never trust a stored UUID.
        guard let containerPath = ContainerStore.resolveAppContainerPath(
            bundleID: entry.manifest.bundleID
        ), ContainerStore.isApplicationContainerPath(containerPath) else {
            throw SaveBackupError.restoreTargetUnavailable
        }

        let grant = ContainerStore.grantContainerAccess(containerPath)
        defer {
            if grant >= 0 { SandboxAccess.release(grant) }
        }

        // Extract with the project's hardened extractor (safeComponents
        // rejects traversal and absolute entries).
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("3106-save-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        _ = try ZIPArchiveExtractor.extract(archiveURL: entry.fileURL, into: scratch)

        // Locate the manifest: the archive-TOP-LEVEL copy first (the writer
        // stages it there), then a deep search. An unordered deep search can
        // hit a file of the same name inside the backed-up app's own data
        // and kill a legitimate restore with .manifestMissing.
        let topLevelManifest = scratch.appendingPathComponent("BackupManifest.plist")
        let manifestCandidate = FileManager.default.fileExists(atPath: topLevelManifest.path)
            ? topLevelManifest
            : findFile(named: "BackupManifest.plist", under: scratch)
        guard let manifestURL = manifestCandidate,
              let data = try? Data(contentsOf: manifestURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              plist["bundleID"] as? String == entry.manifest.bundleID else {
            throw SaveBackupError.manifestMissing
        }

        let documentsSource = findDirectory(named: "Documents", under: scratch)
        let preferencesSource = findDirectory(named: "Preferences", under: scratch)
        guard documentsSource != nil || preferencesSource != nil else {
            throw SaveBackupError.invalidArchive
        }

        let fm = FileManager.default
        let targetDocuments = (containerPath as NSString).appendingPathComponent("Documents")
        let targetPreferences = (containerPath as NSString)
            .appendingPathComponent("Library/Preferences")

        // Restore with a REAL rollback path: directories are renamed aside
        // (same-volume, kept as .pre-restore-*) instead of the old
        // recordOriginalIfNeeded call that silently no-opped on directories
        // and then removeItem destroyed the live data with no backup.
        pruneRestoreAsides(near: URL(fileURLWithPath: (containerPath as NSString).deletingLastPathComponent))
        func restoreDirectory(source: URL, targetPath: String) throws {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: targetPath, isDirectory: &isDirectory) {
                let targetURL = URL(fileURLWithPath: targetPath)
                if isDirectory.boolValue {
                    let asideURL = targetURL.deletingLastPathComponent()
                        .appendingPathComponent(
                            ".pre-restore-\(Int(Date().timeIntervalSince1970 * 1000))-\(targetURL.lastPathComponent)",
                            isDirectory: true
                        )
                    try fm.moveItem(at: targetURL, to: asideURL)
                } else {
                    try fm.removeItem(at: targetURL)
                }
            }
            try fm.copyItem(at: source, to: URL(fileURLWithPath: targetPath))
        }

        if let documentsSource {
            try restoreDirectory(source: documentsSource, targetPath: targetDocuments)
        }
        if let preferencesSource {
            try restoreDirectory(source: preferencesSource, targetPath: targetPreferences)
        }
        ActivityHistory.log(.restore, feature: "savebackup", entry.manifest.bundleID)
        SoundEffects.play(.success)
    }

    /// Keep at most `keep` .pre-restore-* sibling dirs (oldest deleted):
    /// every restore leaves one aside and without pruning they accumulate
    /// forever inside the app container.
    static func pruneRestoreAsides(near directory: URL, keep: Int = 4) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return }
        let asides = contents.filter { $0.lastPathComponent.hasPrefix(".pre-restore-") }
        guard asides.count > keep else { return }
        let sorted = asides.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }
        for stale in sorted.dropFirst(keep) {
            try? fm.removeItem(at: stale)
        }
    }

    // MARK: - Helpers

    private enum EntryKind {
        case file
        case directory
    }

    private static func findFile(named name: String, under root: URL) -> URL? {
        find(kindOf: .file, named: name, under: root)
    }

    private static func findDirectory(named name: String, under root: URL) -> URL? {
        find(kindOf: .directory, named: name, under: root)
    }

    private static func find(
        kindOf: EntryKind,
        named name: String,
        under root: URL
    ) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: []
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            switch kindOf {
            case .directory where values?.isDirectory == true:
                return url
            case .file where values?.isRegularFile == true:
                return url
            default:
                continue
            }
        }
        return nil
    }
}
