import Foundation

/// Cumulative cleaner statistics and per-clean history, persisted locally.
/// Port of Erosion-CN's `totalFreedBytesHistory` idea, extended with a full
/// history trail (WQManager History-tab parity, UI lives in the backup tab).
struct CleanerHistoryEntry: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let cleanedAppCount: Int
    let failedItemCount: Int
    let freedBytes: Int64
    let crashLogsRemoved: Int
    let crashLogBytes: Int64

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        cleanedAppCount: Int,
        failedItemCount: Int,
        freedBytes: Int64,
        crashLogsRemoved: Int = 0,
        crashLogBytes: Int64 = 0
    ) {
        self.id = id
        self.date = date
        self.cleanedAppCount = cleanedAppCount
        self.failedItemCount = failedItemCount
        self.freedBytes = freedBytes
        self.crashLogsRemoved = crashLogsRemoved
        self.crashLogBytes = crashLogBytes
    }

    var totalFreedBytes: Int64 { freedBytes + crashLogBytes }
}

enum CleanerHistory {
    private static let maxEntries = 100
    private static let fileName = "cleaner-history.plist"

    /// Injectable root for tests: the policy harness runs as a bare CLI
    /// binary whose documentDirectory IS the developer's real ~/Documents,
    /// so tests must redirect the store to a temp dir.
    nonisolated(unsafe) private static var injectedRoot: URL?

    static func setRootForTesting(_ root: URL?) {
        injectedRoot = root
    }

    private static var fileURL: URL {
        let base = injectedRoot
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return base!.appendingPathComponent(fileName)
    }

    // MARK: - Persistence

    private struct StoredEntry {
        let id: UUID
        let date: Date
        let cleanedAppCount: Int
        let failedItemCount: Int
        let freedBytes: Int64
        let crashLogsRemoved: Int
        let crashLogBytes: Int64

        func encode() -> [String: Any] {
            [
                "id": id.uuidString,
                "date": date,
                "cleanedAppCount": cleanedAppCount,
                "failedItemCount": failedItemCount,
                "freedBytes": freedBytes,
                "crashLogsRemoved": crashLogsRemoved,
                "crashLogBytes": crashLogBytes,
            ]
        }

        static func decode(_ dict: [String: Any]) -> StoredEntry? {
            guard
                let idString = dict["id"] as? String,
                let id = UUID(uuidString: idString),
                let date = dict["date"] as? Date,
                let cleanedAppCount = dict["cleanedAppCount"] as? Int,
                let failedItemCount = dict["failedItemCount"] as? Int,
                let freedBytes = dict["freedBytes"] as? Int64
            else { return nil }
            return StoredEntry(
                id: id,
                date: date,
                cleanedAppCount: cleanedAppCount,
                failedItemCount: failedItemCount,
                freedBytes: freedBytes,
                crashLogsRemoved: dict["crashLogsRemoved"] as? Int ?? 0,
                crashLogBytes: dict["crashLogBytes"] as? Int64 ?? 0
            )
        }
    }

    static func loadEntries() -> [CleanerHistoryEntry] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [[String: Any]]
        else { return [] }
        return plist.compactMap { dict in
            guard let stored = StoredEntry.decode(dict) else { return nil }
            return CleanerHistoryEntry(
                id: stored.id,
                date: stored.date,
                cleanedAppCount: stored.cleanedAppCount,
                failedItemCount: stored.failedItemCount,
                freedBytes: stored.freedBytes,
                crashLogsRemoved: stored.crashLogsRemoved,
                crashLogBytes: stored.crashLogBytes
            )
        }
        .sorted { $0.date > $1.date }
    }

    @discardableResult
    static func record(_ entry: CleanerHistoryEntry) -> [CleanerHistoryEntry] {
        var entries = loadEntries()
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        persist(entries)
        return entries
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func persist(_ entries: [CleanerHistoryEntry]) {
        let plist = entries.map { entry -> [String: Any] in
            StoredEntry(
                id: entry.id,
                date: entry.date,
                cleanedAppCount: entry.cleanedAppCount,
                failedItemCount: entry.failedItemCount,
                freedBytes: entry.freedBytes,
                crashLogsRemoved: entry.crashLogsRemoved,
                crashLogBytes: entry.crashLogBytes
            ).encode()
        }
        guard
            let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .binary, options: 0
            )
        else { return }
        // Atomic write so a crash mid-clean never corrupts the history.
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Aggregates

    static func totalFreedBytes(in entries: [CleanerHistoryEntry]) -> Int64 {
        entries.reduce(0) { $0 + $1.totalFreedBytes }
    }

    static func totalCleanedApps(in entries: [CleanerHistoryEntry]) -> Int {
        entries.reduce(0) { $0 + $1.cleanedAppCount }
    }
}
