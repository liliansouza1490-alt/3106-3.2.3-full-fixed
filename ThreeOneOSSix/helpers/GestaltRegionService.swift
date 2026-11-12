import Foundation
import Darwin

/// hw.machine via sysctl (project convention, cf. BackupCenter.sysctlString).
/// hw.machine via sysctl. Internal (not private) so the Gestalt cards
/// page can build its four-element checkup from the same source.
func gestaltDeviceMachine() -> String {
    var size = 0
    sysctlbyname("hw.machine", nil, &size, nil, 0)
    guard size > 0 else { return "" }
    var buffer = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.machine", &buffer, &size, nil, 0)
    return String(cString: buffer)
}

/// Region / regulatory-model modification and the Siri AI enablement flows,
/// ported from YumEdit's verified-mapping discipline:
/// - Only the three region keys that already exist on the device are
///   written. iOS 27 rejects caches with newly invented keys (boot bounce).
/// - Native mode changes ONLY country code, sales region and the regulatory
///   model number for a verified machine mapping — no identity spoofing.
/// - Experimental mode (older devices) additionally spoofs product/board/
///   CPU and sets SiriMode=2; it is gated behind the full-screen risk
///   confirmation and refuses unknown machines outright.
enum GestaltRegionError: Error, Equatable {
    case unavailable
    case unreadable
    case missingCacheExtra
    case missingRegionFields
    case unknownMachine
    case experimentalRequiresIOS27
    case experimentalNotEligible
    case unknownPreset
    case factoryBaselineConflict
}

struct GestaltSiriModel: Identifiable, Equatable {
    let id: String          // product type, e.g. "iPhone17,1"
    let name: String
    let board: String
    let cpu: String
    let regulatory: String
}

enum GestaltRegionService {

    /// Verified machine table (YumEdit parity; released hardware only).
    static let siriNativeModels: [GestaltSiriModel] = [
        .init(id: "iPhone16,1", name: "iPhone 15 Pro", board: "D83AP", cpu: "t8130", regulatory: "A2848"),
        .init(id: "iPhone16,2", name: "iPhone 15 Pro Max", board: "D84AP", cpu: "t8130", regulatory: "A2849"),
        .init(id: "iPhone17,3", name: "iPhone 16", board: "D47AP", cpu: "t8140", regulatory: "A3081"),
        .init(id: "iPhone17,4", name: "iPhone 16 Plus", board: "D48AP", cpu: "t8140", regulatory: "A3082"),
        .init(id: "iPhone17,1", name: "iPhone 16 Pro", board: "D93AP", cpu: "t8140", regulatory: "A3083"),
        .init(id: "iPhone17,2", name: "iPhone 16 Pro Max", board: "D94AP", cpu: "t8140", regulatory: "A3084"),
        .init(id: "iPhone17,5", name: "iPhone 16e", board: "V59AP", cpu: "t8140", regulatory: "A3212"),
        .init(id: "iPhone18,3", name: "iPhone 17", board: "V57AP", cpu: "t8150", regulatory: "A3258"),
        .init(id: "iPhone18,1", name: "iPhone 17 Pro", board: "V53AP", cpu: "t8150", regulatory: "A3256"),
        .init(id: "iPhone18,2", name: "iPhone 17 Pro Max", board: "V54AP", cpu: "t8150", regulatory: "A3257"),
        .init(id: "iPhone18,4", name: "iPhone Air", board: "D23AP", cpu: "t8150", regulatory: "A3260"),
        .init(id: "iPhone18,5", name: "iPhone 17e", board: "V159AP", cpu: "t8150", regulatory: "A3575"),
    ]

    /// iPad experimental profile (verified M4 pair only, YumEdit parity).
    static let siriIPadModels: [GestaltSiriModel] = [
        .init(id: "iPad16,3", name: "iPad Pro 11″ M4 Wi-Fi", board: "J717AP", cpu: "t8132", regulatory: "A2836"),
        .init(id: "iPad16,4", name: "iPad Pro 11″ M4 Cellular", board: "J718AP", cpu: "t8132", regulatory: "A2837"),
    ]

    struct RegionSnapshot: Equatable {
        var country: String
        var region: String
        var regulatory: String
        var machine: String
    }

    // MARK: - Snapshot

