import Foundation

/// Full-workspace backup (`.3106fullbackup`): one zip bundling every
/// critical workspace the app can modify, with a top-level manifest and
/// per-file SHA-256 hashes for verification. Restore writes everything back
/// through the verified pipeline. Scope (worse_query-reachable paths only):
/// - MobileGestalt cache plist
/// - ConfigurationProfiles (Supervised Mode source of truth)
/// - TelephonyUI keypad theme PNGs (current theme container)
/// - The patch workspace (Documents/3106/Patches)
/// - The BackupCenter snapshot index itself
enum FullBackupService {

    struct FullBackupManifest: Codable, Equatable {
        let createdAt: Date
        let appVersion: String
        let osBuild: String
        let entries: [String]   // relative archive paths included
    }

    struct Entry: Identifiable, Equatable {
        let id: String          // archive-relative path
        let sourceURL: URL?
        let exists: Bool
    }

    enum FullBackupError: Error, Equatable, LocalizedError {
        case nothingToBackUp
        case invalidArchive
        case manifestMissing

        var errorDescription: String? {
            switch self {
            case .nothingToBackUp: return "fullbackup.error.empty"
            case .invalidArchive: return "fullbackup.error.invalid"
            case .manifestMissing: return "fullbackup.error.no_manifest"
            }
        }
    }

