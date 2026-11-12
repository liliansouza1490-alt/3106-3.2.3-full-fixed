import Foundation
import Darwin

struct LimitedCleanerUsage: Equatable {
    let cacheBytes: Int64
    let temporaryBytes: Int64
    let removableItemCount: Int

    static let empty = LimitedCleanerUsage(
        cacheBytes: 0,
        temporaryBytes: 0,
        removableItemCount: 0
    )

    var totalBytes: Int64 {
        cacheBytes + temporaryBytes
    }
}

struct LimitedCleanerResult: Equatable {
    let before: LimitedCleanerUsage
    let after: LimitedCleanerUsage
    let removedItemCount: Int
    let failedItemCount: Int

    var freedBytes: Int64 {
        max(0, before.totalBytes - after.totalBytes)
    }
}

enum LimitedCleanerError: Error, Equatable {
    case unsafeContainerRoot
}

enum LimitedCleanerService {
    typealias ContainerRootValidator = (URL) -> Bool

    /// This explicit allowlist is the product boundary. Do not add global `/var`
    /// paths here: this cleaner is intentionally limited to per-app disposable data.
    static let allowedRelativeDirectories = ["Library/Caches", "tmp"]

    /// Budgeted-walk limits (WQManager parity): a single relative directory
    /// walk stops after this many entries or this many seconds, whichever
    /// comes first, and reports what it measured so far. Oversized apps get a
    /// partial (understated) size on first pass; the mtime-keyed incremental
    /// cache finishes catching up on later passes without blocking the list.
    static let measureBudgetEntries = 12_000
    static let measureBudgetSeconds: TimeInterval = 0.25

    /// Result of a budgeted walk: totals plus whether the budget ran out.
    struct BudgetedMeasure {
        let bytes: Int64
        let files: Int
        let budgetExhausted: Bool
    }

