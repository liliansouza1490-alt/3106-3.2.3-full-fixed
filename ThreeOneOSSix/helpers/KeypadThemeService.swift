import Foundation

enum KeypadKey: String, CaseIterable, Identifiable {
    case one, two, three, four, five, six, seven, eight, nine, star, zero, pound

    var id: String { rawValue }

    var fileKey: String {
        switch self {
        case .one: return "-1-"
        case .two: return "-2-A B C"
        case .three: return "-3-D E F"
        case .four: return "-4-G H I"
        case .five: return "-5-J K L"
        case .six: return "-6-M N O"
        case .seven: return "-7-P Q R S"
        case .eight: return "-8-T U V"
        case .nine: return "-9-W X Y Z"
        case .star: return "-*-"
        case .zero: return "-0-+"
        case .pound: return "-#-"
        }
    }

    var label: String {
        switch self {
        case .one: return "1"
        case .two: return "2 ABC"
        case .three: return "3 DEF"
        case .four: return "4 GHI"
        case .five: return "5 JKL"
        case .six: return "6 MNO"
        case .seven: return "7 PQRS"
        case .eight: return "8 TUV"
        case .nine: return "9 WXYZ"
        case .star: return "✱"
        case .zero: return "0 +"
        case .pound: return "#"
        }
    }

    static let variants = [
        "--mask.png",
        "--white.png",
        "-hi-mask.png",
        "-hi-white.png",
        "--white-bold.png",
        "--mask-bold.png",
    ]
}

struct KeypadThemeState {
    let containerPath: String
    let telephonyPath: String
    let regCode: String
    let images: [KeypadKey: Data]
}

enum KeypadThemeError: Error, Equatable {
    case phoneAppUnavailable
    case telephonyCacheUnavailable
    case accessDenied
    case imageInvalid
    case writeFailed
    case noBackup
}

extension KeypadThemeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .phoneAppUnavailable: return "The Phone app container is unavailable."
        case .telephonyCacheUnavailable: return "The Phone app keypad cache was not found."
        case .accessDenied: return "Sandbox access to the Phone app was denied."
        case .imageInvalid: return "The selected image could not be read."
        case .writeFailed: return "The keypad image could not be written."
        case .noBackup: return "There is no original keypad backup to restore."
        }
    }

    var localizationKey: String {
        switch self {
        case .phoneAppUnavailable: return "keypad.error.phone_unavailable"
        case .telephonyCacheUnavailable: return "keypad.error.cache_unavailable"
        case .accessDenied: return "keypad.error.access"
        case .imageInvalid: return "keypad.error.image"
        case .writeFailed: return "keypad.error.write"
        case .noBackup: return "keypad.error.no_backup"
        }
    }
}

enum KeypadThemeService {
    private static let bundleID = "com.apple.mobilephone"
    private static let appliedTargetsKey = "keypad.appliedTargets"

    static func load() throws -> KeypadThemeState {
        let (container, directory, regCode, grant) = try resolve()
        defer {
            if grant >= 0 { SandboxAccess.release(grant) }
        }

        var images: [KeypadKey: Data] = [:]
        for key in KeypadKey.allCases {
            for variant in KeypadKey.variants {
                let url = directory.appendingPathComponent(regCode + key.fileKey + variant)
                if let data = try? Data(contentsOf: url), !data.isEmpty {
                    images[key] = data
                    break
                }
            }
        }
        return KeypadThemeState(
            containerPath: container,
            telephonyPath: directory.path,
            regCode: regCode,
            images: images
        )
    }

    static func apply(images: [KeypadKey: Data]) throws {
        guard !images.isEmpty else { return }
        let (_, directory, regCode, grant) = try resolve()
        defer {
            if grant >= 0 { SandboxAccess.release(grant) }
        }

        var applied = Set(UserDefaults.standard.stringArray(forKey: appliedTargetsKey) ?? [])
        for (key, data) in images {
            guard !data.isEmpty else { throw KeypadThemeError.imageInvalid }
            for variant in KeypadKey.variants {
                let target = directory.appendingPathComponent(regCode + key.fileKey + variant)
                do {
                    try VerifiedFileWriter.write(
                        data,
                        to: target,
                        feature: .keypad,
                        reason: "keypad \(key.rawValue)"
                    )
                    applied.insert(target.path)
                } catch {
                    throw KeypadThemeError.writeFailed
                }
            }
        }
        UserDefaults.standard.set(Array(applied), forKey: appliedTargetsKey)
    }

    static func reset() throws {
        let (_, directory, _, grant) = try resolve()
        defer {
            if grant >= 0 { SandboxAccess.release(grant) }
        }

        let originals = BackupCenter.shared.records(feature: .keypad)
            .filter { $0.kind == .original }
        var restoredPaths = Set<String>()
        for record in originals {
            if (try? BackupCenter.shared.restore(record)) != nil {
                restoredPaths.insert(record.targetPath)
            }
        }

        let applied = Set(UserDefaults.standard.stringArray(forKey: appliedTargetsKey) ?? [])
        guard !applied.isEmpty || !restoredPaths.isEmpty else {
            throw KeypadThemeError.noBackup
        }
        for path in applied where !restoredPaths.contains(path) {
            let url = URL(fileURLWithPath: path)
            guard url.deletingLastPathComponent().standardizedFileURL.path
                    == directory.standardizedFileURL.path else { continue }
            if FileManager.default.fileExists(atPath: path) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        UserDefaults.standard.removeObject(forKey: appliedTargetsKey)
    }

    private static func resolve() throws -> (String, URL, String, Int64) {
        let container: String
        if let resolved = ContainerStore.resolveAppContainerPath(bundleID: bundleID),
           ContainerStore.isApplicationContainerPath(resolved) {
            container = resolved
        } else if let mapped = ContainerStore.launchServicesSnapshot()?
                    .containerPath(forBundleID: bundleID),
                  ContainerStore.isApplicationContainerPath(mapped) {
            container = mapped
        } else {
            throw KeypadThemeError.phoneAppUnavailable
        }

        let grant = ContainerStore.grantContainerAccess(container)
        if grant < 0, SandboxAccess.backend != .kernel {
            throw KeypadThemeError.accessDenied
        }

        let caches = URL(fileURLWithPath: container, isDirectory: true)
            .appendingPathComponent("Library/Caches", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: caches,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let telephony = entries
            .filter { $0.lastPathComponent.hasPrefix("TelephonyUI-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first
        guard let telephony else {
            if grant >= 0 { SandboxAccess.release(grant) }
            throw KeypadThemeError.telephonyCacheUnavailable
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: telephony,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let regCode = files.first
            .flatMap { $0.lastPathComponent.split(separator: "-").first.map(String.init) }
            ?? "other"
        return (container, telephony, regCode, grant)
    }
}