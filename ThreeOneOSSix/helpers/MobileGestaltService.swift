import Foundation

struct MobileGestaltState: Equatable {
    var deviceName: String
    var deviceSubtype: Int
    var productType: String
    var dynamicIsland: Bool
    var alwaysOnDisplay: Bool
    var aodVibrancy: Bool
    var chargeLimit: Bool
    var bootChime: Bool
}

enum MobileGestaltError: Error, Equatable {
    case unavailable
    case unreadable
    case invalidPlist
    case missingCacheExtra
    case invalidValue
    case backupRequired
}

extension MobileGestaltError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable: return "MobileGestalt cache is unavailable."
        case .unreadable: return "Could not read the MobileGestalt cache."
        case .invalidPlist: return "The MobileGestalt cache is not a valid plist."
        case .missingCacheExtra: return "The MobileGestalt cache has no CacheExtra dictionary."
        case .invalidValue: return "One of the values is invalid."
        case .backupRequired: return "A valid backup is required before restoring."
        }
    }

    var localizationKey: String {
        switch self {
        case .unavailable: return "gestalt.error.unavailable"
        case .unreadable: return "gestalt.error.unreadable"
        case .invalidPlist: return "gestalt.error.invalid"
        case .missingCacheExtra: return "gestalt.error.cache_extra"
        case .invalidValue: return "gestalt.error.value"
        case .backupRequired: return "gestalt.error.backup"
        }
    }
}

/// Reads and writes only the safe MobileGestalt subset. Every write goes
/// through BackupCenter + VerifiedFileWriter, so the original cache and the
/// pre-write version are always preserved.
enum MobileGestaltService {
    static let gestaltPath = "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist"

    private static let cacheExtraKey = "CacheExtra"
    private static let artworkKey = "oPeik/9e8lQWMszEjbPzng"
    private static let productTypeKey = "h9jDsbgj7xIVeIQ8S3/X3Q"
    private static let islandKey = "YlEtTtHlNesRBMal1CqRaA"
    private static let aodKey = "2OOJf1VhaM7NxfRok3HbWQ"
    private static let aodTimeKey = "j8/Omm6s1lsmTDFsXjsBfA"
    private static let aodVibrancyKey = "ykpu7qyhqFweVMKtxNylWA"
    private static let chargeLimitKey = "37NVydb//GP/GrhuTN+exg"
    private static let bootChimeKey = "QHxt+hGLaBPbQJbXiUJX3w"
    private static let subtypeKey = "ArtworkDeviceSubType"
    private static let artworkNameKey = "ArtworkDeviceProductDescription"

    static func load() throws -> MobileGestaltState {
        let root = try readRoot()
        guard let cacheExtra = root[cacheExtraKey] as? [String: Any] else {
            throw MobileGestaltError.missingCacheExtra
        }
        let artwork = cacheExtra[artworkKey] as? [String: Any] ?? [:]
        return MobileGestaltState(
            deviceName: artwork[artworkNameKey] as? String ?? "",
            deviceSubtype: artwork[subtypeKey] as? Int ?? 0,
            productType: cacheExtra[productTypeKey] as? String ?? "",
            dynamicIsland: isEnabled(cacheExtra[islandKey]),
            alwaysOnDisplay: isEnabled(cacheExtra[aodKey]),
            aodVibrancy: isEnabled(cacheExtra[aodVibrancyKey]),
            chargeLimit: isEnabled(cacheExtra[chargeLimitKey]),
            bootChime: isEnabled(cacheExtra[bootChimeKey])
        )
    }