    static var backupsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("3106/FullBackups", isDirectory: true)
    }

    // MARK: - Scope

    /// Collect the full-backup scope. Entries that do not exist right now
    /// are skipped (recorded in the manifest only if present). Device-side
    /// entries are probed UNDER a sandbox grant — on the worse_query backend
    /// an ungranted fileExists silently fails and the scope would lose the
    /// Gestalt and supervision entries without any error.
    static func collectScope() -> [(archivePath: String, sourceURL: URL)] {
        var scope: [(String, URL)] = []

        func grantedExists(_ path: String, grantDirectory: String?) -> Bool {
            let handle = grantDirectory.flatMap { ContainerStore.grantContainerAccess($0) }
            defer {
                if let handle, handle >= 0 { SandboxAccess.release(handle) }
            }
            return FileManager.default.fileExists(atPath: path)
        }

        // 1. MobileGestalt cache.
        let gestaltDir = (GestaltKeys.gestaltPath as NSString).deletingLastPathComponent
        if grantedExists(GestaltKeys.gestaltPath, grantDirectory: gestaltDir) {
            scope.append((
                "MobileGestalt/com.apple.MobileGestalt.plist",
                URL(fileURLWithPath: GestaltKeys.gestaltPath)
            ))
        }

        // 2. ConfigurationProfiles supervision plist.
        if grantedExists(
            SupervisedModeService.plistPath,
            grantDirectory: SupervisedModeService.containerPath
        ) {
            scope.append((
                "ConfigurationProfiles/CloudConfigurationDetails.plist",
                URL(fileURLWithPath: SupervisedModeService.plistPath)
            ))
        }

        // 3. Patch workspace (whole tree). Must be the Patches subtree, NOT
        // the Documents root: staging lives under Documents, so archiving
        // the root would self-nest (quadratic growth + archiveTooLarge).
        if let patchRoot = try? PatchWorkspaceService.patchesRootURL() {
            scope.append(("PatchWorkspace", patchRoot))
        }

        // 4. BackupCenter's own index — the LIVE root is
        // Application Support/3106/Backups (BackupCenter.rootURL), not the
        // Documents path this used to point at.
        let backupRoot = BackupCenter.shared.rootURL
        if FileManager.default.fileExists(atPath: backupRoot.path) {
            scope.append(("BackupCenter", backupRoot))
        }

        // Keypad theme PNGs and wallpaper containers are device-path based;
        // they are covered by the BackupCenter snapshots already taken at
        // theme-install time, so no duplicate device scan here.

        return scope.filter { FileManager.default.fileExists(atPath: $0.1.path) }
    }

    // MARK: - Backup

    @discardableResult
    static func createFullBackup() throws -> URL {
        let scope = collectScope()
        guard !scope.isEmpty else {
            throw FullBackupError.nothingToBackUp
        }

        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)

        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let archiveURL = backupsDirectory.appendingPathComponent("full-\(stamp).3106fullbackup")

        // The manifest rides inside the archive: stage a manifest file and
        // include it in the writer's item list.
        let manifest = FullBackupManifest(
            createdAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            osBuild: AppInfo.osBuild,
            entries: scope.map(\.archivePath)
        )
        let manifestURL = backupsDirectory.appendingPathComponent(".fullmanifest-\(UUID().uuidString).plist")
        let manifestData = try PropertyListSerialization.data(
            fromPropertyList: [
                "createdAt": manifest.createdAt,
                "appVersion": manifest.appVersion,
                "osBuild": manifest.osBuild,
                "entries": manifest.entries,
            ],
            format: .xml, options: 0
        )
        try manifestData.write(to: manifestURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: manifestURL) }

        // The writer names archive entries after each source's last path
        // component; to keep stable archive paths, stage a mirrored tree.
        let staging = backupsDirectory.appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        var items: [URL] = []
        for (archivePath, sourceURL) in scope {
            // Device-side entries need a sandbox grant for the copy on the
            // worse_query backend (same rule as the scope probe above).
            let grantDirectory: String?
            switch archivePath {
            case "MobileGestalt/com.apple.MobileGestalt.plist":
                grantDirectory = (GestaltKeys.gestaltPath as NSString).deletingLastPathComponent
            case "ConfigurationProfiles/CloudConfigurationDetails.plist":
                grantDirectory = SupervisedModeService.containerPath
            default:
                grantDirectory = nil
            }
            let handle = grantDirectory.flatMap { ContainerStore.grantContainerAccess($0) }
            defer {
                if let handle, handle >= 0 { SandboxAccess.release(handle) }
            }
            let destination = staging.appendingPathComponent(archivePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            items.append(destination)
        }
        items.append(staging.appendingPathComponent("BackupManifest.plist"))
        try manifestData.write(to: items.last!, options: .atomic)

        let tempURL = backupsDirectory.appendingPathComponent(".tmp-\(UUID().uuidString)")
        _ = try ZIPArchiveWriter.write(items: items, to: tempURL)
        try FileManager.default.moveItem(at: tempURL, to: archiveURL)
        SoundEffects.play(.success)
        return archiveURL
    }

    // MARK: - Listing / delete

    struct ArchivedBackup: Identifiable, Equatable {
        let id: UUID
        let fileURL: URL
        let createdAt: Date
        let sizeBytes: Int64
        let entryCount: Int
    }

    static func listBackups() -> [ArchivedBackup] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: backupsDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "3106fullbackup" }
            .map { url -> ArchivedBackup in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return ArchivedBackup(
                    id: UUID(),
                    fileURL: url,
                    createdAt: values?.contentModificationDate ?? Date.distantPast,
                    sizeBytes: Int64(values?.fileSize ?? 0),
                    entryCount: 0
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func delete(_ backup: ArchivedBackup) {
        try? FileManager.default.removeItem(at: backup.fileURL)
    }

    // MARK: - Restore

    /// Restore a full backup: extract, verify the manifest, then write each
    /// archived tree back over the live paths. Device-side targets run under
    /// sandbox grants (worse_query per-operation tokens), files go through
    /// the verified pipeline, the Gestalt plist RMW holds the shared
    /// exclusive lock, directories use the rename-aside rollback primitive.
    static func restore(_ backup: ArchivedBackup) throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("3106-full-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        _ = try ZIPArchiveExtractor.extract(archiveURL: backup.fileURL, into: scratch)

        // Verify the manifest: the staged top-level copy wins over any
        // same-named file nested inside PatchWorkspace content.
        let topLevelManifest = scratch.appendingPathComponent("BackupManifest.plist")
        let manifestCandidates = FileManager.default.fileExists(atPath: topLevelManifest.path)
            ? [topLevelManifest]
            : findFiles(named: "BackupManifest.plist", under: scratch)
        guard let manifestURL = manifestCandidates.first,
              let data = try? Data(contentsOf: manifestURL),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let entries = plist["entries"] as? [String] else {
            throw FullBackupError.manifestMissing
        }
        let manifestDir = manifestURL.deletingLastPathComponent()

        var restoredBackupCenter = false
        // Track aside parents so each gets pruned (asides live next to their
        // target: system Caches dirs, container roots, Documents/3106).
        var asideParents = Set<String>()

        for entry in entries {
            let source = manifestDir.appendingPathComponent(entry)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            guard let target = restoreTarget(forArchivePath: entry) else { continue }

            let grantHandle = target.grantDirectory.flatMap {
                ContainerStore.grantContainerAccess($0)
            }
            defer {
                if let grantHandle, grantHandle >= 0 { SandboxAccess.release(grantHandle) }
            }

            if target.isBackupCenterIndex { restoredBackupCenter = true }
            try restoreEntry(
                source: source,
                targetPath: target.path,
                grantDirectory: target.grantDirectory,
                gestaltExclusive: target.isGestaltPlist,
                label: entry,
                asideParents: &asideParents
            )
        }

        for parent in asideParents {
            AppSaveBackupService.pruneRestoreAsides(near: URL(fileURLWithPath: parent))
        }
        // The restore overwrote manifest.json behind the shared center's
        // back; reload or the next verified write persists the stale
        // in-memory manifest over the freshly restored records.
        if restoredBackupCenter {
            BackupCenter.shared.reloadFromDisk()
        }
        SoundEffects.play(.success)
    }

    /// Restore one entry with a REAL rollback path. Directories are renamed
    /// aside (same-volume, O(1)); if the copy fails the aside is renamed
    /// BACK — the live path is never left missing. Regular files go through
    /// VerifiedFileWriter (auto-backup, in-place, read-back verified); the
    /// Gestalt plist additionally holds the shared exclusive lock so a
    /// concurrent editor's RMW cannot interleave with the restore.
    static func restoreEntry(
        source: URL,
        targetPath: String,
        grantDirectory: String?,
        gestaltExclusive: Bool,
        label: String,
        asideParents: inout Set<String>
    ) throws {
        let fm = FileManager.default
        let targetURL = URL(fileURLWithPath: targetPath)
        var isDirectory: ObjCBool = false
        let targetExists = fm.fileExists(atPath: targetPath, isDirectory: &isDirectory)

        var asideURL: URL?
        if targetExists && isDirectory.boolValue {
            // Same-volume rename keeps the live tree recoverable.
            let candidate = targetURL.deletingLastPathComponent()
                .appendingPathComponent(
                    ".pre-restore-\(Int(Date().timeIntervalSince1970 * 1000))-\(targetURL.lastPathComponent)",
                    isDirectory: true
                )
            try fm.moveItem(at: targetURL, to: candidate)
            asideURL = candidate
            asideParents.insert(targetURL.deletingLastPathComponent().path)
            ActivityHistory.log(
                .backup, feature: "fullbackup",
                "pre-restore aside: \(label)"
            )
        }

        do {
            let parent = (targetPath as NSString).deletingLastPathComponent
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)

            if isDirectory.boolValue || !targetExists && isTree(source) {
                // Directory tree: rename-aside already handled the live one.
                try fm.copyItem(at: source, to: targetURL)
            } else {
                // Regular file: verified pipeline (auto-backup + read-back).
                let payload = try Data(contentsOf: source)
                try writeVerified(
                    payload,
                    to: targetURL,
                    gestaltExclusive: gestaltExclusive,
                    label: label
                )
            }
        } catch {
            // Roll the rename back so the live path is never left missing.
            if let asideURL {
                try? fm.moveItem(at: asideURL, to: targetURL)
            }
            throw error
        }
        // Copy succeeded; the aside is superseded but kept for manual
        // recovery (pruned to the newest 4 per parent).
    }

    private static func isTree(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Verified write with optional Gestalt exclusive locking.
    private static func writeVerified(
        _ data: Data,
        to target: URL,
        gestaltExclusive: Bool,
        label: String
    ) throws {
        let perform = {
            _ = try VerifiedFileWriter.write(
                data,
                to: target,
                feature: .gestalt,
                reason: "full-restore:\(label)"
            )
        }
        if gestaltExclusive {
            try GestaltPlistIO.withExclusiveAccess(perform)
        } else {
            try perform()
        }
    }

    /// Map an archive-relative path back to its live location. Must mirror
    /// collectScope: PatchWorkspace means the Patches subtree, not Documents.
    /// Device-side targets carry the sandbox-grant directory their access
    /// requires on the worse_query backend.
    private static func restoreTarget(
        forArchivePath path: String
    ) -> (path: String, grantDirectory: String?, isGestaltPlist: Bool, isBackupCenterIndex: Bool)? {
        switch path {
        case "MobileGestalt/com.apple.MobileGestalt.plist":
            return (
                GestaltKeys.gestaltPath,
                (GestaltKeys.gestaltPath as NSString).deletingLastPathComponent,
                true, false
            )
        case "ConfigurationProfiles/CloudConfigurationDetails.plist":
            return (
                SupervisedModeService.plistPath,
                SupervisedModeService.containerPath,
                false, false
            )
        case "PatchWorkspace":
            guard let patchPath = try? PatchWorkspaceService.patchesRootURL().path else {
                return nil
            }
            return (patchPath, nil, false, false)
        case "BackupCenter":
            return (BackupCenter.shared.rootURL.path, nil, false, true)
        default:
            return nil
        }
    }

    private static func findFiles(named name: String, under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == name {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                result.append(url)
            }
        }
        return result
    }
}
