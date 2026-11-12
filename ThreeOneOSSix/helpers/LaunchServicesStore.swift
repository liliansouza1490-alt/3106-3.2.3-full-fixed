import Foundation

/// A parsed snapshot of lsd's CSStore2 database (magic `bdsl`).
///
/// Swift port of the LaunchServices store reader in WQ Files
/// (https://github.com/kolbicz/WQFiles, GPL-3.0-or-later, Christoph Kolbicz).
/// The original parser is the reason WQ Files still resolves container names
/// on iOS 27.2+, where the container identifier attribute and the root-owned
/// metadata plist are no longer readable. See NOTICE.md.
struct LaunchServicesSnapshot: Equatable {
    /// Canonical container path -> bundle identifier.
    let containerBundleIDs: [String: String]
    /// Bundle identifier -> localized display name (when the store has one).
    let displayNames: [String: String]
    /// Bundle identifier -> bundle name (fallback for display names).
    let bundleNames: [String: String]
    /// Every app/extension data container path the store lists.
    let containerPaths: [String]
    /// Bundle identifier -> .app bundle path.
    let bundlePaths: [String: String]
    /// Which record layout produced this snapshot, for diagnostics.
    let layoutLabel: String
    /// Number of mapped containers (for diagnostics and layout selection).
    let mappedContainerCount: Int
    /// Number of decoded names (for diagnostics and layout selection).
    let decodedNameCount: Int

    func bundleID(forContainerPath path: String) -> String? {
        containerBundleIDs[LaunchServicesStore.canonicalContainerPath(path)]
    }

    func containerPath(forBundleID bundleID: String) -> String? {
        containerPaths.first { containerBundleIDs[$0] == bundleID }
    }

    func displayName(forBundleID bundleID: String) -> String? {
        displayNames[bundleID] ?? bundleNames[bundleID]
    }
}

/// Pure byte-level parser. IO (locating and reading the store) lives in
/// `ContainerStore` so this file stays testable on macOS.
enum LaunchServicesStore {
    static let minimumStoreBytes = 0x1000
    static let maximumStoreBytes = 64 * 1024 * 1024

    private static let maxStringID: UInt32 = 0x0100_0000
    private static let maxBundleRecords = 100_000
    private static let maxDecodedStrings = 200_000
    private static let maxDecodedStringBytes = 8 * 1024 * 1024
    private static let maxRecordSize = 0x25c
    private static let maxStringLength = 0x800

    private struct Layout {
        let label: String
        let bundleSize: UInt32
        let bundleID: Int
        let container: Int
        let name: Int
        let displayName: Int
        let bundlePath: Int
        let pluginSize: UInt32
        let pluginBundleID: Int
        let pluginContainer: Int
    }

    // Record layouts by release. Offsets are from the record body (after the
    // 8-byte header). iOS 26 records are 0x14 bytes shorter; iOS 27.2 moved
    // the container fields 4 bytes later. A new release can be added here and
    // the layout that maps the most containers still wins automatically.
    private static let layouts: [Layout] = [
        Layout(label: "27.0", bundleSize: 0x250, bundleID: 0x0c, container: 0x68,
               name: 0x6c, displayName: 0x74, bundlePath: 0x00,
               pluginSize: 0x118, pluginBundleID: 0x00, pluginContainer: 0x54),
        Layout(label: "26", bundleSize: 0x23c, bundleID: 0x0c, container: 0x64,
               name: 0x68, displayName: 0x70, bundlePath: 0x00,
               pluginSize: 0x104, pluginBundleID: 0x00, pluginContainer: 0x50),
        // iOS 26.5 (WQ Files 0.9.1, issue #37, from a device layout hint):
        // same record sizes as 26.7 but container fields 4 bytes earlier;
        // the bundle id position was unknown upstream, so both candidates
        // are listed — the layout mapping the most containers wins.
        Layout(label: "26.5", bundleSize: 0x23c, bundleID: 0x0c, container: 0x60,
               name: 0x64, displayName: 0x6c, bundlePath: 0x00,
               pluginSize: 0x104, pluginBundleID: 0x00, pluginContainer: 0x4c),
        Layout(label: "26.5b", bundleSize: 0x23c, bundleID: 0x08, container: 0x60,
               name: 0x64, displayName: 0x6c, bundlePath: 0x00,
               pluginSize: 0x104, pluginBundleID: 0x00, pluginContainer: 0x4c),
        Layout(label: "27.2", bundleSize: 0x25c, bundleID: 0x0c, container: 0x6c,
               name: 0x70, displayName: 0x78, bundlePath: 0x00,
               pluginSize: 0x120, pluginBundleID: 0x00, pluginContainer: 0x58),
        Layout(label: "27.2b", bundleSize: 0x25c, bundleID: 0x10, container: 0x6c,
               name: 0x70, displayName: 0x78, bundlePath: 0x00,
               pluginSize: 0x120, pluginBundleID: 0x04, pluginContainer: 0x58),
        Layout(label: "27.2c", bundleSize: 0x25c, bundleID: 0x0c, container: 0x6c,
               name: 0x70, displayName: 0x78, bundlePath: 0x00,
               pluginSize: 0x120, pluginBundleID: 0x04, pluginContainer: 0x58),
        Layout(label: "27.2d", bundleSize: 0x25c, bundleID: 0x10, container: 0x6c,
               name: 0x70, displayName: 0x78, bundlePath: 0x00,
               pluginSize: 0x120, pluginBundleID: 0x00, pluginContainer: 0x58),
    ]

