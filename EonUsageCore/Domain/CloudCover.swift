import Foundation

/// Where the readings were measured, for the weather that fell on them.
///
/// A delivery point does not move, so this is a coordinate the user sets once rather than
/// anything tracked. `name` is only ever for showing back to them.
struct WeatherLocation: Codable, Sendable, Equatable, Hashable {
    var latitude: Double
    var longitude: Double
    var name: String?

    var summary: String {
        if let name, !name.isEmpty { return name }
        return String(format: "%.3f, %.3f", latitude, longitude)
    }
}

/// Sky cover over the delivery point, hour by hour.
struct CloudCover: Sendable, Equatable {
    struct Sample: Sendable, Equatable, Identifiable {
        let start: Date
        /// 0 is a clear sky, 100 overcast.
        let percent: Double
        var id: Date { start }
    }

    var samples: [Sample]

    init(samples: [Sample]) {
        self.samples = samples.sorted { $0.start < $1.start }
    }

    static let empty = CloudCover(samples: [])
    var isEmpty: Bool { samples.isEmpty }
}

/// When the sun was up, for shading the hours it was not.
struct Daylight: Sendable, Equatable {
    struct Day: Sendable, Equatable, Hashable {
        let sunrise: Date
        let sunset: Date
    }

    var days: [Day]

    static let empty = Daylight(days: [])
    var isEmpty: Bool { days.isEmpty }

    /// The stretches of a window the sun was *not* up, clipped to it.
    ///
    /// Derived by inverting the daylight rather than shading it directly: a window can open
    /// mid-morning or close before dusk, and the night either side of a day is two spans,
    /// not one.
    func nights(in window: ClosedRange<Date>) -> [DateInterval] {
        guard !isEmpty else { return [] }

        var spans: [DateInterval] = []
        var cursor = window.lowerBound

        for day in days.sorted(by: { $0.sunrise < $1.sunrise }) {
            let rise = max(day.sunrise, window.lowerBound)
            let set = min(day.sunset, window.upperBound)
            guard set > rise else { continue }
            if rise > cursor { spans.append(DateInterval(start: cursor, end: rise)) }
            cursor = max(cursor, set)
        }

        if cursor < window.upperBound {
            spans.append(DateInterval(start: cursor, end: window.upperBound))
        }
        return spans
    }
}

/// What the sky was doing over the delivery point. Both halves come from one request.
struct Sky: Sendable, Equatable {
    var cloud: CloudCover
    var daylight: Daylight

    static let empty = Sky(cloud: .empty, daylight: .empty)
    var isEmpty: Bool { cloud.isEmpty && daylight.isEmpty }
}
