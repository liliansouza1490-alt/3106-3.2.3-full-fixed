import Foundation
import CryptoKit
import Darwin

// MARK: - Models

enum BackupFeature: String, Codable, CaseIterable, Identifiable {
    case patch
    case gestalt
    case keypad
    case file
    case wallpaper
    case manual

    var id: String { rawValue }
}

enum BackupKind: String, Codable, CaseIterable {
    /// The first version of a target this app ever saw. Never overwritten.
    case original
    /// A snapshot taken immediately before a write.
    case version
    /// A user-created restore point.
    case manual
}

struct BackupRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: BackupKind
    let feature: BackupFeature
    /// Absolute path of the file this record protects.
    let targetPath: String
    let containerPath: String?
    let bundleID: String?
    /// Path relative to the backup root, e.g. `Versions/.../payload`.
    let payloadRelativePath: String
    let sha256: String
    let byteCount: Int64
    let fileDevice: UInt64?
    let fileInode: UInt64?
    let createdAt: Date
    let reason: String
    let appVersion: String
    let osBuild: String
    var pinned: Bool

    var fileName: String {
        (targetPath as NSString).lastPathComponent
    }

    func payloadURL(rootURL: URL) -> URL {
        rootURL.appendingPathComponent(payloadRelativePath)
    }
}

struct BackupJournal: Codable, Identifiable, Equatable {
    let id: UUID
    let targetPath: String
    let feature: BackupFeature
    let backupRecordID: UUID
    let createdAt: Date
    let reason: String
}

private struct BackupManifest: Codable {
    var version: Int
    var records: [BackupRecord]

    static let empty = BackupManifest(version: 1, records: [])
}

enum BackupError: Error, Equatable {
    case targetMissing(String)
    case targetNotRegularFile(String)
    case targetIsSymbolicLink(String)
    case backupFailed(String)
    case backupVerificationFailed(String)
    case restoreFailed(String)
    case writeFailed(String)
    case readBackMismatch(String)
    case originalIsProtected(String)
    case recordMissing(String)
    case journalFailed(String)
}

extension BackupError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .targetMissing(let path): return "Target does not exist: \(path)"
        case .targetNotRegularFile(let path): return "Target is not a regular file: \(path)"
        case .targetIsSymbolicLink(let path): return "Symbolic links are not supported: \(path)"
        case .backupFailed(let detail): return "Backup failed: \(detail)"
        case .backupVerificationFailed(let detail): return "Backup verification failed: \(detail)"
        case .restoreFailed(let detail): return "Restore failed: \(detail)"
        case .writeFailed(let detail): return "Write failed: \(detail)"
        case .readBackMismatch(let path): return "Written contents did not verify: \(path)"
        case .originalIsProtected(let path): return "Original backups cannot be deleted: \(path)"
        case .recordMissing(let id): return "Backup record not found: \(id)"
        case .journalFailed(let detail): return "Journal operation failed: \(detail)"
        }
    }

    var localizationKey: String {
        switch self {
        case .targetMissing: return "backup.error.target_missing"
        case .targetNotRegularFile: return "backup.error.not_regular"
        case .targetIsSymbolicLink: return "backup.error.symlink"
        case .backupFailed: return "backup.error.backup_failed"
        case .backupVerificationFailed: return "backup.error.verify_failed"
        case .restoreFailed: return "backup.error.restore_failed"
        case .writeFailed: return "backup.error.write_failed"
        case .readBackMismatch: return "backup.error.readback"
        case .originalIsProtected: return "backup.error.original_protected"
        case .recordMissing: return "backup.error.record_missing"
        case .journalFailed: return "backup.error.journal"
        }
    }
}

// MARK: - Backup center

/// Storage for originals, per-write versions and manual restore points.
///
/// All writes in the app are expected to go through `VerifiedFileWriter`,
/// which snapshots the target before touching it. The center is deliberately
/// Foundation-only so the policy can be exercised by the macOS test harness.
final class BackupCenter {
    static let shared = BackupCenter()

    let rootURL: URL
    private let fileManager: FileManager
    private let lock = NSRecursiveLock()
    private var manifest = BackupManifest.empty

