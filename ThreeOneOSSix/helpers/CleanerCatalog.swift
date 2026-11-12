import Foundation

struct CleanerResolvedApplication: Equatable {
    let bundleID: String
    let name: String
    let containerPath: String
    let version: String
}

struct CleanerCatalogRecord: Equatable {
    let application: CleanerResolvedApplication
    let containerPath: String
    let usage: LimitedCleanerUsage

    var bundleID: String { application.bundleID }
}

enum CleanerSortOrder: String, CaseIterable, Identifiable {
    case largestFirst
    case smallestFirst

    var id: String { rawValue }
}

enum CleanerCatalog {
    static func sorted<Record>(
        _ records: [Record],
        order: CleanerSortOrder,
        size: (Record) -> Int64,
        displayName: (Record) -> String,
        stableID: (Record) -> String
    ) -> [Record] {
        records.sorted { left, right in
            let leftSize = size(left)
            let rightSize = size(right)
            if leftSize != rightSize {
                switch order {
                case .largestFirst:
                    return leftSize > rightSize
                case .smallestFirst:
                    return leftSize < rightSize
                }
            }

            let nameComparison = displayName(left).localizedCaseInsensitiveCompare(displayName(right))
            if nameComparison != .orderedSame {
                return nameComparison == .orderedAscending
            }
            return stableID(left).localizedCaseInsensitiveCompare(stableID(right)) == .orderedAscending
        }
    }

    static func selectingAllVisible(
        _ visibleBundleIDs: [String],
        preserving selectedBundleIDs: Set<String>
    ) -> Set<String> {
        selectedBundleIDs.union(visibleBundleIDs)
    }

    static func scanNewApplications(
        _ applications: [CleanerResolvedApplication],
        scannedBundleIDs: inout Set<String>,
        shouldIncludeBundleID: (String) -> Bool,
        activateContainer: (CleanerResolvedApplication) -> String?,
        isValidContainerPath: (String) -> Bool,
        usageForContainer: (String) -> LimitedCleanerUsage?,
        onApplication: ((String) -> Void)? = nil,
        onRecord: ((CleanerCatalogRecord) -> Void)? = nil
    ) -> [CleanerCatalogRecord] {
        var records: [CleanerCatalogRecord] = []
        for application in applications {
            let bundleID = application.bundleID
            defer { onApplication?(bundleID) }
            // Do not mark an app as scanned until its container was actually
            // resolved and measured; otherwise a failed MCM/LS pass hides the
            // filesystem fallback for the same bundle id.
            guard shouldIncludeBundleID(bundleID),
                  !scannedBundleIDs.contains(bundleID),
                  let containerPath = activateContainer(application),
                  isValidContainerPath(containerPath),
                  let usage = usageForContainer(containerPath),
                  usage.totalBytes > 0 else {
                continue
            }
            scannedBundleIDs.insert(bundleID)
            let record = CleanerCatalogRecord(
                application: application,
                containerPath: containerPath,
                usage: usage
            )
            records.append(record)
            onRecord?(record)
        }
        return records
    }
}
