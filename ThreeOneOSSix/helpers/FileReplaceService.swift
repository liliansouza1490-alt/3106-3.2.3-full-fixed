import Foundation
import Darwin

/// Arbitrary file replacement (Erosion-CN OperationsView parity, extended
/// per the operator's flow): pick an app, pick a file, optionally back up
/// the original, replace — with a persistent replace log so a backup can be
/// restored later, even after relaunch.
///
/// Safety rails ported from Erosion's blockedSystemPathReason: core system
/// security files and protected prefixes are refused for raw overwrite and
/// delete; those go through their dedicated modules (Gestalt editor,
/// Supervised Mode) instead.
enum FileReplaceService {

    // MARK: - Replace log model

    struct ReplaceRecord: Codable, Identifiable, Equatable {
        let id: UUID
        let date: Date
        /// App display name at replace time (bundle ID is the stable key).
        let bundleID: String
        let appName: String
        /// Absolute path of the replaced/deleted target.
        let targetPath: String
        let operation: Operation
        /// Path of the pre-replace backup, when a backup was taken.
        let backupPath: String?
        let replacementSizeBytes: Int64

        enum Operation: String, Codable {
            case replace
            case delete
            case writeNew
        }
    }

    enum FileReplaceError: Error, Equatable, LocalizedError {
        case protectedSystemPath(reason: String)
        case targetMissing
        case sourceMissing
        case backupFailed

        var errorDescription: String? {
            switch self {
            case .protectedSystemPath: return "filereplace.error.protected"
            case .targetMissing: return "filereplace.error.target_missing"
            case .sourceMissing: return "filereplace.error.source_missing"
            case .backupFailed: return "filereplace.error.backup_failed"
            }
        }
    }

    // MARK: - Safety rails (Erosion parity)

    static let protectedFileNames: Set<String> = [
        "com.apple.mobilegestalt.plist",
        "cloudconfigurationdetails.plist",
        "keychain-2.db",
        "truststore.sqlite3",
    ]

    static let protectedPathPrefixes: [String] = [
        "/system", "/private/preboot", "/usr", "/bin", "/sbin", "/dev",
        "/var/keychains", "/private/var/keychains",
        "/var/db", "/private/var/db",
        "/var/MobileAsset",
    ]

    static func blockedSystemPathReason(for path: String) -> String? {
        let standardized = (path as NSString).standardizingPath
        let lower = standardized.lowercased()
        if protectedFileNames.contains((standardized as NSString).lastPathComponent.lowercased()) {
            return "filereplace.blocked.file_name"
        }
        for prefix in protectedPathPrefixes
        where lower == prefix.lowercased() || lower.hasPrefix(prefix.lowercased() + "/") {
            return "filereplace.blocked.prefix"
        }
        return nil
    }

    // MARK: - Replace presets (operator request: save a picked app+path as
    // a named recipe; next time, pick the recipe and the target is set)

    struct ReplacePreset: Codable, Identifiable, Equatable {
        let id: UUID
        let name: String
        let bundleID: String
        let appName: String
        let targetPath: String
        let backupRequested: Bool
        let createdAt: Date
    }

    private static let presetLock = NSLock()
    private static let maxPresets = 50