    static func parse(_ data: Data) -> LaunchServicesSnapshot? {
        guard data.count >= minimumStoreBytes,
              data.count <= maximumStoreBytes else {
            return nil
        }
        let bytes = [UInt8](data)
        let n = bytes.count
        guard n >= 4,
              bytes[0] == 0x62, bytes[1] == 0x64, bytes[2] == 0x73, bytes[3] == 0x6c else {
            return nil
        }

        let heapOffset = firstHeapOffset(bytes)
        let bitsetBytes = Int(maxStringID) / 8
        var neededStrings = [UInt8](repeating: 0, count: bitsetBytes)
        var stringsInHeap = [UInt8](repeating: 0, count: bitsetBytes)

        var bundleRecords = [[UInt32]](repeating: [], count: layouts.count)
        var pluginRecords = [[UInt32]](repeating: [], count: layouts.count)
        var bundleLayoutsBySize: [UInt32: [Int]] = [:]
        var pluginLayoutsBySize: [UInt32: [Int]] = [:]
        for (index, layout) in layouts.enumerated() {
            bundleLayoutsBySize[layout.bundleSize, default: []].append(index)
            pluginLayoutsBySize[layout.pluginSize, default: []].append(index)
        }

        // Pass 1: collect Bundle and plug-in records for every known layout.
        // Most four-byte windows are not record headers, so the size index
        // keeps this pass cheap even on a 64 MB store.
        var tooManyRecords = false
        var offset = 0
        while offset + 8 + maxRecordSize <= n, !tooManyRecords {
            let size = rd32(bytes, offset + 4)
            if let indices = pluginLayoutsBySize[size] {
                for index in indices {
                    let layout = layouts[index]
                    let bundleRef = rd32(bytes, offset + 8 + layout.pluginBundleID)
                    let containerRef = rd32(bytes, offset + 8 + layout.pluginContainer)
                    guard isValidRef(bundleRef), isValidRef(containerRef),
                          pluginRecords[index].count / 2 < maxBundleRecords else {
                        continue
                    }
                    pluginRecords[index].append(contentsOf: [bundleRef, containerRef])
                    setBit(&neededStrings, bundleRef >> 2)
                    setBit(&neededStrings, containerRef >> 2)
                }
            }
            if let indices = bundleLayoutsBySize[size] {
                for index in indices {
                    if bundleRecords[index].count / 5 >= maxBundleRecords {
                        tooManyRecords = true
                        break
                    }
                    let layout = layouts[index]
                    let refs = [
                        rd32(bytes, offset + 8 + layout.bundleID),
                        rd32(bytes, offset + 8 + layout.name),
                        rd32(bytes, offset + 8 + layout.displayName),
                        rd32(bytes, offset + 8 + layout.container),
                        rd32(bytes, offset + 8 + layout.bundlePath),
                    ]
                    guard isValidRef(refs[0]) else { continue }
                    bundleRecords[index].append(contentsOf: refs)
                    for ref in refs where isValidRef(ref) {
                        setBit(&neededStrings, ref >> 2)
                    }
                }
            }
            offset += 4
        }

        guard !tooManyRecords,
              bundleRecords.contains(where: { !$0.isEmpty }) ||
                pluginRecords.contains(where: { !$0.isEmpty }) else {
            return nil
        }

        // Pass 2: decode the string table entries the records refer to, plus
        // container/application paths. `heapOffset` marks the start of the
        // string heap; a later duplicate wins over an earlier placeholder.
        var strings: [UInt32: String] = [:]
        var pathStrings: [UInt32: String] = [:]
        var appPathStrings: [UInt32: String] = [:]
        var pathConflicts = Set<UInt32>()
        var appPathConflicts = Set<UInt32>()
        var decodedStringCount = 0
        var decodedStringBytes = 0

        offset = 0
        while offset + 8 <= n {
            let stringID = rd32(bytes, offset)
            guard stringID != 0, stringID < maxStringID,
                  bitIsSet(neededStrings, stringID) else {
                offset += 4
                continue
            }

            let isInHeap = offset >= heapOffset
            let hadString = strings[stringID] != nil
            let keepGeneral = !hadString || (isInHeap && !bitIsSet(stringsInHeap, stringID))

            var maybePath = false
            let peekLength = rd32(bytes, offset + 4)
            if peekLength >= 6, peekLength < UInt32(maxStringLength),
               offset + 8 < n, bytes[offset + 8] == 0x2F { // '/'
                maybePath = true
            }

            guard keepGeneral || maybePath else {
                offset += 4
                continue
            }
            guard let value = decodeString(bytes, at: offset) else {
                offset += 4
                continue
            }

            if maybePath {
                if value.contains("/mobile/Containers/Data/") {
                    storePathString(value, id: stringID, table: &pathStrings,
                                    conflicts: &pathConflicts)
                } else if value.hasSuffix(".app") || value.hasSuffix(".app/") {
                    storePathString(value, id: stringID, table: &appPathStrings,
                                    conflicts: &appPathConflicts)
                }
            }

            guard keepGeneral else {
                offset += 4
                continue
            }
            if decodedStringCount < maxDecodedStrings,
               decodedStringBytes + value.utf16.count <= maxDecodedStringBytes {
                strings[stringID] = value
                decodedStringCount += 1
                decodedStringBytes += value.utf16.count
                if isInHeap {
                    setBit(&stringsInHeap, stringID)
                }
            }
            offset += 4
        }

        func path(for ref: UInt32) -> String? {
            let stringID = ref >> 2
            if pathConflicts.contains(stringID) { return nil }
            if let path = pathStrings[stringID] { return path }
            return strings[stringID]
        }

        // Pass 3: resolve each layout into its container->bundle-id map and
        // keep the layout that maps the most containers.
        var best: LaunchServicesSnapshot?
        var bestContainers: [String: String] = [:]
        var bestDisplayCount = 0

        for (index, layout) in layouts.enumerated() {
            var containers: [String: String] = [:]
            var conflicts = Set<String>()
            var displayNames: [String: String] = [:]
            var bundleNames: [String: String] = [:]
            var bundlePaths: [String: String] = [:]

            func claim(_ rawPath: String?, _ bundleID: String?, _ kind: String) {
                guard let rawPath, let bundleID,
                      looksLikeBundleID(bundleID) else { return }
                let path = canonicalContainerPath(rawPath)
                guard isDataContainerPath(path), path.contains(kind) else { return }
                if let existing = containers[path] {
                    if existing != bundleID { conflicts.insert(path) }
                } else {
                    containers[path] = bundleID
                }
            }

            let plugins = pluginRecords[index]
            var pluginIndex = 0
            while pluginIndex + 1 < plugins.count {
                let bundleID = strings[plugins[pluginIndex] >> 2]
                claim(path(for: plugins[pluginIndex + 1]), bundleID, "/Data/PluginKitPlugin/")
                pluginIndex += 2
            }

            let records = bundleRecords[index]
            var recordIndex = 0
            while recordIndex + 4 < records.count {
                let bundleIDRef = records[recordIndex]
                let bundleID = strings[bundleIDRef >> 2]
                if let bundleID, looksLikeBundleID(bundleID) {
                    let containerRef = records[recordIndex + 3]
                    if containerRef != 0, containerRef & 3 == 0 {
                        claim(path(for: containerRef), bundleID, "/Data/Application/")
                    }
                    let nameRef = records[recordIndex + 1]
                    let displayRef = records[recordIndex + 2]
                    let bundleName = (nameRef & 3) != 0 ? nil : strings[nameRef >> 2]
                    let displayName = (displayRef & 3) != 0 ? nil : strings[displayRef >> 2]
                    if let safe = safeName(displayName), displayNames[bundleID] == nil {
                        displayNames[bundleID] = safe
                    }
                    if let safe = safeName(bundleName), bundleNames[bundleID] == nil {
                        bundleNames[bundleID] = safe
                    }
                    let appPathRef = records[recordIndex + 4]
                    if appPathRef != 0, appPathRef & 3 == 0,
                       let appPath = appPathStrings[appPathRef >> 2],
                       bundlePaths[bundleID] == nil {
                        var clean = appPath.hasSuffix("/") ? String(appPath.dropLast()) : appPath
                        if clean.hasPrefix("/var/") {
                            clean = "/private" + clean
                        }
                        bundlePaths[bundleID] = clean
                    }
                }
                recordIndex += 5
            }

            for conflict in conflicts {
                containers.removeValue(forKey: conflict)
            }

            let displayCount = displayNames.count
            if best == nil || containers.count > bestContainers.count ||
                (containers.count == bestContainers.count && displayCount > bestDisplayCount) {
                bestContainers = containers
                bestDisplayCount = displayCount
                best = LaunchServicesSnapshot(
                    containerBundleIDs: containers,
                    displayNames: displayNames,
                    bundleNames: bundleNames,
                    containerPaths: containers.keys.sorted(),
                    bundlePaths: bundlePaths,
                    layoutLabel: layout.label,
                    mappedContainerCount: containers.count,
                    decodedNameCount: displayCount
                )
            }
        }

        return best
    }