    static func apply(_ state: MobileGestaltState) throws {
        let path = gestaltPath
        let directory = (path as NSString).deletingLastPathComponent
        let grant = ContainerStore.grantContainerAccess(directory)
        defer {
            if grant >= 0 { SandboxAccess.release(grant) }
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw MobileGestaltError.unavailable
        }

        // Same exclusive lock as GestaltPlistIO users: this editor and the
        // preset/field/region editors RMW one shared cache file.
        try GestaltPlistIO.withExclusiveAccess {
            var root = try readRoot()
        guard var cacheExtra = root[cacheExtraKey] as? [String: Any] else {
            throw MobileGestaltError.missingCacheExtra
        }

        var artwork = cacheExtra[artworkKey] as? [String: Any] ?? [:]
        artwork[subtypeKey] = state.deviceSubtype
        if state.deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            artwork.removeValue(forKey: artworkNameKey)
        } else {
            artwork[artworkNameKey] = state.deviceName
        }
        cacheExtra[artworkKey] = artwork
        if state.productType.isEmpty {
            cacheExtra.removeValue(forKey: productTypeKey)
        } else {
            cacheExtra[productTypeKey] = state.productType
        }

        setFlag(&cacheExtra, key: islandKey, enabled: state.dynamicIsland)
        setFlag(&cacheExtra, key: aodKey, enabled: state.alwaysOnDisplay)
        setFlag(&cacheExtra, key: aodTimeKey, enabled: state.alwaysOnDisplay)
        setFlag(&cacheExtra, key: aodVibrancyKey, enabled: state.aodVibrancy)
        setFlag(&cacheExtra, key: chargeLimitKey, enabled: state.chargeLimit)
        setFlag(&cacheExtra, key: bootChimeKey, enabled: state.bootChime)

        root[cacheExtraKey] = cacheExtra

        let format = try readFormat()
        let data: Data
        do {
            data = try PropertyListSerialization.data(
                fromPropertyList: root,
                format: format,
                options: 0
            )
        } catch {
            throw MobileGestaltError.invalidPlist
        }
        guard !data.isEmpty else {
            throw MobileGestaltError.invalidPlist
        }
        // Read back before writing: a malformed plist must never reach disk.
        guard (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) != nil else {
            throw MobileGestaltError.invalidPlist
        }

            try VerifiedFileWriter.write(
                data,
                to: URL(fileURLWithPath: path),
                feature: .gestalt,
                reason: "MobileGestalt safe subset"
            )
        }
    }

    static func restoreOriginal() throws {
        let path = gestaltPath
        let directory = (path as NSString).deletingLastPathComponent
        let grant = ContainerStore.grantContainerAccess(directory)
        defer {
            if grant >= 0 { SandboxAccess.release(grant) }
        }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let record = BackupCenter.shared.records(feature: .gestalt).first(where: {
            $0.kind == .original && $0.targetPath == canonical
        }) else {
            throw MobileGestaltError.backupRequired
        }
        try BackupCenter.shared.restore(record)
    }

    private static func readRoot() throws -> [String: Any] {
        let path = gestaltPath
        let directory = (path as NSString).deletingLastPathComponent
        let grant = ContainerStore.grantContainerAccess(directory)
        defer {
            if grant >= 0 { SandboxAccess.release(grant) }
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw MobileGestaltError.unavailable
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw MobileGestaltError.unreadable
        }
        guard let plist = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else {
            throw MobileGestaltError.invalidPlist
        }
        guard let root = plist as? [String: Any] else {
            throw MobileGestaltError.invalidPlist
        }
        return root
    }

    private static func readFormat() throws -> PropertyListSerialization.PropertyListFormat {
        let path = gestaltPath
        let directory = (path as NSString).deletingLastPathComponent
        let grant = ContainerStore.grantContainerAccess(directory)
        defer {
            if grant >= 0 { SandboxAccess.release(grant) }
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw MobileGestaltError.unreadable
        }
        var format = PropertyListSerialization.PropertyListFormat.binary
        _ = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        return format
    }

    private static func isEnabled(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let bool = value as? Bool { return bool }
        return false
    }

    private static func setFlag(
        _ dictionary: inout [String: Any],
        key: String,
        enabled: Bool
    ) {
        if enabled {
            dictionary[key] = 1
        } else {
            dictionary.removeValue(forKey: key)
        }
    }
}

