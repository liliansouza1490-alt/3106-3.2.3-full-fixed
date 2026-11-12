import Foundation

struct CrashLogSummary: Equatable {
    let fileCount: Int
    let bytes: Int64
}

struct CrashLogCleanResult: Equatable {
    let removed: Int
    let failed: Int
    let freedBytes: Int64
}

/// Removes only crash/panic/diagnostic log files under known user log
/// directories. Symlinks and anything outside those roots are refused.
enum CrashLogCleaner {
    static let rootPath = "/private/var/mobile/Library/Logs/CrashReporter"
    private static let allowedExtensions: Set<String> = [
        "ips", "crash", "panic", "log", "synced", "diag",
    ]
    private static let maximumFiles = 10_000

    static func scan() -> CrashLogSummary {
        let url = URL(fileURLWithPath: rootPath, isDirectory: true)
        let grant = ContainerStore.grantContainerAccess(rootPath)
        defer {
            if grant >= 0 { SandboxAccess.release(grant) }
        }
        guard FileManager.default.fileExists(atPath: rootPath) else {
            return CrashLogSummary(fileCount: 0, bytes: 0)
        }
        var count = 0
        var bytes: Int64 = 0
        for file in files(under: url) {
            count += 1
            bytes += file.size
            if count >= maximumFiles { break }
        }
        return CrashLogSummary(fileCount: count, bytes: bytes)
    }

    static func clean() -> CrashLogCleanResult {
        let url = URL(fileURLWithPath: rootPath, isDirectory: true)
        let grant = ContainerStore.grantContainerAccess(rootPath)
        defer {
            if grant >= 0 { SandboxAccess.release(grant) }
        }
        guard FileManager.default.fileExists(atPath: rootPath) else {
            return CrashLogCleanResult(removed: 0, failed: 0, freedBytes: 0)
        }
        var removed = 0
        var failed = 0
        var freed: Int64 = 0
        for file in files(under: url) {
            guard file.url.standardizedFileURL.path.hasPrefix(
                url.standardizedFileURL.path + "/"
            ) else {
                failed += 1
                continue
            }
            do {
                try FileManager.default.removeItem(at: file.url)
                removed += 1
                freed += file.size
            } catch {
                failed += 1
            }
        }
        return CrashLogCleanResult(removed: removed, failed: failed, freedBytes: freed)
    }

    private struct CrashLogFile {
        let url: URL
        let size: Int64
    }

    private static func files(under root: URL) -> [CrashLogFile] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [CrashLogFile] = []
        for case let url as URL in enumerator {
            guard allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ]) else { continue }
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            result.append(CrashLogFile(
                url: url,
                size: Int64(values.fileSize ?? 0)
            ))
            if result.count >= maximumFiles { break }
        }
        return result
    }
}