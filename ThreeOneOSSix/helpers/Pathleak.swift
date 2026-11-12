import Foundation
import Darwin

/// Cooperative cancellation shared by long container/file scans.
final class ScanToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Fast arbitrary-path directory enumeration by brute-forcing inodes and
/// resolving them with `fsgetpath`. Ported from forcequitOS/worse_query's
/// `pathleak.m` (GPL-3.0-or-later); see NOTICE.md.
enum Pathleak {
    /// Dynamically probe the filesystem's live maximum inode (Erosion-CN
    /// parity): stat() downward from an optimistic ceiling in coarse steps,
    /// then refine. The first hit is an upper bound for the brute-force
    /// range, cutting the fixed 2,000,000 sweep down to roughly the real
    /// allocation watermark — typically a 2-4x faster full scan.
    static func dynamicMaxInode(
        directory: String,
        ceiling: UInt64 = 2_000_000,
        token: ScanToken? = nil
    ) -> UInt64 {
        var fsid: fsid_t
        var filesystem = statfs()
        if statfs(directory, &filesystem) == 0 {
            fsid = filesystem.f_fsid
        } else if statfs("/private/var", &filesystem) == 0 {
            fsid = filesystem.f_fsid
        } else {
            return ceiling
        }

        func exists(_ inode: UInt64) -> Bool {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            return buffer.withUnsafeMutableBufferPointer { pointer in
                fsgetpath(pointer.baseAddress, pointer.count, &fsid, inode) > 0
            }
        }

        // Coarse pass: step down in 8,192-inode blocks.
        let coarseStep: UInt64 = 8_192
        var probe = ceiling
        while probe > coarseStep {
            if token?.isCancelled == true { return ceiling }
            if exists(probe) { break }
            probe &-= coarseStep
        }
        if probe <= coarseStep {
            // Nothing found in the coarse sweep; keep the full range rather
            // than risk missing containers.
            return ceiling
        }

        // Fine pass: probe upward from the coarse hit one inode at a time
        // (bounded by one coarse step) so the returned watermark is the TRUE
        // highest allocated inode. A 256-grid sampling used to under-estimate
        // by up to 255 and silently cut containers off the sweep.
        let fineCeiling = min(ceiling, probe &+ coarseStep)
        var fine = probe
        var cursor = probe &+ 1
        while cursor <= fineCeiling {
            if exists(cursor) {
                fine = cursor
            } else if cursor &- fine > 4096 {
                // 4096 consecutive misses after the last hit: the watermark
                // is almost certainly `fine`; stop to keep the probe cheap.
                break
            }
            cursor &+= 1
        }
        return fine
    }

    static func list(
        directory: String,
        maxInode: UInt64 = 2_000_000,
        startInode: UInt64 = 1,
        token: ScanToken? = nil,
        progress: ((Int64, Int64) -> Void)? = nil
    ) -> [String] {
        var dir = directory
        while dir.count > 1 && dir.hasSuffix("/") {
            dir.removeLast()
        }
        guard !dir.isEmpty else { return [] }

        var filesystem = statfs()
        if statfs(dir, &filesystem) != 0 {
            if statfs("/private/var", &filesystem) != 0,
               statfs("/var", &filesystem) != 0 {
                return []
            }
        }
        var fsid = filesystem.f_fsid

        var prefix = dir
        if prefix.hasPrefix("/private/") {
            prefix.removeFirst("/private".count)
        }

        guard startInode >= 1, maxInode >= startInode else { return [] }
        let total = Int64(maxInode - startInode + 1)
        var result: [String] = []
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        var inode = startInode

        while inode <= maxInode {
            if token?.isCancelled == true { break }

            let length = buffer.withUnsafeMutableBufferPointer { pointer in
                fsgetpath(pointer.baseAddress, pointer.count, &fsid, inode)
            }
            if length > 0 {
                var path = buffer.withUnsafeBufferPointer { pointer in
                    String(cString: pointer.baseAddress!)
                }
                if path.hasPrefix("/private/") {
                    path.removeFirst("/private".count)
                }
                if path.hasPrefix(prefix) {
                    let rest = path.dropFirst(prefix.count)
                    if rest.first == "/", !rest.dropFirst().contains("/") {
                        result.append(path)
                    }
                }
            }

            if let progress, inode % 4_096 == 0 || inode == maxInode {
                progress(Int64(inode - startInode + 1), total)
            }
            inode &+= 1
        }

        if let progress {
            let done = Int64(min(inode, maxInode) - startInode + 1)
            progress(max(0, done), total)
        }
        return result
    }
}