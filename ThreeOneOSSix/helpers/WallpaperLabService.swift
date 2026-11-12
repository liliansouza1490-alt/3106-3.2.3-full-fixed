import Foundation
import Darwin

struct WallpaperAccessReport: Equatable {
    let layout: WallpaperPosterLayout
    let descriptorCount: Int
    let customDescriptorCount: Int
    let canInstall: Bool
    let deniedExtensionIdentifiers: [String]
}

enum WallpaperAccessProbe {
    static func probe(
        containerURL: URL,
        rootValidator: WallpaperLayoutScanner.RootValidator,
        requiredExtensionIdentifiers: Set<String>? = nil,
        fileManager: FileManager = .default
    ) throws -> WallpaperAccessReport {
        // worse_query grants are path-scoped; the layout store and every
        // descriptor directory must be granted before any mkdir/read.
        let containerGrant = ContainerStore.grantContainerAccess(containerURL.path)
        defer { SandboxAccess.release(containerGrant) }
        var descriptorGrants: [Int64] = []
        defer {
            for grant in descriptorGrants { SandboxAccess.release(grant) }
        }

        let layout = try WallpaperLayoutScanner.scan(
            containerURL: containerURL,
            rootValidator: rootValidator,
            requiredExtensionIdentifiers: requiredExtensionIdentifiers,
            allowSyntheticLayout: true,
            fileManager: fileManager
        )
        var descriptorCount = 0
        var customDescriptorCount = 0
        for descriptorDirectory in layout.extensionDescriptorDirectories.values {
            let grant = ContainerStore.grantContainerAccess(descriptorDirectory.path)
            if grant >= 0 { descriptorGrants.append(grant) }
            let children = (try? fileManager.contentsOfDirectory(
                at: descriptorDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )) ?? []
            for child in children {
                let name = child.lastPathComponent
                if name.hasPrefix(".") && !name.hasPrefix(".3106-wallpaper-") { continue }
                let values = try? child.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                descriptorCount += 1
                if WallpaperDescriptorIdentity.isCustom(at: child, fileManager: fileManager) {
                    customDescriptorCount += 1
                }
            }
        }

        let requiredIdentifiers: [String]
        if let requiredExtensionIdentifiers {
            requiredIdentifiers = requiredExtensionIdentifiers.sorted()
        } else if layout.supportsCollections {
            requiredIdentifiers = [WallpaperPosterLayout.collectionsExtension]
        } else {
            requiredIdentifiers = layout.extensionDescriptorDirectories.keys.sorted()
        }
        var deniedIdentifiers = requiredIdentifiers.filter {
            layout.extensionDescriptorDirectories[$0] == nil
        }

        for identifier in requiredIdentifiers where !deniedIdentifiers.contains(identifier) {
            guard let descriptorDirectory = layout.extensionDescriptorDirectories[identifier] else {
                continue
            }

            let grant = ContainerStore.grantContainerAccess(descriptorDirectory.path)
            if grant >= 0 { descriptorGrants.append(grant) }
            let probeURL = descriptorDirectory.appendingPathComponent(
                ".3106-wallpaper-probe-\(UUID().uuidString)",
                isDirectory: true
            )
            let created = mkdir(probeURL.path, 0o700) == 0
            if !created {
                log("wallpaper: probe denied \(identifier) errno=\(errno) path=\(descriptorDirectory.path)")
            }
            if created {
                let descriptor = open(
                    probeURL.path,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                if descriptor >= 0 { close(descriptor) }
                if rmdir(probeURL.path) != 0 || descriptor < 0 {
                    deniedIdentifiers.append(identifier)
                    try? fileManager.removeItem(at: probeURL)
                }
            } else {
                deniedIdentifiers.append(identifier)
            }
        }

        return WallpaperAccessReport(
            layout: layout,
            descriptorCount: descriptorCount,
            customDescriptorCount: customDescriptorCount,
            canInstall: !requiredIdentifiers.isEmpty
                && deniedIdentifiers.isEmpty,
            deniedExtensionIdentifiers: deniedIdentifiers
        )
    }
}

enum WallpaperDeviceAccessService {
    /// Resolve PosterBoard's container without relying on MCM or the bundle-id
    /// index alone: scan app-data containers for the poster store directory.
    static func containerPath() -> String? {
        if let path = ContainerStore.resolveAppContainerPath(
            bundleID: "com.apple.PosterBoard"
        ) {
            log("wallpaper: PosterBoard container=\(path)")
            return path
        }

        let identifiers = worse_query_path_identifiers()
        if let path = identifiers.first(where: { $0.value == "com.apple.PosterBoard" })?.key {
            log("wallpaper: PosterBoard container=\(path) (reverse index)")
            return path
        }

        let storeRelativePath = WallpaperLayoutScanner.storeRelativePath
        for directory in ContainerStore.enumerateDirectories(path: ContainerStore.appDataRoot) {
            let grant = ContainerStore.grantContainerAccess(directory)
            let storePath = (directory as NSString).appendingPathComponent(storeRelativePath)
            let exists = FileManager.default.fileExists(atPath: storePath)
            if grant >= 0 { SandboxAccess.release(grant) }
            if exists {
                log("wallpaper: PosterBoard container=\(directory) (poster store scan)")
                return directory
            }
        }

        let posterIDs = Set(
            identifiers.values.filter { $0.localizedCaseInsensitiveContains("PosterBoard") }
        )
        log("wallpaper: PosterBoard container unavailable ids=\(posterIDs.sorted())")
        return nil
    }