    static func scan(
        containerURL: URL,
        rootValidator: ContainerRootValidator
    ) throws -> LimitedCleanerUsage {
        let root = containerURL.standardizedFileURL
        guard root.path.hasPrefix("/"),
              root.path != "/",
              rootValidator(root) else {
            throw LimitedCleanerError.unsafeContainerRoot
        }

        let containerGrant = ContainerStore.grantContainerAccess(root.path)
        defer { SandboxAccess.release(containerGrant) }
        var targetGrants: [Int64] = []
        defer {
            for targetGrant in targetGrants { SandboxAccess.release(targetGrant) }
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isDirectoryKey
        ]

        // Budgeted walk (WQManager parity): stop after the entry or time
        // budget so one huge app cannot stall the whole list. The result is
        // cached keyed by directory mtime; a changed directory re-walks.
        func measure(_ relative: String) -> BudgetedMeasure {
            if let cached = CleanerMeasureCache.cachedUsage(
                containerPath: root.path,
                relativePath: relative
            ) {
                let bytes = relative == "Library/Caches"
                    ? cached.cacheBytes : cached.temporaryBytes
                return BudgetedMeasure(
                    bytes: bytes, files: cached.removableItemCount,
                    budgetExhausted: false
                )
            }

            let url = relative.split(separator: "/").reduce(root) { current, part in
                current.appendingPathComponent(String(part), isDirectory: true)
            }
            let grant = ContainerStore.grantContainerAccess(url.path)
            if grant >= 0 { targetGrants.append(grant) }

            // Sample the directory mtime BEFORE walking (ContainerSizeMeter
            // parity): a store() that stats after the walk binds any file
            // written mid-walk to an mtime its measured bytes never had,
            // and the stale total then never re-measures.
            let preWalkMTime = CleanerMeasureCache.directoryMTime(atPath: url.path)

            var bytes: Int64 = 0
            var files = 0
            var visited = 0
            var exhausted = false
            let startedAt = Date()
            guard FileManager.default.fileExists(atPath: url.path),
                  let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: [],
                    errorHandler: { failedURL, error in
                        log(
                            "cleaner: enumerate failed \(failedURL.path) " +
                                "error=\(error.localizedDescription)"
                        )
                        return true
                    }
                  ) else {
                return BudgetedMeasure(bytes: 0, files: 0, budgetExhausted: false)
            }

            for case let item as URL in enumerator {
                visited += 1
                if visited % 256 == 0 {
                    if visited >= measureBudgetEntries
                        || Date().timeIntervalSince(startedAt) >= measureBudgetSeconds {
                        exhausted = true
                        log(
                            "cleaner: measure budget hit \(url.path) " +
                                "entries=\(visited) bytes=\(bytes)"
                        )
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
                files += 1
            }
            log("cleaner: measured \(url.path) bytes=\(bytes) files=\(files) exhausted=\(exhausted)")
            if !exhausted, let preWalkMTime {
                CleanerMeasureCache.store(
                    containerPath: root.path,
                    relativePath: relative,
                    bytes: bytes,
                    files: files,
                    directoryMTime: preWalkMTime
                )
            }
            return BudgetedMeasure(bytes: bytes, files: files, budgetExhausted: exhausted)
        }

        // Use FileManager enumeration instead of openat(O_NOFOLLOW): apps
        // commonly make Library/Caches a symlink, which the old walker
        // rejected as ELOOP and reported as an empty target.
        let cache = measure("Library/Caches")
        let temporary = measure("tmp")
        return LimitedCleanerUsage(
            cacheBytes: cache.bytes,
            temporaryBytes: temporary.bytes,
            removableItemCount: cache.files + temporary.files
        )
    }

    static func clean(
        containerURL: URL,
        rootValidator: ContainerRootValidator
    ) throws -> LimitedCleanerResult {
        let before = try scan(containerURL: containerURL, rootValidator: rootValidator)
        let root = containerURL.standardizedFileURL
        guard root.path.hasPrefix("/"),
              root.path != "/",
              rootValidator(root) else {
            throw LimitedCleanerError.unsafeContainerRoot
        }

        let containerGrant = ContainerStore.grantContainerAccess(root.path)
        defer { SandboxAccess.release(containerGrant) }
        var targetGrants: [Int64] = []
        defer {
            for targetGrant in targetGrants { SandboxAccess.release(targetGrant) }
        }

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var removed = 0
        var failed = 0

        // Safety policy pre-flight (CleanerSafetyPolicy): the container root
        // and both planned targets must pass the protected-path blacklist and
        // component-level symlink checks before anything is deleted.
        for relative in allowedRelativeDirectories {
            guard let planned = CleanerSafetyPolicy.PlannedTarget.build(
                containerRoot: root.path,
                relativePath: relative
            ) else {
                failed += 1
                log("cleaner: policy rejected malformed target \(relative) in \(root.path)")
                continue
            }
            switch CleanerSafetyPolicy.checkTarget(planned, snapshot: nil) {
            case .allowed:
                continue
            case .rejected(let reason):
                failed += 1
                log("cleaner: policy rejected \(planned.absolutePath) reason=\(reason)")
            }
        }
        guard failed == 0 else {
            throw LimitedCleanerError.unsafeContainerRoot
        }

        for relative in allowedRelativeDirectories {
            let target = relative.split(separator: "/").reduce(root) { current, part in
                current.appendingPathComponent(String(part), isDirectory: true)
            }
            let grant = ContainerStore.grantContainerAccess(target.path)
            if grant >= 0 { targetGrants.append(grant) }
            guard FileManager.default.fileExists(atPath: target.path) else { continue }

            // `Library/Caches` is often a symlink. Only follow it when the
            // resolved target stays inside the app container.
            let resolvedTarget = target.resolvingSymlinksInPath().standardizedFileURL
            let inside = resolvedTarget.path == resolvedRoot.path ||
                resolvedTarget.path.hasPrefix(resolvedRoot.path + "/")
            guard inside else {
                failed += 1
                log(
                    "cleaner: refusing symlink outside container " +
                        "\(target.path) -> \(resolvedTarget.path)"
                )
                continue
            }

            let children = (try? FileManager.default.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: [.isSymbolicLinkKey],
                options: []
            )) ?? []
            for child in children {
                // TOCTOU guard: re-verify the child still resolves inside the
                // container immediately before deletion (a symlink swapped in
                // between listing and removal is refused here).
                let resolvedChild = child.resolvingSymlinksInPath().standardizedFileURL
                let childInside = resolvedChild.path == resolvedRoot.path ||
                    resolvedChild.path.hasPrefix(resolvedRoot.path + "/")
                guard childInside else {
                    failed += 1
                    log(
                        "cleaner: refusing child outside container " +
                            "\(child.path) -> \(resolvedChild.path)"
                    )
                    continue
                }
                do {
                    try FileManager.default.removeItem(at: child)
                    removed += 1
                } catch {
                    failed += 1
                    log(
                        "cleaner: remove failed \(child.path) " +
                            "error=\(error.localizedDescription)"
                    )
                }
            }
            log("cleaner: removed=\(removed) failed=\(failed) under \(target.path)")
        }

        let after = try scan(containerURL: containerURL, rootValidator: rootValidator)
        return LimitedCleanerResult(
            before: before,
            after: after,
            removedItemCount: removed,
            failedItemCount: failed
        )
    }