    static var presetsFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("3106/FileReplacePresets.plist", isDirectory: false)
    }

    static func loadPresets() -> [ReplacePreset] {
        presetLock.lock()
        defer { presetLock.unlock() }
        return loadPresetsLocked()
    }

    private static func loadPresetsLocked() -> [ReplacePreset] {
        guard
            let data = try? Data(contentsOf: presetsFileURL),
            let plist = try? PropertyListDecoder().decode([ReplacePreset].self, from: data)
        else { return [] }
        return plist.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    static func savePreset(
        name: String,
        bundleID: String,
        appName: String,
        targetPath: String,
        backupRequested: Bool
    ) -> [ReplacePreset] {
        presetLock.lock()
        defer { presetLock.unlock() }
        var presets = loadPresetsLocked()
        // Same target path replaces its preset (an updated recipe, not a dupe).
        presets.removeAll {
            $0.targetPath.caseInsensitiveCompare(targetPath) == .orderedSame
        }
        presets.insert(
            ReplacePreset(
                id: UUID(),
                name: name,
                bundleID: bundleID,
                appName: appName,
                targetPath: targetPath,
                backupRequested: backupRequested,
                createdAt: Date()
            ),
            at: 0
        )
        if presets.count > maxPresets {
            presets.removeLast(presets.count - maxPresets)
        }
        if let data = try? PropertyListEncoder().encode(presets) {
            try? data.write(to: presetsFileURL, options: .atomic)
        }
        return presets
    }

    static func deletePreset(id: UUID) {
        presetLock.lock()
        defer { presetLock.unlock() }
        var presets = loadPresetsLocked()
        presets.removeAll { $0.id == id }
        if let data = try? PropertyListEncoder().encode(presets) {
            try? data.write(to: presetsFileURL, options: .atomic)
        }
    }

    // MARK: - Log persistence

    private static let maxEntries = 200
    private static let logLock = NSLock()

    static var logFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("3106/FileReplaceLog.plist", isDirectory: false)
    }

    static func loadLog() -> [ReplaceRecord] {
        logLock.lock()
        defer { logLock.unlock() }
        return loadLogLocked()
    }

    private static func loadLogLocked() -> [ReplaceRecord] {
        guard
            let data = try? Data(contentsOf: logFileURL),
            let plist = try? PropertyListDecoder().decode([ReplaceRecord].self, from: data)
        else { return [] }
        return plist.sorted { $0.date > $1.date }
    }

    @discardableResult
    static func appendLog(_ record: ReplaceRecord) -> [ReplaceRecord] {
        logLock.lock()
        defer { logLock.unlock() }
        var entries = loadLogLocked()
        entries.insert(record, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        persistLocked(entries)
        return entries
    }

    static func clearLog() {
        logLock.lock()
        defer { logLock.unlock() }
        try? FileManager.default.removeItem(at: logFileURL)
    }

    /// Remove a single log entry (and only the entry — the caller deletes
    /// the backup file it points at).
    static func clearLogEntry(id: UUID) {
        logLock.lock()
        defer { logLock.unlock() }
        var entries = loadLogLocked()
        entries.removeAll { $0.id == id }
        persistLocked(entries)
    }

    private static func persistLocked(_ entries: [ReplaceRecord]) {
        guard let data = try? PropertyListEncoder().encode(entries) else { return }
        try? data.write(to: logFileURL, options: .atomic)
    }

    // MARK: - Backups

    static var backupDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("3106/FileReplaceBackups", isDirectory: true)
    }

    /// Copy the current target into the backup dir under a timestamped name.
    /// Returns the backup path, nil when the target does not exist yet
    /// (writing a brand-new file has nothing to back up).
    static func backupTarget(_ targetPath: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: targetPath) else { return nil }
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let safeName = ((targetPath as NSString).lastPathComponent)
            .replacingOccurrences(of: "/", with: "_")
        let backupURL = backupDirectory
            .appendingPathComponent("\(stamp)_\(safeName)")
        do {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: targetPath),
                to: backupURL
            )
            return backupURL.path
        } catch {
            throw FileReplaceError.backupFailed
        }
    }

    /// Restore a backup recorded in a log entry. The CURRENT live file is
    /// renamed aside first (same-volume, recoverable) — never bare-deleted.
    static func restore(record: ReplaceRecord) throws {
        guard let backupPath = record.backupPath,
              FileManager.default.fileExists(atPath: backupPath) else {
            throw FileReplaceError.sourceMissing
        }
        let fm = FileManager.default
        let targetURL = URL(fileURLWithPath: record.targetPath)
        var isDirectory: ObjCBool = false

        if fm.fileExists(atPath: record.targetPath, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                throw FileReplaceError.backupFailed
            }
            // Safety aside of the current live version before overwriting it.
            let asideURL = targetURL.deletingLastPathComponent()
                .appendingPathComponent(
                    ".pre-restore-\(Int(Date().timeIntervalSince1970 * 1000))-\(targetURL.lastPathComponent)",
                    isDirectory: true
                )
            try fm.moveItem(at: targetURL, to: asideURL)
        }
        let parent = (record.targetPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: backupPath), to: targetURL)
    }

    /// The aside left behind by restore() accumulates; prune to newest 4.
    static func pruneRestoreAsides(inContainerPath containerPath: String) {
        let parent = (containerPath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: parent),
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        ) else { return }
        let asides = contents.filter { $0.lastPathComponent.hasPrefix(".pre-restore-") }
        guard asides.count > 4 else { return }
        let sorted = asides.sorted { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return leftDate > rightDate
        }
        for stale in sorted.dropFirst(4) {
            try? fm.removeItem(at: stale)
        }
    }

    // MARK: - Core operations

    /// Replace (or create) the target with the given payload.
    static func replace(
        targetPath: String,
        payload: Data,
        bundleID: String,
        appName: String,
        backupRequested: Bool
    ) throws -> ReplaceRecord {
        if let reason = blockedSystemPathReason(for: targetPath) {
            throw FileReplaceError.protectedSystemPath(reason: reason)
        }

        let grant = ContainerStore.grantContainerAccess(
            (targetPath as NSString).deletingLastPathComponent
        )
        defer {
            if grant >= 0 { SandboxAccess.release(grant) }
        }

        var backupPath: String?
        if backupRequested {
            backupPath = try backupTarget(targetPath)
        }

        let existed = FileManager.default.fileExists(atPath: targetPath)
        try payload.write(
            to: URL(fileURLWithPath: targetPath),
            options: .atomic
        )

        let record = ReplaceRecord(
            id: UUID(),
            date: Date(),
            bundleID: bundleID,
            appName: appName,
            targetPath: targetPath,
            operation: existed ? .replace : .writeNew,
            backupPath: backupPath,
            replacementSizeBytes: Int64(payload.count)
        )
        appendLog(record)
        ActivityHistory.log(
            .write,
            feature: "filereplace",
            "\(appName) · \(record.operation.rawValue)"
        )
        SoundEffects.play(.success)
        return record
    }

    /// Delete the target (backup always taken — a delete without a backup is
    /// unrecoverable by design).
    static func deleteTarget(
        targetPath: String,
        bundleID: String,
        appName: String
    ) throws -> ReplaceRecord {
        if let reason = blockedSystemPathReason(for: targetPath) {
            throw FileReplaceError.protectedSystemPath(reason: reason)
        }
        guard FileManager.default.fileExists(atPath: targetPath) else {
            throw FileReplaceError.targetMissing
        }

        let grant = ContainerStore.grantContainerAccess(
            (targetPath as NSString).deletingLastPathComponent
        )
        defer {
            if grant >= 0 { SandboxAccess.release(grant) }
        }

        guard let backupPath = try backupTarget(targetPath) else {
            throw FileReplaceError.targetMissing
        }
        try FileManager.default.removeItem(at: URL(fileURLWithPath: targetPath))

        let record = ReplaceRecord(
            id: UUID(),
            date: Date(),
            bundleID: bundleID,
            appName: appName,
            targetPath: targetPath,
            operation: .delete,
            backupPath: backupPath,
            replacementSizeBytes: 0
        )
        appendLog(record)
        ActivityHistory.log(.write, feature: "filereplace", "\(appName) · delete")
        SoundEffects.play(.warning)
        return record
    }

    /// Export the current target to a temp file for the share sheet.
    static func exportTarget(targetPath: String) throws -> URL {
        guard FileManager.default.fileExists(atPath: targetPath) else {
            throw FileReplaceError.targetMissing
        }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("3106-Export-\(UUID().uuidString)")
            .appendingPathComponent((targetPath as NSString).lastPathComponent)
        try FileManager.default.createDirectory(
            at: temp.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: targetPath),
            to: temp
        )
        return temp
    }
}