    static func report(
        requiredExtensionIdentifiers: Set<String>? = nil
    ) throws -> WallpaperAccessReport {
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-wallpaper-data") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "3106-Simulated-PosterBoard",
                isDirectory: true
            )
            let descriptors = root.appendingPathComponent(
                "Library/Application Support/PRBPosterExtensionDataStore/72/Extensions/" +
                    "com.apple.WallpaperKit.CollectionsPoster/descriptors",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: descriptors,
                withIntermediateDirectories: true
            )
            return try WallpaperAccessProbe.probe(
                containerURL: root,
                rootValidator: { WallpaperLayoutScanner.sameDirectory($0, root) },
                requiredExtensionIdentifiers: requiredExtensionIdentifiers
            )
        }
#endif
        guard let path = containerPath() else {
            throw WallpaperLabError.accessDenied
        }
        do {
            let report = try WallpaperAccessProbe.probe(
                containerURL: URL(fileURLWithPath: path, isDirectory: true),
                rootValidator: { ContainerStore.isApplicationContainerPath($0.path) },
                requiredExtensionIdentifiers: requiredExtensionIdentifiers
            )
            log("wallpaper: canInstall=\(report.canInstall) denied=\(report.deniedExtensionIdentifiers)")
            return report
        } catch {
            log("wallpaper: probe failed error=\(error)")
            throw error
        }
    }

    static func install(
        _ package: WallpaperStagedPackage
    ) throws -> (WallpaperInstallReceipt, WallpaperAccessReport) {
        let requiredExtensions = Set(
            package.payload.descriptors.map(\.extensionIdentifier)
        )
        let currentReport = try report(
            requiredExtensionIdentifiers: requiredExtensions
        )
        guard currentReport.canInstall else {
            throw WallpaperLabError.accessDenied
        }
        let backupRoot = try WallpaperPackageStore.backupRoot()
        let receipt = try WallpaperInstaller.install(
            payload: package.payload,
            layout: currentReport.layout,
            backupRoot: backupRoot
        )
        do {
            try WallpaperPackageStore.delete(package)
        } catch {
            log("wallpaper: staged package leftover after apply")
        }
        return (
            receipt,
            try report(requiredExtensionIdentifiers: requiredExtensions)
        )
    }

    static func resetCustomCollections() throws -> (Int, WallpaperAccessReport) {
        let currentReport = try report()
        guard currentReport.canInstall else {
            throw WallpaperLabError.accessDenied
        }
        guard let path = containerPath() else {
            throw WallpaperLabError.accessDenied
        }
        let containerURL = URL(fileURLWithPath: path, isDirectory: true)
        let backupRoot = try WallpaperPackageStore.backupRoot()
        let removed = try WallpaperInstaller.resetCustomDescriptors(
            layout: currentReport.layout,
            containerURL: containerURL,
            rootValidator: { ContainerStore.isApplicationContainerPath($0.path) },
            backupRoot: backupRoot
        )
        return (removed, try report())
    }
}

