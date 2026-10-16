import Foundation

/// On-disk cache for cloud cover, on the same principle as `ReadingsCache`: the weather
/// over a day that has already happened is not going to change.
///
/// Kept per whole range rather than per day, because the weather service bills a request
/// the same whatever span it covers — there is nothing to gain by splitting a month into
/// thirty lookups the way a metering horizon forces.
actor WeatherCache {
    static let shared = WeatherCache()

    private let directory: URL
    private var isPrepared = false

    init(directory: URL = SharedContainer.directory.appending(path: "weather")) {
        self.directory = directory
    }

    /// A cached range, or `nil` when it was never fetched or is not settled yet.
    func sky(at location: WeatherLocation, from: Date, to: Date) -> Sky? {
        guard isSettled(to: to) else { return nil }
        guard let data = try? Data(contentsOf: url(location, from, to)),
              let stored = try? JSONDecoder.portal.decode(Stored.self, from: data)
        else { return nil }

        return Sky(
            cloud: CloudCover(samples: stored.cloud.map { CloudCover.Sample(start: $0.t, percent: $0.v) }),
            daylight: Daylight(days: stored.days.map { Daylight.Day(sunrise: $0.rise, sunset: $0.set) })
        )
    }

    func store(_ sky: Sky, at location: WeatherLocation, from: Date, to: Date) {
        // A range running up to today is still being written by the forecast model.
        guard isSettled(to: to), !sky.isEmpty else { return }

        let stored = Stored(
            cloud: sky.cloud.samples.map { Entry(t: $0.start, v: $0.percent) },
            days: sky.daylight.days.map { Span(rise: $0.sunrise, set: $0.sunset) }
        )
        guard let data = try? JSONEncoder.portal.encode(stored) else { return }

        prepare()
        try? data.write(to: url(location, from, to), options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: directory)
        isPrepared = false
    }

    // MARK: - Files

    private struct Stored: Codable, Sendable {
        var cloud: [Entry]
        var days: [Span]
    }

    private struct Entry: Codable, Sendable {
        var t: Date
        var v: Double
    }

    private struct Span: Codable, Sendable {
        var rise: Date
        var set: Date
    }

    /// Only ranges wholly in the past are worth keeping — today's is still being revised.
    private func isSettled(to: Date) -> Bool {
        to < Calendar.sapWallClock.startOfDay(for: Date())
    }

    private func url(_ location: WeatherLocation, _ from: Date, _ to: Date) -> URL {
        // Coordinates are rounded to about a kilometre: the cloud model has nothing finer,
        // and it keeps a nudged location from missing its own cache.
        let key = String(
            format: "%.2f_%.2f_%@_%@",
            location.latitude, location.longitude, stamp(from), stamp(to)
        ).replacingOccurrences(of: "-", with: "m")
        return directory.appending(path: "\(key).json")
    }

    private func stamp(_ date: Date) -> String {
        let parts = Calendar.sapWallClock.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func prepare() {
        guard !isPrepared else { return }
        isPrepared = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var marker = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? marker.setResourceValues(values)
    }
}
