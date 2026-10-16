import Foundation

/// Where the app and its widgets meet.
///
/// Both resolve the App Group; if the group is unavailable — an unsigned local build, a
/// misconfigured entitlement — everything falls back to the app's own container so the
/// app keeps working and only the widget goes stale.
enum SharedContainer {
    static let appGroupID = "group.hu.randart.EonUsage"

    /// `UserDefaults` is thread-safe but not `Sendable`; the app and the widget both
    /// read this and neither mutates the instance itself.
    nonisolated(unsafe) static let defaults: UserDefaults = UserDefaults(suiteName: appGroupID) ?? .standard

    static let directory: URL = {
        let manager = FileManager.default
        if let group = manager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return group
        }
        return (try? manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL.temporaryDirectory
    }()

    static var isSharing: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
    }
}

/// Persists the widget snapshot as a single JSON file in the shared container.
struct SnapshotStore: Sendable {
    static let shared = SnapshotStore()

    private var url: URL { SharedContainer.directory.appending(path: "usage-snapshot.json") }

    func load() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.portal.decode(UsageSnapshot.self, from: data)
    }

    func save(_ snapshot: UsageSnapshot) {
        guard let data = try? JSONEncoder.portal.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

extension JSONDecoder {
    static var portal: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var portal: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