struct WallpaperStagedPackage: Identifiable, Equatable {
    let id: UUID
    let displayName: String
    let repositoryIdentity: String?
    let packageDirectoryURL: URL
    let archiveURL: URL
    let extractedURL: URL
    let payload: TendiesPayload
    let importedAt: Date
}

enum WallpaperPackageStore {
    private static let archiveName = "wallpaper.tendies"
    private static let extractedName = "Extracted"
    private static let metadataName = "metadata.plist"

    static func stagingRoot(fileManager: FileManager = .default) throws -> URL {
        let base = try applicationSupportURL(fileManager: fileManager)
        let url = base.appendingPathComponent("WallpaperLab/Packages", isDirectory: true)
        try createApprovedDirectory(url, fileManager: fileManager)
        return url
    }

    static func backupRoot(fileManager: FileManager = .default) throws -> URL {
        let base = try applicationSupportURL(fileManager: fileManager)
        let url = base.appendingPathComponent("WallpaperLab/Backups", isDirectory: true)
        try createApprovedDirectory(url, fileManager: fileManager)
        return url
    }

    static func importPackage(
        from sourceURL: URL,
        displayName: String? = nil,
        repositoryIdentity: String? = nil,
        fileManager: FileManager = .default
    ) throws -> WallpaperStagedPackage {
        guard sourceURL.pathExtension.lowercased() == "tendies" else {
            throw WallpaperLabError.unsupportedPackage
        }
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let values = try sourceURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw WallpaperLabError.symbolicLinkUnsupported
        }
        let size = Int64(values.fileSize ?? 0)
        guard size > 0, size <= WallpaperLabLimits.maximumArchiveBytes else {
            throw WallpaperLabError.packageTooLarge
        }
        let resolvedDisplayName = (
            displayName ?? sourceURL.deletingPathExtension().lastPathComponent
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidMetadataText(resolvedDisplayName, maximumBytes: 255),
              repositoryIdentity.map({
                  isValidMetadataText($0, maximumBytes: 4_096)
              }) ?? true else {
            throw WallpaperLabError.unsupportedPackage
        }

        let root = try stagingRoot(fileManager: fileManager)
        let id = UUID()
        let importingURL = root.appendingPathComponent(
            ".importing-\(id.uuidString)",
            isDirectory: true
        )
        let finalURL = root.appendingPathComponent(id.uuidString, isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: importingURL,
                withIntermediateDirectories: false
            )
            let archiveURL = importingURL.appendingPathComponent(archiveName)
            try fileManager.copyItem(at: sourceURL, to: archiveURL)
            let extractedURL = importingURL.appendingPathComponent(
                extractedName,
                isDirectory: true
            )
            log("wallpaper: extracting \(sourceURL.lastPathComponent) bytes=\(size)")
            _ = try SecureZIPArchive.extract(
                archiveURL: archiveURL,
                destinationURL: extractedURL,
                fileManager: fileManager
            )
            log("wallpaper: extracted \(sourceURL.lastPathComponent)")
            let inspected = try TendiesPackageInspector.inspectExtractedPackage(
                at: extractedURL,
                fileManager: fileManager
            )
            log(
                "wallpaper: inspected \(sourceURL.lastPathComponent) " +
                    "descriptors=\(inspected.descriptors.count)"
            )
            let metadata = PackageMetadata(
                id: id,
                displayName: resolvedDisplayName,
                repositoryIdentity: repositoryIdentity,
                importedAt: Date()
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(metadata).write(
                to: importingURL.appendingPathComponent(metadataName),
                options: .atomic
            )
            guard rename(importingURL.path, finalURL.path) == 0 else {
                throw WallpaperLabError.unsafeArchive
            }
            let importedPackage = try loadPackage(
                at: finalURL,
                fileManager: fileManager
            )
            if let repositoryIdentity {
                for existingPackage in packages(fileManager: fileManager)
                where existingPackage.id != importedPackage.id
                    && existingPackage.repositoryIdentity == repositoryIdentity {
                    try? delete(existingPackage, fileManager: fileManager)
                }
            }
            return importedPackage
        } catch let error as WallpaperLabError {
            try? fileManager.removeItem(at: importingURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: importingURL)
            throw WallpaperLabError.unsupportedPackage
        }
    }

