import Combine
import Foundation

struct RepositoryStoreAlert: Identifiable {
    let id = UUID()
    let titleKey: String
    let messageKey: String
}

@MainActor
final class PackageRepositoryStore: ObservableObject {
    @Published private(set) var sources: [RepositorySource]
    @Published private(set) var repositories: [UUID: PackageRepository] = [:]
    @Published private(set) var sourceStates: [UUID: RepositorySourceState] = [:]
    @Published private(set) var downloadingPackageKeys = Set<String>()
    @Published private(set) var downloadStartedAtByPackageKey: [String: Date] = [:]
    @Published var alert: RepositoryStoreAlert?
    @Published private var catalogSyncOperations = 0

    private static let storageKey = "repository.sources.v1"
    private static let resolutionStorageKey = "repository.package_resolutions.v1"
    private let defaults: UserDefaults
    private var resolutionIndex: RepositoryPackageResolutionIndex
    private var refreshedThisLaunch = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.resolutionStorageKey),
           let decoded = try? JSONDecoder().decode(
               RepositoryPackageResolutionIndex.self,
               from: data
           ) {
            resolutionIndex = decoded
        } else {
            resolutionIndex = RepositoryPackageResolutionIndex()
        }
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([RepositorySource].self, from: data) {
            sources = decoded
        } else {
            sources = []
        }
        // Single-source policy (operator-set): AltGallery's all-apps.json is
        // the only source. Seed it on first run and REMOVE anything else
        // persisted from earlier builds, so both fresh installs and updates
        // converge to the same one source.
        sources.removeAll {
            $0.manifestURL.absoluteString.caseInsensitiveCompare(
                AltStoreSourceAdapter.altGalleryURL.absoluteString
            ) != .orderedSame
        }
        if !sources.contains(where: {
            $0.manifestURL.absoluteString.caseInsensitiveCompare(
                AltStoreSourceAdapter.altGalleryURL.absoluteString
            ) == .orderedSame
        }) {
            let seed = RepositorySource(manifestURL: AltStoreSourceAdapter.altGalleryURL)
            sources.append(seed)
            persist()
        }
        for source in sources {
            sourceStates[source.id] = .idle
        }
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-repository") {
            installSimulatorPreviewRepository()
        }