    private static let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "?"
    private static let osBuild: String = {
        func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(cString: buffer)
        }
        let machine = sysctlString("hw.machine") ?? "unknown"
        let build = sysctlString("kern.osversion") ?? ProcessInfo.processInfo.operatingSystemVersionString
        return "\(machine) \(build)"
    }()

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.rootURL = base
                .appendingPathComponent("3106", isDirectory: true)
                .appendingPathComponent("Backups", isDirectory: true)
        }
        prepareDirectories()
        loadManifest()
    }

    private var originalsURL: URL { rootURL.appendingPathComponent("Originals", isDirectory: true) }
    private var versionsURL: URL { rootURL.appendingPathComponent("Versions", isDirectory: true) }
    private var manualURL: URL { rootURL.appendingPathComponent("Manual", isDirectory: true) }
    private var journalsURL: URL { rootURL.appendingPathComponent("Journals", isDirectory: true) }
    private var manifestURL: URL { rootURL.appendingPathComponent("manifest.json") }

    private func prepareDirectories() {
        for directory in [rootURL, originalsURL, versionsURL, manualURL, journalsURL] {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableRoot = rootURL
        try? mutableRoot.setResourceValues(values)
    }

    // MARK: Queries

    /// Re-read the manifest from disk. Full-backup restore overwrites
    /// manifest.json behind this instance's back; without this call the
    /// stale in-memory manifest would be persisted over the restored one
    /// by the next verified write, silently dropping every reinstalled
    /// record.
    func reloadFromDisk() {
        lock.lock()
        defer { lock.unlock() }
        loadManifest()
    }

    func records(feature: BackupFeature? = nil) -> [BackupRecord] {
        lock.lock()
        defer { lock.unlock() }
        let records = feature.map { value in manifest.records.filter { $0.feature == value } }
            ?? manifest.records
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    func record(id: UUID) -> BackupRecord? {
        lock.lock()
        defer { lock.unlock() }
        return manifest.records.first { $0.id == id }
    }

    func storageUsage() -> Int64 {
        lock.lock()
        let records = manifest.records
        lock.unlock()
        return records.reduce(0) { $0 + $1.byteCount }
    }

    // MARK: Snapshotting

    @discardableResult
    func recordOriginalIfNeeded(
        target: URL,
        feature: BackupFeature,
        containerPath: String? = nil,
        bundleID: String? = nil,
        reason: String
    ) throws -> BackupRecord {
        lock.lock()
        defer { lock.unlock() }
        return try recordOriginalLocked(
            target: target,
            feature: feature,
            containerPath: containerPath,
            bundleID: bundleID,
            reason: reason
        )
    }

    private func recordOriginalLocked(
        target: URL,
        feature: BackupFeature,
        containerPath: String?,
        bundleID: String?,
        reason: String
    ) throws -> BackupRecord {
        let path = target.standardizedFileURL.path
        if let existing = manifest.records.first(where: {
            $0.kind == .original && $0.feature == feature && $0.targetPath == path
        }) {
            return existing
        }

        let identity = try regularFileIdentity(target)
        let directory = originalsURL
            .appendingPathComponent(feature.rawValue, isDirectory: true)
            .appendingPathComponent(targetKey(for: path), isDirectory: true)
        let payload = directory.appendingPathComponent("payload")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: payload.path) {
            try? fileManager.removeItem(at: payload)
        }
        try cloneOrCopy(from: target, to: payload)
        let hash = try hashFile(payload)
        let sourceHash = try hashFile(target)
        guard hash == sourceHash else {
            throw BackupError.backupVerificationFailed("original copy hash mismatch \(path)")
        }

        let record = BackupRecord(
            id: UUID(),
            kind: .original,
            feature: feature,
            targetPath: path,
            containerPath: containerPath,
            bundleID: bundleID,
            payloadRelativePath: relativePath(of: payload),
            sha256: hash,
            byteCount: identity.size,
            fileDevice: identity.device,
            fileInode: identity.inode,
            createdAt: Date(),
            reason: reason,
            appVersion: Self.appVersion,
            osBuild: Self.osBuild,
            pinned: true
        )
        try writeRecordFile(record, in: directory)
        manifest.records.append(record)
        try saveManifestLocked()
        return record
    }

    @discardableResult
    func createVersionSnapshot(
        target: URL,
        feature: BackupFeature,
        containerPath: String? = nil,
        bundleID: String? = nil,
        reason: String
    ) throws -> BackupRecord {
        lock.lock()
        defer { lock.unlock() }
        return try createVersionLocked(
            target: target,
            feature: feature,
            containerPath: containerPath,
            bundleID: bundleID,
            reason: reason
        )
    }

    private func createVersionLocked(
        target: URL,
        feature: BackupFeature,
        containerPath: String?,
        bundleID: String?,
        reason: String
    ) throws -> BackupRecord {
        _ = try recordOriginalLocked(
            target: target,
            feature: feature,
            containerPath: containerPath,
            bundleID: bundleID,
            reason: "original before \(reason)"
        )

        let identity = try regularFileIdentity(target)
        let stamp = Self.timestampFormatter.string(from: Date())
        let suffix = String(UUID().uuidString.prefix(8))
        let directory = versionsURL.appendingPathComponent(
            "\(stamp)-\(targetKey(for: target.standardizedFileURL.path))-\(suffix)",
            isDirectory: true
        )
        let payload = directory.appendingPathComponent("payload")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try cloneOrCopy(from: target, to: payload)
        let hash = try hashFile(payload)
        let sourceHash = try hashFile(target)
        guard hash == sourceHash else {
            throw BackupError.backupVerificationFailed("version copy hash mismatch \(target.path)")
        }

        let record = BackupRecord(
            id: UUID(),
            kind: .version,
            feature: feature,
            targetPath: target.standardizedFileURL.path,
            containerPath: containerPath,
            bundleID: bundleID,
            payloadRelativePath: relativePath(of: payload),
            sha256: hash,
            byteCount: identity.size,
            fileDevice: identity.device,
            fileInode: identity.inode,
            createdAt: Date(),
            reason: reason,
            appVersion: Self.appVersion,
            osBuild: Self.osBuild,
            pinned: false
        )
        try writeRecordFile(record, in: directory)
        manifest.records.append(record)
        try saveManifestLocked()
        purgeVersionsLocked()
        return record
    }

    @discardableResult
    func manualBackup(
        target: URL,
        feature: BackupFeature,
        label: String,
        containerPath: String? = nil,
        bundleID: String? = nil
    ) throws -> BackupRecord {
        lock.lock()
        defer { lock.unlock() }

        let identity = try regularFileIdentity(target)
        let stamp = Self.timestampFormatter.string(from: Date())
        let safeLabel = label
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .prefix(48)
        let suffix = String(UUID().uuidString.prefix(8))
        let directory = manualURL.appendingPathComponent(
            "\(stamp)-\(safeLabel)-\(suffix)",
            isDirectory: true
        )
        let payload = directory.appendingPathComponent("payload")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try cloneOrCopy(from: target, to: payload)
        let hash = try hashFile(payload)
        let sourceHash = try hashFile(target)
        guard hash == sourceHash else {
            throw BackupError.backupVerificationFailed("manual copy hash mismatch \(target.path)")
        }

        let record = BackupRecord(
            id: UUID(),
            kind: .manual,
            feature: feature,
            targetPath: target.standardizedFileURL.path,
            containerPath: containerPath,
            bundleID: bundleID,
            payloadRelativePath: relativePath(of: payload),
            sha256: hash,
            byteCount: identity.size,
            fileDevice: identity.device,
            fileInode: identity.inode,
            createdAt: Date(),
            reason: label,
            appVersion: Self.appVersion,
            osBuild: Self.osBuild,
            pinned: false
        )
        try writeRecordFile(record, in: directory)
        manifest.records.append(record)
        try saveManifestLocked()
        return record
    }

    // MARK: Restore / delete / pin

    func restore(_ record: BackupRecord) throws {
        lock.lock()
        defer { lock.unlock() }

        guard manifest.records.contains(where: { $0.id == record.id }) else {
            throw BackupError.recordMissing(record.id.uuidString)
        }
        let payload = record.payloadURL(rootURL: rootURL)
        guard fileManager.fileExists(atPath: payload.path) else {
            throw BackupError.recordMissing(record.id.uuidString)
        }
        let payloadHash = try hashFile(payload)
        guard payloadHash == record.sha256 else {
            throw BackupError.restoreFailed("payload hash mismatch \(record.id.uuidString)")
        }

        let target = URL(fileURLWithPath: record.targetPath)
        if fileManager.fileExists(atPath: target.path) {
            // Make the restore itself undoable before touching the target.
            _ = try createVersionLocked(
                target: target,
                feature: record.feature,
                containerPath: record.containerPath,
                bundleID: record.bundleID,
                reason: "before restore of \(record.id.uuidString.prefix(8))"
            )
        }

        do {
            let data = try Data(contentsOf: payload, options: .mappedIfSafe)
            try writeDataInPlace(data, to: target)
            let writtenHash = try hashFile(target)
            guard writtenHash == record.sha256 else {
                throw BackupError.restoreFailed("restored file hash mismatch \(record.targetPath)")
            }
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.restoreFailed(error.localizedDescription)
        }
    }

    func setPinned(_ pinned: Bool, recordID: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let index = manifest.records.firstIndex(where: { $0.id == recordID }) else {
            throw BackupError.recordMissing(recordID.uuidString)
        }
        manifest.records[index].pinned = pinned
        try saveManifestLocked()
    }

    func delete(_ record: BackupRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        guard record.kind != .original else {
            throw BackupError.originalIsProtected(record.targetPath)
        }
        guard manifest.records.contains(where: { $0.id == record.id }) else {
            throw BackupError.recordMissing(record.id.uuidString)
        }
        let payload = record.payloadURL(rootURL: rootURL)
        let directory = payload.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directory.path) {
            try? fileManager.removeItem(at: directory)
        }
        manifest.records.removeAll { $0.id == record.id }
        try saveManifestLocked()
    }

    // MARK: Journals

    func beginJournal(
        target: URL,
        feature: BackupFeature,
        backupRecordID: UUID,
        reason: String
    ) throws -> UUID {
        let journal = BackupJournal(
            id: UUID(),
            targetPath: target.standardizedFileURL.path,
            feature: feature,
            backupRecordID: backupRecordID,
            createdAt: Date(),
            reason: reason
        )
        do {
            let data = try Self.encoder.encode(journal)
            let url = journalsURL.appendingPathComponent("\(journal.id.uuidString).json")
            try data.write(to: url, options: .atomic)
            return journal.id
        } catch {
            throw BackupError.journalFailed(error.localizedDescription)
        }
    }

    func commitJournal(_ id: UUID) {
        let url = journalsURL.appendingPathComponent("\(id.uuidString).json")
        try? fileManager.removeItem(at: url)
    }

    func pendingJournals() -> [BackupJournal] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: journalsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let journal = try? Self.decoder.decode(BackupJournal.self, from: data) else {
                return nil
            }
            return journal
        }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Restores every unfinished journal's backup. Returns the restored count.
    @discardableResult
    func recoverPendingJournals() -> Int {
        var restored = 0
        for journal in pendingJournals() {
            guard let record = record(id: journal.backupRecordID) else { continue }
            if (try? restore(record)) != nil {
                commitJournal(journal.id)
                restored += 1
            }
        }
        return restored
    }

    // MARK: Writing

    /// Writes in place, preserving the target's inode, owner and xattrs.
    /// Missing targets are created atomically. The caller is responsible for
    /// having a backup when the target already exists.
    func writeDataInPlace(_ data: Data, to target: URL) throws {
        let path = target.standardizedFileURL.path
        var existing = stat()
        let exists = lstat(path, &existing) == 0

        if exists {
            guard (existing.st_mode & S_IFMT) != S_IFLNK else {
                throw BackupError.targetIsSymbolicLink(path)
            }
            guard (existing.st_mode & S_IFMT) == S_IFREG else {
                throw BackupError.targetNotRegularFile(path)
            }

            let descriptor = open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw BackupError.writeFailed("open \(path) errno \(errno)")
            }
            defer { close(descriptor) }

            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  opened.st_dev == existing.st_dev,
                  opened.st_ino == existing.st_ino else {
                throw BackupError.writeFailed("target changed while opening \(path)")
            }

            do {
                try writeAll(data, to: descriptor)
                guard ftruncate(descriptor, off_t(data.count)) == 0 else {
                    throw BackupError.writeFailed("truncate \(path) errno \(errno)")
                }
                guard fsync(descriptor) == 0 else {
                    throw BackupError.writeFailed("fsync \(path) errno \(errno)")
                }
            } catch let error as BackupError {
                throw error
            } catch {
                throw BackupError.writeFailed(error.localizedDescription)
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: target, options: .atomic)
            } catch {
                throw BackupError.writeFailed(error.localizedDescription)
            }
        }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let written = write(descriptor, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw BackupError.writeFailed("write errno \(errno)")
                }
                if written == 0 {
                    throw BackupError.writeFailed("write returned 0")
                }
                offset += written
            }
        }
    }

    // MARK: Internals

    struct FileIdentity {
        let device: UInt64
        let inode: UInt64
        let size: Int64
    }

    private func regularFileIdentity(_ url: URL) throws -> FileIdentity {
        let path = url.standardizedFileURL.path
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw BackupError.targetMissing(path)
        }
        guard (info.st_mode & S_IFMT) != S_IFLNK else {
            throw BackupError.targetIsSymbolicLink(path)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw BackupError.targetNotRegularFile(path)
        }
        return FileIdentity(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size)
        )
    }

    private func targetKey(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    private func relativePath(of url: URL) -> String {
        let root = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }

    private func cloneOrCopy(from source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        var cloned = false
        source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return }
                cloned = clonefile(sourcePath, destinationPath, 0) == 0
            }
        }
        if !cloned {
            do {
                try fileManager.copyItem(at: source, to: destination)
            } catch {
                throw BackupError.backupFailed(error.localizedDescription)
            }
        }
    }

    func hashFile(_ url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw BackupError.backupFailed("open \(url.path): \(error.localizedDescription)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                hasher.update(data: data)
            }
        } catch {
            throw BackupError.backupFailed("read \(url.path): \(error.localizedDescription)")
        }
        return hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
    }

    static func hashData(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func writeRecordFile(_ record: BackupRecord, in directory: URL) throws {
        do {
            let data = try Self.encoder.encode(record)
            try data.write(
                to: directory.appendingPathComponent("record.json"),
                options: .atomic
            )
        } catch {
            throw BackupError.backupFailed("write record: \(error.localizedDescription)")
        }
    }

    private func loadManifest() {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? Self.decoder.decode(BackupManifest.self, from: data) else {
            manifest = .empty
            return
        }
        manifest = decoded
    }

    private func saveManifestLocked() throws {
        do {
            let data = try Self.encoder.encode(manifest)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            throw BackupError.backupFailed("write manifest: \(error.localizedDescription)")
        }
    }

    private func purgeVersionsLocked() {
        let versions = manifest.records
            .filter { $0.kind == .version }
            .sorted { $0.createdAt > $1.createdAt }
        var keptPerTarget: [String: Int] = [:]
        var removal: [BackupRecord] = []
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)

        for record in versions {
            guard !record.pinned else { continue }
            let key = "\(record.feature.rawValue)|\(record.targetPath)"
            let count = keptPerTarget[key, default: 0]
            let expired = record.createdAt < cutoff
            if count >= 20 || expired {
                removal.append(record)
            } else {
                keptPerTarget[key] = count + 1
            }
        }
        guard !removal.isEmpty else { return }
        for record in removal {
            let directory = record.payloadURL(rootURL: rootURL).deletingLastPathComponent()
            try? fileManager.removeItem(at: directory)
        }
        let ids = Set(removal.map(\.id))
        manifest.records.removeAll { ids.contains($0.id) }
        try? saveManifestLocked()
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

// MARK: - Verified writer

enum VerifiedFileWriter {
    /// Backs up the current file, writes the new bytes in place, verifies them,
    /// and returns the pre-write version. Throws before writing if the backup
    /// cannot be created.
    @discardableResult
    static func write(
        _ data: Data,
        to target: URL,
        feature: BackupFeature,
        reason: String,
        containerPath: String? = nil,
        bundleID: String? = nil,
        center: BackupCenter = .shared
    ) throws -> BackupRecord? {
        let targetPath = target.standardizedFileURL.path
        var info = stat()
        let exists = lstat(targetPath, &info) == 0

        var version: BackupRecord?
        if exists {
            guard (info.st_mode & S_IFMT) != S_IFLNK else {
                throw BackupError.targetIsSymbolicLink(targetPath)
            }
            guard (info.st_mode & S_IFMT) == S_IFREG else {
                throw BackupError.targetNotRegularFile(targetPath)
            }
            version = try center.createVersionSnapshot(
                target: target,
                feature: feature,
                containerPath: containerPath,
                bundleID: bundleID,
                reason: reason
            )
        }

        let journalID: UUID?
        if let version {
            journalID = try center.beginJournal(
                target: target,
                feature: feature,
                backupRecordID: version.id,
                reason: reason
            )
        } else {
            journalID = nil
        }

        do {
            try center.writeDataInPlace(data, to: target)
            let written = try center.hashFile(target)
            let expected = BackupCenter.hashData(data)
            guard written == expected else {
                throw BackupError.readBackMismatch(targetPath)
            }
            if let journalID { center.commitJournal(journalID) }
            return version
        } catch {
            if let version {
                do {
                    try center.restore(version)
                    if let journalID { center.commitJournal(journalID) }
                } catch {
                    // Keep the journal so the next launch can offer recovery.
                }
            } else if let journalID {
                center.commitJournal(journalID)
            }
            throw error
        }
    }
}