    static func snapshot() throws -> RegionSnapshot {
        let cacheExtra = try readCacheExtra()
        guard
            let country = cacheExtra[GestaltKeys.regionCode] as? String,
            let region = cacheExtra[GestaltKeys.legacyRegionInfo] as? String,
            let regulatory = cacheExtra[GestaltKeys.modelNumber] as? String
        else {
            throw GestaltRegionError.missingRegionFields
        }
        return RegionSnapshot(
            country: country,
            region: region,
            regulatory: regulatory,
            machine: gestaltDeviceMachine()
        )
    }

    // MARK: - Region change (LL/A US trial)

    /// Change region to US (LL/A) with the regulatory model of the chosen
    /// native model. Writes only keys that already exist.
    static func applyRegion(nativeModel: GestaltSiriModel) throws {
        let cacheExtra = try readCacheExtra()
        // All three region fields must exist on this device.
        guard
            cacheExtra[GestaltKeys.regionCode] != nil,
            cacheExtra[GestaltKeys.legacyRegionInfo] != nil,
            cacheExtra[GestaltKeys.modelNumber] != nil
        else {
            throw GestaltRegionError.missingRegionFields
        }
        // The chosen model must be a verified mapping for this machine.
        let machine = gestaltDeviceMachine()
        guard nativeModel.id == machine else {
            throw GestaltRegionError.unknownMachine
        }

        // Exclusive across read→mutate→write (shared with the preset engine
        // and field editor, which RMW the same cache from other queues).
        try GestaltPlistIO.withExclusiveAccess {
            var root = try GestaltPlistIO.readRoot()
            guard var extra = root["CacheExtra"] as? [String: Any] else {
                throw GestaltRegionError.missingCacheExtra
            }
            extra[GestaltKeys.regionCode] = "LL"
            extra[GestaltKeys.legacyRegionInfo] = "LL/A"
            extra[GestaltKeys.modelNumber] = nativeModel.regulatory
            root["CacheExtra"] = extra
            try GestaltPlistIO.writeRoot(root, reason: "region:LLA:\(nativeModel.id)")
        }
        SoundEffects.play(.confirm)
    }

    // MARK: - Siri AI native mode

    /// Native Siri AI enablement: region triplet + AI capability flag only,
    /// in a SINGLE write (each writeRoot pass creates a backup snapshot, so
    /// the old applyRegion-then-flag two-write shape doubled backup churn).
    /// No product/board/CPU spoofing, so Face ID and hardware identity stay
    /// untouched.
    static func applySiriAINative(nativeModel: GestaltSiriModel) throws {
        let machine = gestaltDeviceMachine()
        guard nativeModel.id == machine else {
            throw GestaltRegionError.unknownMachine
        }
        try GestaltPlistIO.withExclusiveAccess {
            var root = try GestaltPlistIO.readRoot()
            guard var extra = root["CacheExtra"] as? [String: Any] else {
                throw GestaltRegionError.missingCacheExtra
            }
            guard
                extra[GestaltKeys.regionCode] != nil,
                extra[GestaltKeys.legacyRegionInfo] != nil,
                extra[GestaltKeys.modelNumber] != nil
            else {
                throw GestaltRegionError.missingRegionFields
            }
            extra[GestaltKeys.regionCode] = "LL"
            extra[GestaltKeys.legacyRegionInfo] = "LL/A"
            extra[GestaltKeys.modelNumber] = nativeModel.regulatory
            if extra[GestaltKeys.aiCapability] != nil {
                extra[GestaltKeys.aiCapability] = NSNumber(value: true)
            }
            root["CacheExtra"] = extra
            try GestaltPlistIO.writeRoot(root, reason: "siri-ai-native:\(nativeModel.id)")
        }
        SoundEffects.play(.confirm)
    }

    // MARK: - Siri AI experimental mode

