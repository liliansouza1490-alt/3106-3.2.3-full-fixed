import Foundation

/// AltStore-format source adapter: bridges the AltGallery `all-apps.json`
/// manifest (the operator's only configured source) into the native
/// `PackageRepository` model. AltStore manifests have no schemaVersion and
/// package entries are `apps[]` with `versions[]`, so the adapter maps the
/// newest version of each app to a `.ipa`-kind repository package.
///
/// Mapping notes:
/// - `bundleIdentifier` → package identifier
/// - `versions[0]` (newest first) → version/downloadURL/size/changelog
/// - `minOSVersion` ("12.0" style) → a single wide supportedOS range; the
///   native compatibility evaluator still gates the install button.
/// - `sha256CertFingerprints` (AltStore signing pins) do NOT apply here —
///   these are upstream release IPAs, downloaded and re-signed by the user's
///   own tool, so the field is ignored rather than enforced.
enum AltStoreSourceAdapter {

    static let altGalleryURL = URL(string: "https://raw.githubusercontent.com/bebound/AltGallery/refs/heads/master/all-apps.json")!

    struct AltStoreApp: Decodable {
        let name: String
        let bundleIdentifier: String
        let developerName: String?
        let subtitle: String?
        let localizedDescription: String?
        let iconURL: String?
        let versions: [AltStoreVersion]?
    }

    struct AltStoreVersion: Decodable {
        let version: String
        let date: String?
        let localizedDescription: String?
        let downloadURL: String
        let size: Int?
        let minOSVersion: String?
    }

    struct AltStoreManifest: Decodable {
        let name: String?
        let subtitle: String?
        let iconURL: String?
        let apps: [AltStoreApp]
    }

    enum AdapterError: Error, Equatable {
        case invalidManifest
        case tooLarge
    }

    /// Parse an AltStore manifest into the native repository model.
    /// Size limits mirror PackageRepositoryLimits so a hostile manifest
    /// cannot balloon memory.
    static func decode(_ data: Data, sourceURL: URL) throws -> PackageRepository {
        guard data.count <= PackageRepositoryLimits.maximumManifestBytes else {
            throw AdapterError.tooLarge
        }
        let manifest: AltStoreManifest
        do {
            manifest = try JSONDecoder().decode(AltStoreManifest.self, from: data)
        } catch {
            throw AdapterError.invalidManifest
        }
        guard !manifest.apps.isEmpty,
              manifest.apps.count <= PackageRepositoryLimits.maximumPackageCount else {
            throw AdapterError.invalidManifest
        }

        var seen = Set<String>()
        var packages: [RepositoryPackage] = []
        packages.reserveCapacity(manifest.apps.count)

        for app in manifest.apps {
            guard let latest = app.versions?.first,
                  let rawDownload = URL(string: latest.downloadURL),
                  let downloadURL = try? PackageRepositoryURLPolicy.validate(rawDownload) else {
                // A single bad entry (non-https, odd port, …) must not
                // drop the other 60 apps from the gallery.
                continue
            }
            guard seen.insert(app.bundleIdentifier).inserted else {
                continue
            }

            // PackageOSRange.maximum is a non-optional String, so "no upper
            // bound" is expressed with a far-future sentinel rather than nil.
            let sentinelMax = "99.0.0"
            let supportedOS: [PackageOSRange]
            if let minOS = latest.minOSVersion, !minOS.isEmpty {
                supportedOS = [PackageOSRange(minimum: minOS, maximum: sentinelMax, builds: nil)]
            } else {
                supportedOS = [PackageOSRange(minimum: "12.0", maximum: sentinelMax, builds: nil)]
            }

            let publishedAt: Date? = latest.date.flatMap {
                ISO8601DateFormatter().date(from: $0)
            }

            packages.append(RepositoryPackage(
                identifier: app.bundleIdentifier,
                kind: .ipa,
                name: app.name,
                author: app.developerName ?? "AltGallery",
                version: latest.version,
                summary: app.subtitle ?? "",
                details: app.localizedDescription,
                category: nil,
                tags: [],
                publishedAt: publishedAt,
                iconURL: app.iconURL.flatMap(URL.init(string:)),
                bannerURL: nil,
                screenshotURLs: [],
                downloadURL: downloadURL,
                sha256: nil,
                expectedSize: latest.size.map(UInt64.init),
                supportedOS: supportedOS,
                changelog: latest.localizedDescription,
                isFeatured: false,
                isPrivate: false,
                sharedPassword: nil
            ))
        }

        guard !packages.isEmpty else {
            throw AdapterError.invalidManifest
        }

        return PackageRepository(
            identifier: "altgallery",
            name: manifest.name ?? "AltGallery",
            summary: manifest.subtitle,
            iconURL: manifest.iconURL.flatMap(URL.init(string:)),
            sourceURL: sourceURL,
            packages: packages
        )
    }
}