    private static func withValidatedRootDescriptor<T>(
        _ rawURL: URL,
        rootValidator: ContainerRootValidator,
        operation: (Int32) throws -> T
    ) throws -> T {
        guard rawURL.isFileURL else { throw LimitedCleanerError.unsafeContainerRoot }
        let root = rawURL.standardizedFileURL
        guard root.path.hasPrefix("/"),
              root.path != "/",
              rootValidator(root) else {
            throw LimitedCleanerError.unsafeContainerRoot
        }

        // iOS 26/27: the cleaner opens the container root directly, so the
        // sandbox grant must be active for the whole scan/removal pass.
        let grant = ContainerStore.grantContainerAccess(root.path)
        defer { SandboxAccess.release(grant) }

        // worse_query grants are path-scoped. Grant the two measured targets
        // explicitly, mirroring WQ Files' wq_grant(dir) before measuring.
        var targetGrants: [Int64] = []
        defer {
            for targetGrant in targetGrants { SandboxAccess.release(targetGrant) }
        }
        for relative in allowedRelativeDirectories {
            let targetURL = relative.split(separator: "/").reduce(root) { url, part in
                url.appendingPathComponent(String(part), isDirectory: true)
            }
            let targetGrant = ContainerStore.grantContainerAccess(targetURL.path)
            if targetGrant >= 0 { targetGrants.append(targetGrant) }
        }

        let descriptor = open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else { throw LimitedCleanerError.unsafeContainerRoot }
        defer { close(descriptor) }
        return try operation(descriptor)
    }

    private static func scanAllowedDirectory(
        components: [String],
        rootDescriptor: Int32
    ) -> ScanSummary {
        guard let directoryDescriptor = openDirectory(
            components: components,
            relativeTo: rootDescriptor
        ) else {
            log("cleaner: open failed \(components.joined(separator: "/")) errno=\(errno)")
            return .empty
        }
        defer { close(directoryDescriptor) }
        return scanDirectory(directoryDescriptor)
    }

    private static func openDirectory(
        components: [String],
        relativeTo rootDescriptor: Int32
    ) -> Int32? {
        var currentDescriptor = dup(rootDescriptor)
        guard currentDescriptor >= 0 else { return nil }

        for component in components {
            let nextDescriptor = component.withCString {
                openat(
                    currentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            close(currentDescriptor)
            guard nextDescriptor >= 0 else { return nil }
            currentDescriptor = nextDescriptor
        }
        return currentDescriptor
    }

    private static func scanDirectory(_ directoryDescriptor: Int32) -> ScanSummary {
        var result = ScanSummary.empty
        forEachEntry(in: directoryDescriptor) { name, information in
            switch information.st_mode & S_IFMT {
            case S_IFREG:
                result.bytes += max(0, Int64(information.st_size))
                result.itemCount += 1
            case S_IFDIR:
                let childDescriptor = name.withCString {
                    openat(
                        directoryDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard childDescriptor >= 0 else { return }
                let nested = scanDirectory(childDescriptor)
                close(childDescriptor)
                result.bytes += nested.bytes
                result.itemCount += nested.itemCount
            default:
                // Symbolic links, sockets and device nodes are never followed or counted.
                break
            }
        }
        return result
    }

    private static func removeDirectoryContents(
        _ directoryDescriptor: Int32,
        summary: inout RemovalSummary
    ) {
        forEachEntry(in: directoryDescriptor) { name, information in
            switch information.st_mode & S_IFMT {
            case S_IFREG:
                let result = name.withCString { unlinkat(directoryDescriptor, $0, 0) }
                if result == 0 {
                    summary.removedItemCount += 1
                } else if errno != ENOENT {
                    summary.failedItemCount += 1
                }
            case S_IFDIR:
                let childDescriptor = name.withCString {
                    openat(
                        directoryDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard childDescriptor >= 0 else {
                    if errno != ENOENT && errno != ELOOP {
                        summary.failedItemCount += 1
                    }
                    return
                }
                removeDirectoryContents(childDescriptor, summary: &summary)
                close(childDescriptor)

                let result = name.withCString {
                    unlinkat(directoryDescriptor, $0, AT_REMOVEDIR)
                }
                if result != 0,
                   errno != ENOENT,
                   errno != ENOTEMPTY {
                    summary.failedItemCount += 1
                }
            default:
                // Preserve and never follow symbolic links or special nodes.
                break
            }
        }
    }

    private static func forEachEntry(
        in directoryDescriptor: Int32,
        body: (String, stat) -> Void
    ) {
        let iterationDescriptor = dup(directoryDescriptor)
        guard iterationDescriptor >= 0,
              let directory = fdopendir(iterationDescriptor) else {
            if iterationDescriptor >= 0 { close(iterationDescriptor) }
            return
        }
        defer { closedir(directory) }

        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }

            var information = stat()
            let status = name.withCString {
                fstatat(directoryDescriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else { continue }
            body(name, information)
        }
    }
}

private struct ScanSummary {
    var bytes: Int64
    var itemCount: Int

    static let empty = ScanSummary(bytes: 0, itemCount: 0)
}

private struct RemovalSummary {
    var removedItemCount = 0
    var failedItemCount = 0
}