    // MARK: - Shared helpers (also used by ContainerStore)

    static func canonicalContainerPath(_ rawPath: String) -> String {
        var path = rawPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        if path == "/var" || path.hasPrefix("/var/") {
            path = "/private" + path
        }
        return path
    }

    /// Path containment that treats `/var/...` and `/private/var/...` as the
    /// same tree. A raw string prefix check here rejected extracted `.tendies`
    /// packages after the archive itself had unpacked successfully.
    static func isPath(_ candidate: String, containedIn root: String) -> Bool {
        let rootPath = canonicalContainerPath(root)
        let candidatePath = canonicalContainerPath(candidate)
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    static func isDataContainerPath(_ path: String) -> Bool {
        let prefixes = [
            "/private/var/mobile/Containers/Data/Application/",
            "/private/var/mobile/Containers/Data/PluginKitPlugin/",
        ]
        for prefix in prefixes {
            guard path.hasPrefix(prefix), path.count == prefix.count + 36 else { continue }
            return UUID(uuidString: String(path.dropFirst(prefix.count))) != nil
        }
        return false
    }

    static func looksLikeBundleID(_ value: String) -> Bool {
        guard value.count > 2,
              value.contains("."),
              !value.hasPrefix("."),
              value.utf8.count <= 255 else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: - Byte helpers

    @inline(__always)
    private static func rd32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    @inline(__always)
    private static func isValidRef(_ ref: UInt32) -> Bool {
        ref != 0 && (ref & 3) == 0 && (ref >> 2) < maxStringID
    }

    @inline(__always)
    private static func setBit(_ bits: inout [UInt8], _ stringID: UInt32) {
        let index = Int(stringID / 8)
        guard index < bits.count else { return }
        bits[index] |= UInt8(1) << UInt8(stringID % 8)
    }

    @inline(__always)
    private static func bitIsSet(_ bits: [UInt8], _ stringID: UInt32) -> Bool {
        let index = Int(stringID / 8)
        guard index < bits.count else { return false }
        return (bits[index] & (UInt8(1) << UInt8(stringID % 8))) != 0
    }

    private static func firstHeapOffset(_ bytes: [UInt8]) -> Int {
        let marker = Array("<string>".utf8)
        guard bytes.count >= marker.count else { return 0 }
        let last = bytes.count - marker.count
        var index = 0
        while index <= last {
            if bytes[index] == marker[0] {
                var matched = true
                for offset in 1..<marker.count where bytes[index + offset] != marker[offset] {
                    matched = false
                    break
                }
                if matched { return index }
            }
            index += 1
        }
        return 0
    }

    private static func decodeString(_ bytes: [UInt8], at offset: Int) -> String? {
        let n = bytes.count
        guard offset >= 0, n - offset >= 8 else { return nil }
        let length = Int(rd32(bytes, offset + 4))
        guard length > 0,
              length < maxStringLength,
              length < n - offset - 8 else {
            return nil
        }
        if length % 4 != 0, bytes[offset + 8 + length] != 0 {
            return nil
        }
        let start = offset + 8
        let range = start..<(start + length)
        guard !bytes[range].contains(0),
              let value = String(bytes: bytes[range], encoding: .utf8) else {
            return nil
        }
        return value
    }

    private static func storePathString(
        _ value: String,
        id: UInt32,
        table: inout [UInt32: String],
        conflicts: inout Set<UInt32>
    ) {
        if let existing = table[id] {
            if existing != value {
                conflicts.insert(id)
                table.removeValue(forKey: id)
            }
        } else if !conflicts.contains(id) {
            table[id] = value
        }
    }

    private static func safeName(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        var safe = String()
        safe.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            if isFormatScalar(scalar.value) || scalar.value == 0x2028 || scalar.value == 0x2029 {
                safe.unicodeScalars.append("\u{FFFD}")
            } else {
                safe.unicodeScalars.append(scalar)
            }
        }
        let normalized = safe
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !normalized.hasPrefix("/"),
              !normalized.contains(".app/"),
              normalized.rangeOfCharacter(from: .controlCharacters) == nil else {
            return nil
        }
        return normalized
    }

    private static func isFormatScalar(_ value: UInt32) -> Bool {
        value == 0x00ad
            || (0x0600...0x0605).contains(value)
            || value == 0x061c
            || value == 0x06dd
            || value == 0x070f
            || (0x0890...0x0891).contains(value)
            || value == 0x08e2
            || value == 0x180e
            || (0x200b...0x200f).contains(value)
            || (0x202a...0x202e).contains(value)
            || (0x2060...0x206f).contains(value)
            || value == 0xfeff
    }
}

// MARK: - Fast container catalog

/// One entry derived directly from lsd's database. No filesystem scan is
/// involved; the list is the source of truth for App Data and the cleaner on
/// every iOS version where the database is readable.
enum ContainerCatalogKind: String, Codable, Equatable {
    case application
    case extensionContainer = "extension"
}

struct ContainerCatalogEntry: Codable, Equatable, Identifiable {
    let containerPath: String
    let bundleID: String
    let displayName: String
    let kind: ContainerCatalogKind

