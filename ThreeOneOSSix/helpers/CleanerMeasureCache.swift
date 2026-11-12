import Foundation
import Darwin

/// Incremental size cache for cleaner measurements (WQManager WQMAppCache
/// parity): keyed by container path, storing per-relative-directory
/// (mtime, bytes, files). When a directory's modification date is unchanged
/// since the last full walk, its cached total is reused instead of
/// re-enumerating thousands of files.
enum CleanerMeasureCache {

    struct Entry: Equatable {
        var directoryMTime: Date
        var bytes: Int64
        var files: Int
    }

    private static let fileName = "cleaner-measure-cache.plist"
    private static let queue = DispatchQueue(label: "cleaner.measure.cache")
    private static var cachedStore: [String: [String: Entry]]?

    private static var fileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(fileName)
    }

    private static func loadStore() -> [String: [String: Entry]] {
        if let cachedStore { return cachedStore }
        guard
            let data = try? Data(contentsOf: fileURL),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [String: [String: [String: Any]]]
        else {
            cachedStore = [:]
            return [:]
        }
        var decoded: [String: [String: Entry]] = [:]
        for (container, relatives) in plist {
            var entries: [String: Entry] = [:]
            for (relative, raw) in relatives {
                guard
                    let mtime = raw["mtime"] as? Date,
                    let bytes = raw["bytes"] as? Int64,
                    let files = raw["files"] as? Int
                else { continue }
                entries[relative] = Entry(directoryMTime: mtime, bytes: bytes, files: files)
            }
            decoded[container] = entries
        }
        cachedStore = decoded
        return decoded
    }

    private static func persist(_ store: [String: [String: Entry]]) {
        let plist: [String: [String: [String: Any]]] = store.mapValues { relatives in
            relatives.mapValues { entry in
                [
                    "mtime": entry.directoryMTime,
                    "bytes": entry.bytes,
                    "files": entry.files,
                ] as [String: Any]
            }
        }
        guard
            let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .binary, options: 0
            )
        else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Current mtime of a directory, nil when it does not exist. Uses full
    /// nanosecond precision: truncating to whole seconds makes two distinct
    /// directory states within the same wall-clock second indistinguishable
    /// (a clean + immediate repopulation would serve stale 0 bytes).
    static func directoryMTime(atPath path: String) -> Date? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000.0
        )
    }

    /// Returns the cached usage when the directory mtime matches; nil on any
    /// mismatch (caller must do a fresh walk and call `store`). A directory
    /// that no longer exists reports a zeroed usage so callers drop the record.
    static func cachedUsage(
        containerPath: String,
        relativePath: String
    ) -> LimitedCleanerUsage? {
        queue.sync {
            let absolute = (containerPath as NSString).appendingPathComponent(relativePath)
            guard let mtime = directoryMTime(atPath: absolute) else {
                return LimitedCleanerUsage(cacheBytes: 0, temporaryBytes: 0, removableItemCount: 0)
            }
            guard
                let entry = loadStore()[containerPath]?[relativePath],
                entry.directoryMTime == mtime
            else { return nil }
            let cacheBytes = relativePath == "Library/Caches" ? entry.bytes : 0
            let tmpBytes = relativePath == "tmp" ? entry.bytes : 0
            return LimitedCleanerUsage(
                cacheBytes: cacheBytes,
                temporaryBytes: tmpBytes,
                removableItemCount: entry.files
            )
        }
    }

    static func store(
        containerPath: String,
        relativePath: String,
        bytes: Int64,
        files: Int,
        directoryMTime preWalkMTime: Date?
    ) {
        guard let preWalkMTime else { return }
        queue.sync {
            var store = loadStore()
            var relatives = store[containerPath] ?? [:]
            relatives[relativePath] = Entry(
                directoryMTime: preWalkMTime, bytes: bytes, files: files
            )
            store[containerPath] = relatives
            cachedStore = store
            // Deferred persist re-reads the LATEST in-memory store at fire
            // time (all mutations run on this same queue, so this block
            // serializes with them). Persisting the snapshot captured at
            // enqueue time used to resurrect entries that removeAll/
            // clearAll deleted inside the 2-second window.
            queue.asyncAfter(deadline: .now() + 2.0) {
                persist(cachedStore ?? [:])
            }
        }
    }

    static func removeAll(underContainerPath containerPath: String) {
        queue.sync {
            var store = loadStore()
            store.removeValue(forKey: containerPath)
            cachedStore = store
            persist(store)
        }
    }

    static func clearAll() {
        queue.sync {
            cachedStore = [:]
            persist([:])
        }
    }
}
