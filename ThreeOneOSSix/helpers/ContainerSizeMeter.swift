import Foundation
import Darwin

/// Total-size measurement for app data containers, shown in the file browser
/// (WQManager AppScanner parity): budgeted walk (stops after N entries or T
/// seconds), session-level memoization keyed by (path, container mtime), and
/// a bounded parallel pool so a device with 200+ apps still finishes fast.
enum ContainerSizeMeter {

    private struct Memo {
        let directoryMTime: Date
        let bytes: Int64
    }

    /// Entries walked before the budget check kicks in; between checks the
    /// loop only accumulates, so this granularity bounds overshoot.
    private static let budgetEntries = 12_000
    private static let budgetSeconds: TimeInterval = 0.5
    private static let maxConcurrent = 6

    private static let lock = NSLock()
    private static var memo: [String: Memo] = [:]

    /// Measure one container's total bytes. Returns the memoized value when
    /// the container directory mtime is unchanged; nil when the walk hit the
    /// budget (caller keeps the previous display value). mtime is sampled
    /// BEFORE the walk at full nanosecond precision, so a write that lands
    /// mid-walk forces a memo miss on the next call instead of being bound
    /// to bytes that never included it.
    static func measureTotal(containerPath: String) -> Int64? {
        var st = stat()
        guard lstat(containerPath, &st) == 0 else { return nil }
        let mtime = Date(
            timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000.0
        )

        lock.lock()
        if let hit = memo[containerPath], hit.directoryMTime == mtime {
            lock.unlock()
            return hit.bytes
        }
        lock.unlock()

        let grant = ContainerStore.grantContainerAccess(containerPath)
        defer { SandboxAccess.release(grant) }

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: containerPath, isDirectory: true),
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else { return nil }

        var bytes: Int64 = 0
        var visited = 0
        let startedAt = Date()
        var exhausted = false

        for case let item as URL in enumerator {
            visited += 1
            if visited % 512 == 0 {
                if visited >= budgetEntries
                    || Date().timeIntervalSince(startedAt) >= budgetSeconds {
                    exhausted = true
                    break
                }
            }
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true else { continue }
            bytes += max(0, Int64(values?.fileSize ?? 0))
        }

        if exhausted {
            log("size-meter: budget hit \(containerPath) visited=\(visited) partial=\(bytes)")
            return nil
        }

        lock.lock()
        memo[containerPath] = Memo(directoryMTime: mtime, bytes: bytes)
        lock.unlock()
        return bytes
    }

    /// Measure many containers in parallel; reports progress in batches so
    /// the UI can refresh without one publish per app.
    static func measureBatch(
        _ containerPaths: [String],
        progress: @escaping (_ index: Int, _ path: String, _ bytes: Int64?) -> Void,
        completion: @escaping () -> Void
    ) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = maxConcurrent
        let progressLock = NSLock()
        var finished = 0
        let total = containerPaths.count

        for (index, path) in containerPaths.enumerated() {
            queue.addOperation {
                let bytes = measureTotal(containerPath: path)
                progressLock.lock()
                finished += 1
                let done = finished
                progressLock.unlock()
                progress(index, path, bytes)
                if done == total {
                    completion()
                }
            }
        }
    }
}
