import Foundation
import Darwin

/// Defense-in-depth safety layer for the limited cleaner, ported from
/// WQManager's WQMSafetyPolicy + WQCacheSafety design:
/// - protected absolute-path blacklist (component-prefix matching, so
///   "/var/db2" can never satisfy a "/var/db" prefix check)
/// - (st_dev, st_ino) identity snapshots taken at scan time and re-validated
///   right before deletion (TOCTOU protection)
/// - a three-stage confirmation gate bound to a per-operation identifier.
///
/// The per-app relative allowlist (`Library/Caches`, `tmp`) still lives in
/// `LimitedCleanerService.allowedRelativeDirectories` and is unchanged; this
/// policy only hardens what may pass through it.
enum CleanerSafetyPolicy {

    // MARK: - Protected absolute paths

    /// Absolute paths that must never be touched by the cleaner, even if a
    /// container root check somehow passes. Component-prefix matched.
    static let protectedAbsolutePaths: [String] = [
        "/var/db",
        "/private/var/db",
        "/var/MobileAsset",
        "/private/var/MobileAsset",
        "/var/db/uuidtext",
        "/private/var/db/uuidtext",
        "/var/mobile/Library/Caches",
        "/private/var/mobile/Library/Caches",
        "/var/mobile/Library/Safari",
        "/private/var/mobile/Library/Safari",
        "/private/var/containers/Data/System",
        "/private/var/containers/Shared/SystemGroup",
        "/private/var/mobile/Containers/Data/InternalDaemon",
        "/var/containers/Data/System",
        "/var/containers/Shared/SystemGroup",
        "/var/mobile/Containers/Data/InternalDaemon",
    ]

    /// Bundle IDs the cleaner must never select or clean (port of Erosion's
    /// protectedBundleIDs, extended for 3106).
    static let protectedBundleIDs: Set<String> = [
        "com.qingtang.3106",
        "com.apple.springboard",
        "com.apple.Preferences",
        "com.apple.mobilephone",
        "com.apple.PosterBoard",
        "com.apple.mobileslideshow",
        "com.apple.WebKit.WebContent",
    ]

    // MARK: - Path checks

    private static func hasComponentPrefix(path: String, prefix: String) -> Bool {
        if path == prefix { return true }
        return path.hasPrefix(prefix + "/")
    }

    /// Normalize with the filesystem's canonical spelling where possible so
    /// "/var" vs "/private/var" aliases compare correctly.
    private static func canonicalize(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(standardized, &resolved) != nil {
            return String(cString: resolved)
        }
        // Missing final component is fine for a planned (not yet existing)
        // target; standardizing the parent keeps alias detection mostly right.
        return standardized
    }

    /// True when the path (or any ancestor) is in the protected list. Refuses
    /// relative paths, "/" itself, and any component named "." or "..".
    /// Traversal components are checked on the RAW path first: canonicalizing
    /// before the check would silently resolve them away.
    static func isProtectedSystemPath(_ rawPath: String) -> Bool {
        guard rawPath.hasPrefix("/"), rawPath != "/" else { return true }
        let rawComponents = rawPath.split(separator: "/").map(String.init)
        if rawComponents.isEmpty { return true }
        if rawComponents.contains(".") || rawComponents.contains("..") { return true }

        let path = canonicalize(rawPath)
        let components = path.split(separator: "/").map(String.init)
        if components.isEmpty { return true }

        var prefix = ""
        for component in components {
            prefix += "/" + component
            for protectedPath in protectedAbsolutePaths {
                if hasComponentPrefix(path: prefix, prefix: protectedPath) {
                    return true
                }
            }
        }
        return false
    }

    /// True when the bundle is excluded from cleaning regardless of state.
    static func isProtectedBundle(_ bundleID: String) -> Bool {
        protectedBundleIDs.contains(bundleID)
    }

    /// A planned cleanup target: relative allowlist entry inside a container.
    struct PlannedTarget {
        let containerRoot: String
        let relativePath: String
        let absolutePath: String

        static func build(
            containerRoot: String,
            relativePath: String
        ) -> PlannedTarget? {
            let root = (containerRoot as NSString).standardizingPath
            guard root.hasPrefix("/"), root != "/" else { return nil }
            let components = relativePath.split(separator: "/").map(String.init)
            guard !components.isEmpty,
                  !components.contains("."),
                  !components.contains("..") else { return nil }
            let absolute = components.reduce(root) {
                ($0 as NSString).appendingPathComponent($1)
            }
            guard absolute.hasPrefix(root + "/") else { return nil }
            return PlannedTarget(
                containerRoot: root,
                relativePath: relativePath,
                absolutePath: absolute
            )
        }
    }

