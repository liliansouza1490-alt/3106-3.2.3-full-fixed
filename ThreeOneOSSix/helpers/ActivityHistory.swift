import Foundation

/// Unified activity timeline (WQManager History parity): one persisted log
/// for backup / restore / clean / write events so the backup tab can show
/// "what happened to this device and when" across features.
struct ActivityEvent: Identifiable, Equatable {
    enum Kind: String, Codable {
        case backup
        case restore
        case clean
        case write
    }

    let id: UUID
    let date: Date
    let kind: Kind
    /// Localization-free summary: feature tag + target, e.g. "gestalt ·
    /// preset:aod". The view maps the feature tag to a localized title and
    /// shows the raw detail as monospaced secondary text.
    let featureTag: String
    let detail: String

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        kind: Kind,
        featureTag: String,
        detail: String
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.featureTag = featureTag
        self.detail = detail
    }
}

enum ActivityHistory {
    private static let maxEntries = 300
    private static let fileName = "activity-history.plist"
    // record() is a file-level read-modify-write called from multiple
    // concurrent userInitiated queues; without this lock two racers both
    // load the same list and the second persist silently drops an event.
    private static let recordLock = NSLock()

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

    static func load() -> [ActivityEvent] {
        recordLock.lock()
        defer { recordLock.unlock() }
        return loadLocked()
    }

    private static func loadLocked() -> [ActivityEvent] {
        guard
            let data = try? Data(contentsOf: fileURL),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
            ) as? [[String: Any]]
        else { return [] }
        return plist.compactMap { dict in
            guard
                let idString = dict["id"] as? String,
                let id = UUID(uuidString: idString),
                let date = dict["date"] as? Date,
                let kindRaw = dict["kind"] as? String,
                let kind = ActivityEvent.Kind(rawValue: kindRaw),
                let featureTag = dict["featureTag"] as? String
            else { return nil }
            return ActivityEvent(
                id: id,
                date: date,
                kind: kind,
                featureTag: featureTag,
                detail: dict["detail"] as? String ?? ""
            )
        }
        .sorted { $0.date > $1.date }
    }

    @discardableResult
    static func record(_ event: ActivityEvent) -> [ActivityEvent] {
        recordLock.lock()
        defer { recordLock.unlock() }
        var events = loadLocked()
        events.insert(event, at: 0)
        if events.count > maxEntries {
            events.removeLast(events.count - maxEntries)
        }
        persistLocked(events)
        return events
    }

    static func clear() {
        recordLock.lock()
        defer { recordLock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static func persistLocked(_ events: [ActivityEvent]) {
        let plist = events.map { event -> [String: Any] in
            [
                "id": event.id.uuidString,
                "date": event.date,
                "kind": event.kind.rawValue,
                "featureTag": event.featureTag,
                "detail": event.detail,
            ]
        }
        guard
            let data = try? PropertyListSerialization.data(
                fromPropertyList: plist, format: .binary, options: 0
            )
        else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Convenience emitters so feature code can log an activity with one call.
extension ActivityHistory {
    static func log(
        _ kind: ActivityEvent.Kind,
        feature: String,
        _ detail: String
    ) {
        record(ActivityEvent(kind: kind, featureTag: feature, detail: detail))
    }
}