    static func packages(fileManager: FileManager = .default) -> [WallpaperStagedPackage] {
        guard let root = try? stagingRoot(fileManager: fileManager),
              let directories = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return directories.compactMap { directory in
            guard UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
            return try? loadPackage(at: directory, fileManager: fileManager)
        }.sorted { $0.importedAt > $1.importedAt }
    }

    static func contains(
        repositoryIdentity: String,
        fileManager: FileManager = .default
    ) -> Bool {
        packages(fileManager: fileManager).contains {
            $0.repositoryIdentity == repositoryIdentity
        }
    }

    static func delete(
        _ package: WallpaperStagedPackage,
        fileManager: FileManager = .default
    ) throws {
        let root = try stagingRoot(fileManager: fileManager)
        guard package.packageDirectoryURL.deletingLastPathComponent().standardizedFileURL
                == root.standardizedFileURL,
              package.packageDirectoryURL.lastPathComponent == package.id.uuidString else {
            throw WallpaperLabError.unsafeArchive
        }
        try WallpaperLayoutScanner.validateDirectory(
            package.packageDirectoryURL,
            fileManager: fileManager
        )
        try fileManager.removeItem(at: package.packageDirectoryURL)
    }

    private static func loadPackage(
        at directory: URL,
        fileManager: FileManager
    ) throws -> WallpaperStagedPackage {
        try WallpaperLayoutScanner.validateDirectory(directory, fileManager: fileManager)
        let metadataData = try Data(contentsOf: directory.appendingPathComponent(metadataName))
        let metadata = try PropertyListDecoder().decode(PackageMetadata.self, from: metadataData)
        guard directory.lastPathComponent == metadata.id.uuidString,
              !metadata.displayName.isEmpty,
              metadata.displayName.utf8.count <= 255 else {
            throw WallpaperLabError.unsupportedPackage
        }
        let archiveURL = directory.appendingPathComponent(archiveName)
        let extractedURL = directory.appendingPathComponent(extractedName, isDirectory: true)
        let payload = try TendiesPackageInspector.inspectExtractedPackage(
            at: extractedURL,
            fileManager: fileManager
        )
        return WallpaperStagedPackage(
            id: metadata.id,
            displayName: metadata.displayName,
            repositoryIdentity: metadata.repositoryIdentity,
            packageDirectoryURL: directory,
            archiveURL: archiveURL,
            extractedURL: extractedURL,
            payload: payload,
            importedAt: metadata.importedAt
        )
    }

    private static func applicationSupportURL(fileManager: FileManager) throws -> URL {
        guard let url = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw WallpaperLabError.accessDenied
        }
        try createApprovedDirectory(url, fileManager: fileManager)
        return url
    }

    private static func createApprovedDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        if fileManager.fileExists(atPath: url.path) {
            try WallpaperLayoutScanner.validateDirectory(url, fileManager: fileManager)
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private static func isValidMetadataText(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains(
                where: CharacterSet.controlCharacters.contains
            )
    }
}

private struct PackageMetadata: Codable {
    let id: UUID
    let displayName: String
    let repositoryIdentity: String?
    let importedAt: Date
}
