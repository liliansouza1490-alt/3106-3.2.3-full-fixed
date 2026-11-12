import Foundation

/// Supervised Mode toggle (Regitela parity): flips `IsSupervised` in the
/// ConfigurationProfiles container's CloudConfigurationDetails.plist.
/// The write goes through the verified pipeline (auto-backup, in-place
/// inode-preserving replacement, read-back verification).
///
/// Risk note (surfaced in the UI): never use on an MDM-managed device —
/// flipping supervision breaks the management relationship. A setup screen
/// may appear after the next respring or reboot. Quit the Settings app to
/// apply.
enum SupervisedModeService {

    static let containerPath =
        "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.configurationprofiles/Library/ConfigurationProfiles"
    static let plistName = "CloudConfigurationDetails.plist"
    static let supervisedKey = "IsSupervised"

    enum SupervisedError: Error, Equatable, LocalizedError {
        case unavailable
        case unreadable
        case invalidPlist
        case notAConfigurationProfile

        var errorDescription: String? {
            switch self {
            case .unavailable: return "supervised.error.unavailable"
            case .unreadable: return "supervised.error.unreadable"
            case .invalidPlist: return "supervised.error.invalid"
            case .notAConfigurationProfile: return "supervised.error.not_profile"
            }
        }
    }

    static var plistPath: String {
        (containerPath as NSString).appendingPathComponent(plistName)
    }

    /// Current supervision state; nil when the plist or key does not exist.
    static func currentState() -> Bool? {
        guard let root = try? readRoot() else { return nil }
        let value = root[supervisedKey] as? NSNumber
        return value?.boolValue
    }

    static func apply(_ supervised: Bool) throws {
        guard FileManager.default.fileExists(atPath: plistPath) else {
            throw SupervisedError.unavailable
        }
        var root = try readRoot()
        root[supervisedKey] = NSNumber(value: supervised)

        let directory = containerPath
        let grant = ContainerStore.grantContainerAccess(directory)
        defer {
            if grant >= 0 { SandboxAccess.release(grant) }
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: root, format: .binary, options: 0
        )
        // Read-back before writing.
        guard (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) != nil else {
            throw SupervisedError.invalidPlist
        }
        try VerifiedFileWriter.write(
            data,
            to: URL(fileURLWithPath: plistPath),
            feature: .gestalt,
            reason: supervised ? "supervised:enable" : "supervised:disable"
        )
        ActivityHistory.log(
            .write,
            feature: "supervised",
            supervised ? "IsSupervised=true" : "IsSupervised=false"
        )
        SoundEffects.play(.confirm)
    }

    private static func readRoot() throws -> [String: Any] {
        let grant = ContainerStore.grantContainerAccess(containerPath)
        defer {
            if grant >= 0 { SandboxAccess.release(grant) }
        }
        guard let data = FileManager.default.contents(atPath: plistPath), !data.isEmpty else {
            throw SupervisedError.unreadable
        }
        guard let root = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any] else {
            throw SupervisedError.invalidPlist
        }
        return root
    }
}