    var id: String { containerPath }
}

struct ContainerCatalogSnapshot: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let signature: String
    let osBuild: String
    let createdAt: Date
    let entries: [ContainerCatalogEntry]
}

enum ContainerCatalogBuilder {
    static func build(
        from snapshot: LaunchServicesSnapshot,
        signature: String,
        osBuild: String
    ) -> ContainerCatalogSnapshot {
        var seen = Set<String>()
        var entries: [ContainerCatalogEntry] = []
        entries.reserveCapacity(snapshot.containerPaths.count)

        for rawPath in snapshot.containerPaths {
            let path = LaunchServicesStore.canonicalContainerPath(rawPath)
            guard LaunchServicesStore.isDataContainerPath(path),
                  seen.insert(path).inserted,
                  let bundleID = snapshot.bundleID(forContainerPath: path),
                  LaunchServicesStore.looksLikeBundleID(bundleID),
                  !bundleID.hasPrefix("systemgroup.") else {
                continue
            }
            let kind: ContainerCatalogKind =
                path.contains("/PluginKitPlugin/") ? .extensionContainer : .application
            let name = snapshot.displayName(forBundleID: bundleID) ?? bundleID
            entries.append(ContainerCatalogEntry(
                containerPath: path,
                bundleID: bundleID,
                displayName: name,
                kind: kind
            ))
        }

        entries.sort {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.containerPath < $1.containerPath
        }
        return ContainerCatalogSnapshot(
            version: ContainerCatalogSnapshot.currentVersion,
            signature: signature,
            osBuild: osBuild,
            createdAt: Date(),
            entries: entries
        )
    }
}

enum ContainerCatalogCache {
    static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("3106", isDirectory: true)
            .appendingPathComponent("container-catalog.json")
    }

    static func load(
        signature: String,
        rootURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> ContainerCatalogSnapshot? {
        let url = rootURL ?? defaultURL(fileManager: fileManager)
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(ContainerCatalogSnapshot.self, from: data),
              snapshot.version == ContainerCatalogSnapshot.currentVersion,
              snapshot.signature == signature,
              !snapshot.entries.isEmpty else {
            return nil
        }
        return snapshot
    }

    static func save(
        _ snapshot: ContainerCatalogSnapshot,
        rootURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let url = rootURL ?? defaultURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    static func clear(rootURL: URL? = nil, fileManager: FileManager = .default) {
        let url = rootURL ?? defaultURL(fileManager: fileManager)
        try? fileManager.removeItem(at: url)
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
}