    /// Experimental Siri AI for older devices: spoofs product type, board
    /// config and CPU type to the chosen profile and sets SiriMode=2.
    /// YumEdit guardrails kept verbatim: iOS 27+ only, eligible machines
    /// only (iPhone 11..17 families without native AI, or the verified M4
    /// iPads), unknown machines refused before any write.
    static func applySiriAIExperimental(spoofModel: GestaltSiriModel) throws {
        let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        guard osMajor >= 27 else {
            throw GestaltRegionError.experimentalRequiresIOS27
        }
        let machine = gestaltDeviceMachine()
        let family = Int(machine.dropFirst(6).prefix(while: { $0.isNumber })) ?? 0
        let isPad = machine.hasPrefix("iPad")

        let eligible: Bool
        if isPad {
            eligible = GestaltRegionService.siriIPadModels.contains { $0.id == machine }
        } else {
            // iPhone 11 (12,1 era = family 12) through 17 family, plus any
            // machine whose productType appears in the native table.
            eligible = (12...17).contains(family)
                || GestaltRegionService.siriNativeModels.contains { $0.id == machine }
        }
        guard eligible else {
            throw GestaltRegionError.experimentalNotEligible
        }
        // The spoof TARGET must come from the verified table for this device
        // family: iPads may only use the M4 profiles, iPhones only the
        // native-AI profiles. (spoofModel describes the target identity, not
        // the current machine.)
        let spoofTable = isPad ? GestaltRegionService.siriIPadModels : GestaltRegionService.siriNativeModels
        guard spoofTable.contains(where: { $0.id == spoofModel.id }) else {
            throw GestaltRegionError.unknownMachine
        }

        try GestaltPlistIO.withExclusiveAccess {
            var root = try GestaltPlistIO.readRoot()
            guard var extra = root["CacheExtra"] as? [String: Any] else {
                throw GestaltRegionError.missingCacheExtra
            }
            guard
                extra[GestaltKeys.regionCode] != nil,
                extra[GestaltKeys.legacyRegionInfo] != nil,
                extra[GestaltKeys.modelNumber] != nil
            else {
                throw GestaltRegionError.missingRegionFields
            }

            // Anti-bounce rule (module header): only overwrite keys the
            // device ALREADY has. The identity cluster (productType/board/
            // cpu/SiriMode/AI flag) is checked inside the same locked
            // read-modify-write — a check outside the lock races with any
            // editor that removes a key between check and write, and
            // re-injecting a key the device never had trips the iOS 27
            // boot-time cache rebuild.
            for identityKey in [
                GestaltKeys.aiCapability,
                GestaltKeys.productType,
                GestaltKeys.boardConfig,
                GestaltKeys.cpuType,
                GestaltKeys.siriMode,
            ] where extra[identityKey] == nil {
                throw GestaltRegionError.missingRegionFields
            }
            // Erosion-CN v0.8.5: Audio Intelligence ships FALSE everywhere;
            // setting a factory-false AI slot to true breaks the photos
            // high-quality Clean Up pipeline even in experimental mode.
            if let aiFlag = extra[GestaltKeys.aiCapability] as? NSNumber,
               aiFlag.boolValue == false {
                throw GestaltRegionError.factoryBaselineConflict
            }

            extra[GestaltKeys.regionCode] = "LL"
            extra[GestaltKeys.legacyRegionInfo] = "LL/A"
            extra[GestaltKeys.modelNumber] = spoofModel.regulatory
            extra[GestaltKeys.aiCapability] = NSNumber(value: true)
            extra[GestaltKeys.productType] = spoofModel.id
            extra[GestaltKeys.boardConfig] = spoofModel.board
            extra[GestaltKeys.cpuType] = spoofModel.cpu
            extra[GestaltKeys.siriMode] = NSNumber(value: 2)
            root["CacheExtra"] = extra
            try GestaltPlistIO.writeRoot(root, reason: "siri-ai-exp:\(spoofModel.id)")
        }
        SoundEffects.play(.warning)
    }

    // MARK: - Restore

    /// Restore the pre-change region/siri state from the Gestalt backup
    /// chain (VerifiedFileWriter originals).
    static func restoreOriginal() throws {
        try MobileGestaltService.restoreOriginal()
    }

    // MARK: - Helpers

    private static func readCacheExtra() throws -> [String: Any] {
        let root = try GestaltPlistIO.readRoot()
        guard let cacheExtra = root["CacheExtra"] as? [String: Any] else {
            throw GestaltRegionError.missingCacheExtra
        }
        return cacheExtra
    }
}

extension GestaltRegionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable: return "gestalt.error.unavailable"
        case .unreadable: return "gestalt.error.unreadable"
        case .missingCacheExtra: return "gestalt.error.cache_extra"
        case .missingRegionFields: return "gestalt.region.error.missing_fields"
        case .unknownMachine: return "gestalt.region.error.unknown_machine"
        case .experimentalRequiresIOS27: return "gestalt.region.error.needs_ios27"
        case .experimentalNotEligible: return "gestalt.region.error.not_eligible"
        case .factoryBaselineConflict: return "gestalt.region.error.factory_baseline"
        case .unknownPreset: return "gestalt.error.value"
        }
    }
}