#endif
    }

    var packages: [RepositoryPackageRecord] {
        sources.flatMap { source -> [RepositoryPackageRecord] in
            guard let repository = repositories[source.id] else {
                return []
            }
            return repository.packages.map {
                RepositoryPackageRecord(
                    sourceID: source.id,
                    sourceName: repository.name,
                    sourceURL: repository.sourceURL,
                    package: $0
                )
            }
        }
        .sorted {
            if $0.package.isFeatured != $1.package.isFeatured {
                return $0.package.isFeatured && !$1.package.isFeatured
            }
            return $0.package.name.localizedCaseInsensitiveCompare($1.package.name)
                == .orderedAscending
        }
    }

    var isRefreshing: Bool {
        catalogSyncOperations > 0 || sourceStates.values.contains(.loading)
    }

    func repository(for sourceID: UUID) -> PackageRepository? {
        repositories[sourceID]
    }

    func state(for sourceID: UUID) -> RepositorySourceState {
        sourceStates[sourceID] ?? .idle
    }

    func resolvedPackageID(for record: RepositoryPackageRecord) -> UUID? {
        resolutionIndex.packageID(
            sourceURL: record.sourceURL,
            packageIdentifier: record.package.identifier
        )
    }

    @discardableResult
    func addSource(rawURL: String) -> Bool {
        do {
            let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let candidate = URL(string: trimmed) else {
                throw PackageRepositoryError.insecureURL
            }
            let url = try PackageRepositoryURLPolicy.validate(candidate)
            guard !sources.contains(where: {
                $0.manifestURL.absoluteString.caseInsensitiveCompare(url.absoluteString)
                    == .orderedSame
            }) else {
                throw PackageRepositoryError.sourceAlreadyExists
            }
            let source = RepositorySource(manifestURL: url)
            sources.append(source)
            sourceStates[source.id] = .idle
            persist()
            refresh(source)
            return true
        } catch let error as PackageRepositoryError {
            present(error)
            return false
        } catch {
            present(.insecureURL)
            return false
        }
    }

    func removeSource(_ source: RepositorySource) {
        sources.removeAll { $0.id == source.id }
        repositories[source.id] = nil
        sourceStates[source.id] = nil
        persist()
    }

    func refreshAllIfNeeded() {
        guard !refreshedThisLaunch else { return }
        refreshedThisLaunch = true
        Task { [weak self] in
            guard let self else { return }
            await self.synchronizeDefaultSources()
            self.refreshStoredSources()
        }
    }

    func refreshAll() {
        Task { [weak self] in
            guard let self else { return }
            await self.synchronizeDefaultSources()
            self.refreshStoredSources()
        }
    }

    func refreshAllAndWait() async {
        await synchronizeDefaultSources()
        refreshStoredSources()
        while isRefreshing {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func refreshStoredSources() {
        for source in sources {
            refresh(source)
        }
    }

    private func synchronizeDefaultSources() async {
        // 3106 ships no upstream source catalog; users add their own sources.
        log("repository: default catalog disabled")
    }

    func refresh(_ source: RepositorySource) {
        guard state(for: source.id) != .loading else {
            return
        }
        sourceStates[source.id] = .loading
        Task {
            do {
                let repository = try await PackageRepositoryNetworkClient.loadRepository(
                    from: source.manifestURL
                )
                repositories[source.id] = repository
                sourceStates[source.id] = .loaded(Date())
                log(
                    "repository: loaded \(repository.identifier) " +
                    "packages=\(repository.packages.count)"
                )
            } catch let error as PackageRepositoryError {
                repositories[source.id] = nil
                sourceStates[source.id] = .failed(error)
                log("repository: failed \(source.manifestURL.host ?? "unknown") \(error)")
            } catch {
                repositories[source.id] = nil
                sourceStates[source.id] = .failed(.sourceUnavailable)
                log("repository: failed \(source.manifestURL.host ?? "unknown")")
            }
        }
    }

    func install(
        _ record: RepositoryPackageRecord,
        using patchStore: PatchProjectStore
    ) {
        let compatibility = PackageCompatibilityEvaluator.evaluate(
            record.package.supportedOS,
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild
        )
        guard compatibility == .compatible else {
            present(.incompatiblePackage)
            return
        }
        guard !downloadingPackageKeys.contains(record.id) else {
            return
        }
        downloadStartedAtByPackageKey[record.id] = Date()
        downloadingPackageKeys.insert(record.id)

        Task {
            defer {
                downloadingPackageKeys.remove(record.id)
                downloadStartedAtByPackageKey[record.id] = nil
            }
            do {
                switch record.package.kind {
                case .ipa:
                    // AltStore-format sources ship upstream release IPAs.
                    // There is no in-app sideload: download into the IPAs
                    // folder and present the share sheet so the user's own
                    // signing tool (AirDrop/Configurator/Sideloadly) takes it.
                    let url = try await PackageRepositoryNetworkClient.downloadIPA(
                        record.package
                    )
                    await MainActor.run {
                        NotificationCenter.default.post(
                            name: .repositoryShareIPA,
                            object: url
                        )
                    }
                case .patch:
                    let data = try await PackageRepositoryNetworkClient.download(
                        record.package
                    )
                    let summary = try PatchPackageCodec.inspect(data)
                    resolutionIndex.record(
                        summary.packageID,
                        sourceURL: record.sourceURL,
                        packageIdentifier: record.package.identifier
                    )
                    persistResolutionIndex()
                    let origin = PatchPackageOrigin(
                        repositoryName: record.sourceName,
                        repositoryURL: record.sourceURL,
                        packageIdentifier: record.package.identifier
                    )
                    guard patchStore.importPackage(
                        data: data,
                        password: record.package.sharedPassword,
                        origin: origin
                    ) else {
                        throw PackageRepositoryError.importUnavailable
                    }
                    log(
                        "repository: handed off \(record.package.identifier) " +
                            "to patch import"
                    )
                case .wallpaper:
                    let packageURL = try await PackageRepositoryNetworkClient
                        .downloadWallpaper(record.package)
                    defer { try? FileManager.default.removeItem(at: packageURL) }
                    try await Task.detached(priority: .userInitiated) {
                        _ = try WallpaperPackageStore.importPackage(
                            from: packageURL,
                            displayName: record.package.name,
                            repositoryIdentity: record.repositoryIdentity
                        )
                    }.value
                    alert = RepositoryStoreAlert(
                        titleKey: "wallpaper.import_done_title",
                        messageKey: "repository.wallpaper_imported"
                    )
                    log(
                        "repository: imported wallpaper " +
                            record.package.identifier
                    )
                }
            } catch let error as PackageRepositoryError {
                present(error)
            } catch let error as PatchPackageError {
                patchStore.presentImportError(error)
            } catch let error as WallpaperLabError {
                present(error)
            } catch {
                present(.sourceUnavailable)
            }
        }
    }

    func isDownloading(_ record: RepositoryPackageRecord) -> Bool {
        downloadingPackageKeys.contains(record.id)
    }

    func downloadStartedAt(for record: RepositoryPackageRecord) -> Date? {
        downloadStartedAtByPackageKey[record.id]
    }

    func isInstalled(_ record: RepositoryPackageRecord) -> Bool {
        switch record.package.kind {
        case .patch:
            return false
        case .wallpaper:
            return WallpaperPackageStore.contains(
                repositoryIdentity: record.repositoryIdentity
            )
        case .ipa:
            // IPAs are installed by the user's own signing tool, not by the
            // app — there is no in-app "installed" state to report.
            return false
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sources) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func persistResolutionIndex() {
        guard let data = try? JSONEncoder().encode(resolutionIndex) else { return }
        defaults.set(data, forKey: Self.resolutionStorageKey)
    }

    private func present(_ error: PackageRepositoryError) {
        alert = RepositoryStoreAlert(
            titleKey: "common.failed",
            messageKey: error.localizationKey
        )
    }

    private func present(_ error: WallpaperLabError) {
        alert = RepositoryStoreAlert(
            titleKey: "wallpaper.operation_failed",
            messageKey: error.localizationKey
        )
    }

#if targetEnvironment(simulator)
    private func installSimulatorPreviewRepository() {
        let sourceURL = URL(string: "https://example.com/3106/repo.json")!
        let source = RepositorySource(manifestURL: sourceURL)
        let ranges = [
            PackageOSRange(minimum: "17.0", maximum: "18.7.1", builds: nil),
            PackageOSRange(minimum: "26.0", maximum: "26.6.1", builds: nil),
            PackageOSRange(minimum: "27.0", maximum: "27.0", builds: ["24A5390f"])
        ]
        let previewPackages = [
            RepositoryPackage(
                identifier: "clean-layout",
                kind: .patch,
                name: "Clean Layout",
                author: "3106",
                version: "1.2.0",
                summary: "A compact layout patch for a cleaner app interface.",
                details: "Simulator preview package used to verify marketplace layout.",
                category: "Customization",
                tags: ["Customization", "Layout", "Featured"],
                publishedAt: ISO8601DateFormatter().date(
                    from: "2026-08-21T08:00:00Z"
                ),
                iconURL: nil,
                bannerURL: nil,
                screenshotURLs: [
                    URL(string: "https://example.com/previews/clean-layout-1.png")!,
                    URL(string: "https://example.com/previews/clean-layout-2.png")!,
                    URL(string: "https://example.com/previews/clean-layout-3.png")!
                ],
                downloadURL: URL(string: "https://example.com/clean-layout.3106")!,
                sha256: String(repeating: "a", count: 64),
                expectedSize: nil,
                supportedOS: ranges,
                changelog: "Improved spacing and added iOS 27 metadata.",
                isFeatured: true,
                isPrivate: false,
                sharedPassword: nil
            ),
            RepositoryPackage(
                identifier: "profile-switcher",
                kind: .patch,
                name: "Profile Switcher",
                author: "3106 Community",
                version: "1.0.0",
                summary: "A portable workspace example with multiple bundle targets.",
                details: nil,
                category: "Utilities",
                tags: ["Utilities", "Profiles"],
                publishedAt: ISO8601DateFormatter().date(
                    from: "2026-08-18T08:00:00Z"
                ),
                iconURL: nil,
                bannerURL: nil,
                screenshotURLs: [],
                downloadURL: URL(string: "https://example.com/profile-switcher.3106")!,
                sha256: String(repeating: "b", count: 64),
                expectedSize: nil,
                supportedOS: ranges,
                changelog: nil,
                isFeatured: false,
                isPrivate: false,
                sharedPassword: nil
            )
        ]
        sources = [source]
        repositories[source.id] = PackageRepository(
            identifier: "com.qingtang.3106.preview",
            name: "3106 Preview",
            summary: "Simulator-only marketplace preview",
            iconURL: nil,
            sourceURL: sourceURL,
            packages: previewPackages
        )
        sourceStates[source.id] = .loaded(Date())
        refreshedThisLaunch = true
    }

#endif
}

private final class PackageRepositoryRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              (try? PackageRepositoryURLPolicy.validate(url)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

enum PackageRepositoryNetworkClient {
    static func loadSourceCatalog(from catalogURL: URL) async throws -> [URL] {
        let trustedURL = try PackageRepositoryURLPolicy.validate(catalogURL)
        let download = try await downloadFile(
            from: trustedURL,
            maximumBytes: PackageRepositoryLimits.maximumCatalogBytes
        )
        defer { try? FileManager.default.removeItem(at: download.fileURL) }
        let data = try Data(contentsOf: download.fileURL, options: .mappedIfSafe)
        return try PackageRepositoryCatalogValidator.decode(
            data,
            catalogURL: download.finalURL
        )
    }

    static func loadRepository(from sourceURL: URL) async throws -> PackageRepository {
        let trustedURL = try PackageRepositoryURLPolicy.validate(sourceURL)
        let download = try await downloadFile(
            from: trustedURL,
            maximumBytes: PackageRepositoryLimits.maximumManifestBytes
        )
        defer { try? FileManager.default.removeItem(at: download.fileURL) }
        let data = try Data(contentsOf: download.fileURL, options: .mappedIfSafe)
        // AltStore-format manifests (the AltGallery default source) have no
        // schemaVersion field and would fail the native decode; dispatch on
        // the known URL so they go through the adapter instead.
        if download.finalURL.absoluteString == AltStoreSourceAdapter.altGalleryURL.absoluteString {
            return try AltStoreSourceAdapter.decode(data, sourceURL: download.finalURL)
        }
        return try PackageRepositoryValidator.decode(
            data,
            sourceURL: download.finalURL
        )
    }

    static func download(_ package: RepositoryPackage) async throws -> Data {
        guard package.kind == .patch else {
            throw PackageRepositoryError.invalidPackage
        }
        let fileURL = try await verifiedDownload(package, maximumBytes: nil)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        return try Data(contentsOf: fileURL, options: .mappedIfSafe)
    }

    /// Download an upstream IPA into Documents/3106/IPAs, overwriting a
    /// previous release of the same app (bundle identifier is the name key).
    /// 512 MB cap: upstream releases are single-digit MB to a few hundred;
    /// anything larger is almost certainly a wrong link.
    static func downloadIPA(_ package: RepositoryPackage) async throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("3106/IPAs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = package.identifier
            .replacingOccurrences(of: "/", with: "_")
        let destination = dir
            .appendingPathComponent("\(safeName)-\(package.version).ipa")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let (fileURL, _) = try await downloadFile(
            from: package.downloadURL,
            maximumBytes: 512 * 1024 * 1024
        )
        try FileManager.default.moveItem(at: fileURL, to: destination)
        return destination
    }

    static func downloadWallpaper(_ package: RepositoryPackage) async throws -> URL {
        guard package.kind == .wallpaper else {
            throw PackageRepositoryError.invalidPackage
        }
        return try await verifiedDownload(
            package,
            maximumBytes: Int(WallpaperLabLimits.maximumArchiveBytes)
        )
    }

    private static func verifiedDownload(
        _ package: RepositoryPackage,
        maximumBytes: Int?
    ) async throws -> URL {
        let download = try await downloadFile(
            from: package.downloadURL,
            maximumBytes: maximumBytes
        )
        do {
            let values = try download.fileURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey]
            )
            guard values.isRegularFile == true else {
                throw PackageRepositoryError.sourceUnavailable
            }
            if let expectedSize = package.expectedSize {
                guard let fileSize = values.fileSize,
                      fileSize >= 0,
                      UInt64(fileSize) == expectedSize else {
                    throw PackageRepositoryError.checksumMismatch
                }
            }
            if let expectedDigest = package.sha256 {
                guard try PackageDigest.sha256Hex(fileURL: download.fileURL)
                    .caseInsensitiveCompare(expectedDigest) == .orderedSame else {
                    throw PackageRepositoryError.checksumMismatch
                }
            }
            return download.fileURL
        } catch {
            try? FileManager.default.removeItem(at: download.fileURL)
            throw error
        }
    }

    private static func downloadFile(
        from rawURL: URL,
        maximumBytes: Int?
    ) async throws -> (fileURL: URL, finalURL: URL) {
        let url = try PackageRepositoryURLPolicy.validate(rawURL)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = PackageRepositoryRedirectDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.setValue("3106", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await session.download(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              let finalURL = response.url,
              (try? PackageRepositoryURLPolicy.validate(finalURL)) != nil else {
            throw PackageRepositoryError.sourceUnavailable
        }
        if let maximumBytes {
            let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
            guard let byteCount = values.fileSize, byteCount <= maximumBytes else {
                throw PackageRepositoryError.invalidManifest
            }
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
            .appendingPathExtension(rawURL.pathExtension)
        do {
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            return (destination, finalURL)
        } catch {
            throw PackageRepositoryError.sourceUnavailable
        }
    }
}

extension Notification.Name {
    static let repositoryShareIPA = Notification.Name("repositoryShareIPA")
}