    enum TargetCheckResult: Equatable {
        case allowed
        case rejected(reason: TargetRejectReason)
    }

    enum TargetRejectReason: Equatable {
        case protectedSystemPath
        case symlinkEscapesContainer
        case identityChanged
        case malformedPath
    }

    /// Full pre-clean validation of one planned target. Runs the blacklist,
    /// then verifies (via lstat, no symlinks followed) that every existing
    /// component of the path stays inside the container root.
    static func checkTarget(
        _ target: PlannedTarget,
        snapshot: FileIdentitySnapshot?
    ) -> TargetCheckResult {
        guard target.absolutePath.hasPrefix("/"),
              target.absolutePath.hasPrefix(target.containerRoot + "/") else {
            return .rejected(reason: .malformedPath)
        }
        if isProtectedSystemPath(target.absolutePath) {
            return .rejected(reason: .protectedSystemPath)
        }

        // Walk every component without following symlinks. `Library/Caches`
        // is frequently a symlink INSIDE the container; that is allowed, but
        // only when the resolved destination stays within the container root.
        let components = target.absolutePath.split(separator: "/").map(String.init)
        var prefix = ""
        for component in components {
            prefix += "/" + component
            var st = stat()
            if lstat(prefix, &st) != 0 {
                // Missing final component is acceptable (nothing to clean).
                if errno == ENOENT && prefix == target.absolutePath { continue }
                return .rejected(reason: .malformedPath)
            }
            if (st.st_mode & S_IFMT) == S_IFLNK {
                let resolved = (prefix as NSString).resolvingSymlinksInPath
                if !resolved.hasPrefix(target.containerRoot + "/") {
                    return .rejected(reason: .symlinkEscapesContainer)
                }
            }
        }

        if let snapshot,
           !snapshot.matchesCurrentPath(target.absolutePath) {
            return .rejected(reason: .identityChanged)
        }
        return .allowed
    }

    // MARK: - Identity snapshots (TOCTOU protection)

    struct FileIdentitySnapshot: Equatable {
        let device: dev_t
        let inode: ino_t
        let existed: Bool

        static func capture(atPath path: String) -> FileIdentitySnapshot {
            var st = stat()
            if lstat(path, &st) == 0 {
                return FileIdentitySnapshot(
                    device: st.st_dev, inode: st.st_ino, existed: true
                )
            }
            return FileIdentitySnapshot(device: 0, inode: 0, existed: false)
        }

        /// Re-stat and compare identity. A file that existed at scan time
        /// must keep the same (dev, ino) to be touched now; a file that was
        /// missing at scan time must still be missing (or, if it appeared,
        /// it is treated as changed and skipped).
        func matchesCurrentPath(_ path: String) -> Bool {
            var st = stat()
            let ok = lstat(path, &st) == 0
            if !existed { return !ok }
            guard ok else { return false }
            return st.st_dev == device && st.st_ino == inode
        }
    }

    // MARK: - Three-stage confirmation gate

    /// Port of WQManager's WQMConfirmationGate: cleaning may only run after
    /// an explicit scope acknowledgement followed by authorization, both
    /// bound to the same operation identifier, in order. Out-of-order or
    /// cross-operation calls are rejected, so a UI cannot accidentally skip
    /// the confirmation sheet.
    final class ConfirmationGate {
        enum Stage: Equatable {
            case idle
            case scopeAcknowledged
            case authorized
        }

        private let lock = NSLock()
        private var operationID: String?
        private var stage: Stage = .idle

        func begin(operationID: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard stage == .idle else { return false }
            self.operationID = operationID
            stage = .scopeAcknowledged
            return true
        }

        func acknowledgeScope(operationID: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard stage == .scopeAcknowledged,
                  self.operationID == operationID else { return false }
            stage = .authorized
            return true
        }

        func authorize(operationID: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard stage == .authorized,
                  self.operationID == operationID else { return false }
            return true
        }

        func finish(operationID: String) {
            lock.lock(); defer { lock.unlock() }
            guard self.operationID == operationID else { return }
            self.operationID = nil
            stage = .idle
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            self.operationID = nil
            stage = .idle
        }
    }
}
