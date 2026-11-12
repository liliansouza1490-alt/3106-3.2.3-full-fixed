import Foundation

/// The container-access backend selected for the running OS.
///
/// - `kernel`: iOS 17/18 kernel exploit chain (unchanged from 3105).
/// - `badQuery`: the original bad_query grant for iOS 26.0–26.6.1 (fallback when no App Group).
/// - `worseQuery`: worse_query sandbox escape for iOS 26.0–26.7.2 and 27.0–27.3.
enum SandboxBackend: String {
    case kernel
    case badQuery
    case worseQuery
    case unsupported

    var displayName: String {
        switch self {
        case .kernel: return "kernel"
        case .badQuery: return "bad_query"
        case .worseQuery: return "worse_query"
        case .unsupported: return "unsupported"
        }
    }
}

/// One place for every sandbox grant. Callers keep treating the return value as
/// an opaque `Int64` handle, so the rest of the app did not need to change.
enum SandboxAccess {
    static var backend: SandboxBackend {
        let v = AppInfo.versionTuple
        if ExploitSupportPolicy.supportsKernelExploit(major: v.major, minor: v.minor, patch: v.patch) {
            return .kernel
        }
        if ExploitSupportPolicy.supportsWorseQuery(major: v.major, minor: v.minor, patch: v.patch) ||
            ExploitSupportPolicy.isExperimental(major: v.major, minor: v.minor) {
            return .worseQuery
        }
        if ExploitSupportPolicy.supportsBadQuery(major: v.major, minor: v.minor, patch: v.patch) {
            return .badQuery
        }
        return .unsupported
    }

    static var appGroup: String? {
        worse_query_app_group()
    }

    static var hasAppGroup: Bool { appGroup != nil }

    /// Last successful probe result. Cleared on forget / failed grant.
    private static var _probeOK: Bool?
    private static let _probeLock = NSLock()

    static var lastProbeSucceeded: Bool {
        _probeLock.lock()
        defer { _probeLock.unlock() }
        return _probeOK == true
    }

    static func markProbe(_ ok: Bool) {
        _probeLock.lock()
        _probeOK = ok
        _probeLock.unlock()
    }

    static var needsWorseQuery: Bool { backend == .worseQuery }

    /// System Data and System Groups are only reachable through worse_query on
    /// iOS 27; iOS 26 (either backend) and the kernel path keep their old
    /// visibility rules.
    static var systemAreasReachable: Bool {
        switch backend {
        case .kernel, .badQuery:
            return true
        case .worseQuery:
            return AppInfo.versionTuple.major >= 27
        case .unsupported:
            return false
        }
    }

    /// True when the current backend can reach Shared/SystemGroup containers
    /// (MobileGestalt cache, ConfigurationProfiles → Supervised Mode, …).
    /// Only worse_query grants those on iOS 26.7+; the bad_query backend
    /// (iOS 26.0–26.6.1) covers app/daemon/group containers only, and the
    /// kernel backend reaches whatever the kernel permits but historically
    /// the 3105 lineage used it without SystemGroup writes.
    static var systemGroupWritable: Bool {
        // kernel (iOS 17/18) escapes the sandbox entirely and reaches system
        // groups; worse_query grants them on 26.7+/27. Only bad_query
        // (26.0-26.6.1) cannot.
        backend == .worseQuery || backend == .kernel
    }

    /// True when worse_query's App-Group technique is REQUIRED but the
    /// device cannot run it (e.g. iOS 26.0–26.6.1 on bad_query, or a
    /// missing App Group entitlement).
    static var systemGroupFeaturesUnavailable: Bool {
        !systemGroupWritable
    }

    /// System Groups' parent cannot be listed on 27.0.1; callers fall back to
    /// probing known container names.
    static var systemGroupParentListable: Bool {
        let v = AppInfo.versionTuple
        return !(v.major == 27 && v.minor == 0 && v.patch == 1)
    }

    /// Heals an interrupted Caches swap. Called once at launch.
    static func prepare() {
        guard backend == .worseQuery else { return }
        if !worse_query_recover() {
            log("sandbox: worse_query recovery skipped or needs attention")
        }
    }

    /// A lightweight activation probe used by the UI. It verifies the App Group
    /// exists for worse_query, and that the previous grant path is usable for
    /// bad_query.
    static func probe() -> Bool {
        switch backend {
        case .kernel:
            let ok = KernelExploit.hasKernelSandboxAccess()
            markProbe(ok)
            return ok
        case .badQuery:
            let handle = grant(path: ContainerStore.appDataRoot)
            if handle >= 0 {
                release(handle)
                markProbe(true)
                return true
            }
            markProbe(false)
            return false
        case .worseQuery:
            guard let group = appGroup,
                  let groupURL = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: group
                  ) else {
                log("sandbox: no App Group entitlement — worse_query cannot run")
                markProbe(false)
                return false
            }
            // Try the paths the browser + patch inject actually need, in order.
            // Works for iOS 26.0–26.7.2 and 27.0–27.3.
            let candidates = [
                ContainerStore.appDataRoot,
                groupURL.path,
                "/var/mobile/Containers/Shared/AppGroup",
                "/var/mobile/Containers/Data/InternalDaemon",
            ]
            var ok = false
            for path in candidates {
                let handle = grant(path: path)
                if handle >= 0 {
                    log("sandbox: worse_query probe OK on \(path)")
                    // Keep the root grant cached; release only non-root probes
                    // so subsequent enumerate/list can reuse the token.
                    if path != ContainerStore.appDataRoot {
                        release(handle)
                    }
                    ok = true
                    break
                }
            }
            if ok {
                // Warm path↔identifier index (needed on 26.7+/27.x when
                // metadata plists / xattrs are unreadable).
                _ = worse_query_path_identifiers()
                markProbe(true)
                return true
            }
            log("sandbox: worse_query probe failed on all candidate paths")
            markProbe(false)
            return false
        case .unsupported:
            markProbe(false)
            return false
        }
    }

    static func grant(path: String) -> Int64 {
        let clean = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        switch backend {
        case .kernel:
            return -1
        case .badQuery:
            var pathC = clean.utf8CString.map { Int8($0) }
            return bad_query(&pathC, true, nil, false)
        case .worseQuery:
            var pathC = clean.utf8CString.map { Int8($0) }
            let handle = worse_query_grant(&pathC)
            if handle >= 0 { return handle }
            // On 26.0–26.6.1, if worse_query fails (e.g. App Group flake),
            // fall back to bad_query when the policy still allows it.
            let v = AppInfo.versionTuple
            if ExploitSupportPolicy.supportsBadQuery(major: v.major, minor: v.minor, patch: v.patch) {
                var pathB = clean.utf8CString.map { Int8($0) }
                let fallback = bad_query(&pathB, true, nil, false)
                if fallback >= 0 {
                    log("sandbox: worse_query miss, bad_query fallback OK for \(clean)")
                }
                return fallback
            }
            return handle
        case .unsupported:
            return -1
        }
    }

    static func release(_ handle: Int64) {
        guard handle >= 0 else { return }
        switch backend {
        case .kernel:
            break
        case .badQuery:
            bad_query_release(handle)
        case .worseQuery:
            worse_query_release(handle)
        case .unsupported:
            break
        }
    }
}