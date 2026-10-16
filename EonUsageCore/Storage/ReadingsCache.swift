import Foundation

/// On-disk cache for portal readings that can no longer change.
///
/// A quarter-hourly reading is settled data: once E.ON has finished publishing a day, that
/// day's values are fixed forever. Anything already downloaded for a finished day is
/// therefore kept and never fetched again — a month view costs one request for the newest
/// day or two instead of thirty-one days of traffic, and scrolling back through history is
/// free after the first visit.
///
/// Raw portal rows are cached rather than mapped samples, so correcting a channel's
/// direction in Settings re-renders the whole history straight from disk instead of
/// re-downloading it.
actor ReadingsCache {
    static let shared = ReadingsCache()

    /// One day's rows, as written to disk.
    struct Day: Codable, Sendable {
        /// The variable ids the rows were fetched with, in `Value1…ValueN` order.
        var ids: [String]
        var rows: [Row]

        /// Terse keys: a year of 15-minute readings is ~365 files of ~100 rows each.
        struct Row: Codable, Sendable {
            var t: Date
            var v: [Double?]
        }
    }

    /// How long a day may keep gaps before the app stops waiting for a backfill and caches
    /// it as it stands. Readings arrive roughly a day in arrears, so a week is generous;
    /// without this, a day the meter never fully reported would be refetched forever.
    private static let settledAfterDays = 7

    private let directory: URL
    private var isPrepared = false

    init(directory: URL = SharedContainer.directory.appending(path: "readings")) {
        self.directory = directory
    }

    // MARK: - Reading

    /// The cached rows for one day, or `nil` when the day was never cached or was fetched
    /// without one of the variables now being asked for.
    func rows(pod: String, interval: String, day: Date, ids: [String]) -> [MeasRowDTO]? {
        guard let data = try? Data(contentsOf: url(pod: pod, interval: interval, day: day)),
              let cached = try? JSONDecoder.portal.decode(Day.self, from: data),
              Set(ids).isSubset(of: Set(cached.ids))
        else {
            return nil
        }

        return cached.rows.map {
            MeasRowDTO(timestamp: $0.t, variableIds: cached.ids, values: $0.v)
        }
    }

    // MARK: - Writing

    /// Files away every day in `rows` that the portal has finished publishing. Days that
    /// are still filling in are simply skipped, so the next fetch picks them up again.
    func store(pod: String, interval: String, ids: [String], rows: [MeasRowDTO], now: Date = Date()) {
        let calendar = Calendar.sapWallClock
        let byDay = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.timestamp) }

        for (day, dayRows) in byDay where Self.isSettled(day: day, rows: dayRows, now: now) {
            // `MeasVarList` echoes the request, which is what lets the ids be stored once
            // per day instead of once per row. A row that disagrees would make that
            // shorthand a lie, so such a day is left uncached rather than mis-cached.
            guard dayRows.allSatisfy({ $0.variableIds.isEmpty || $0.variableIds == ids }) else { continue }

            let payload = Day(
                ids: ids,
                rows: dayRows
                    .sorted { $0.timestamp < $1.timestamp }
                    .map { Day.Row(t: $0.timestamp, v: $0.values) }
            )
            write(payload, to: url(pod: pod, interval: interval, day: day))
        }
    }

    /// A day is cacheable once it is over *and* the portal has clearly stopped adding to
    /// it: either its readings run to the end of the day, or it is old enough that the
    /// gaps in it are permanent. A day with no readings at all is never cached — the
    /// portal may simply not have published it yet.
    static func isSettled(day: Date, rows: [MeasRowDTO], now: Date = Date()) -> Bool {
        let calendar = Calendar.sapWallClock
        guard let newest = rows.map(\.timestamp).max() else { return false }
        guard day < calendar.startOfDay(for: now) else { return false }

        if let lastHour = calendar.date(byAdding: .hour, value: 23, to: day), newest >= lastHour {
            return true
        }
        return (calendar.dateComponents([.day], from: day, to: now).day ?? 0) >= settledAfterDays
    }

    /// Drops everything. Called on sign-out — the cache is keyed by delivery point, so
    /// switching PODs needs no eviction.
    func clear() {
        try? FileManager.default.removeItem(at: directory)
        isPrepared = false
    }

    // MARK: - Files

    private func url(pod: String, interval: String, day: Date) -> URL {
        directory.appending(path: "\(sanitised(pod))-\(sanitised(interval))-\(Self.stamp(day)).json")
    }

    private func write(_ day: Day, to url: URL) {
        guard let data = try? JSONEncoder.portal.encode(day) else { return }
        prepareDirectory()
        try? data.write(to: url, options: .atomic)
    }

    private func prepareDirectory() {
        guard !isPrepared else { return }
        isPrepared = true

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Re-downloadable derived data, so it has no business in a backup.
        var marker = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? marker.setResourceValues(values)
    }

    /// POD and interval ids are alphanumeric in practice; anything else would be a
    /// surprise, and a surprise has no place in a file name.
    private func sanitised(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }

    private static func stamp(_ day: Date) -> String {
        let components = Calendar.sapWallClock.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
