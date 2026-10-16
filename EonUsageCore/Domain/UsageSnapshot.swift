import Foundation

/// The small, self-contained summary the app hands to its widgets through the App Group.
///
/// Widgets never talk to the portal themselves: the portal only publishes settled
/// readings (typically a day behind), so there is nothing a background refresh could add
/// that the app has not already written here after its own fetch.
struct UsageSnapshot: Codable, Sendable, Hashable {
    struct Bar: Codable, Sendable, Hashable {
        let start: Date
        let consumption: Double
        let feedIn: Double
    }

    /// The delivery point these figures belong to.
    var podID: String
    /// The day the figures cover, in the meter's own wall clock.
    var day: Date
    var consumption: Double
    var feedIn: Double
    /// Hourly buckets for the widget's sparkline — 24 at most.
    var bars: [Bar]
    var capturedAt: Date

    init(podID: String, day: Date, consumption: Double, feedIn: Double, bars: [Bar], capturedAt: Date) {
        self.podID = podID
        self.day = day
        self.consumption = consumption
        self.feedIn = feedIn
        self.bars = bars
        self.capturedAt = capturedAt
    }

    var net: Double { consumption - feedIn }

    /// The net position as a share of what was drawn, as in `EnergySeries.netShare`.
    var netShare: Double? {
        guard consumption > 0 else { return nil }
        return abs(consumption - feedIn) / consumption
    }

    var balance: EnergyBalance {
        guard let share = netShare, share >= 0.005 else { return .balanced }
        return feedIn > consumption ? .sentBack : .taken
    }

    /// Builds a snapshot from one day's readings.
    init(podID: String, day: Date, series: EnergySeries, capturedAt: Date = Date()) {
        let hourly = series.aggregated(to: .hour)
        self.init(
            podID: podID,
            day: Calendar.sapWallClock.startOfDay(for: day),
            consumption: series.totalConsumption,
            feedIn: series.totalFeedIn,
            bars: hourly.samples.map {
                Bar(start: $0.start, consumption: $0.consumption ?? 0, feedIn: $0.feedIn ?? 0)
            },
            capturedAt: capturedAt
        )
    }

    static let placeholder = UsageSnapshot(
        podID: "HU000210F11000000000000000000",
        day: Calendar.sapWallClock.startOfDay(for: Date(timeIntervalSince1970: 1_788_300_000)),
        consumption: 14.2,
        feedIn: 21.6,
        bars: (0..<24).map { hour in
            let solar = max(0, sin(Double(hour - 6) / 12 * .pi))
            return Bar(
                start: Date(timeIntervalSince1970: 1_788_300_000 + Double(hour) * 3600),
                consumption: 0.35 + 0.4 * abs(sin(Double(hour) / 4)),
                feedIn: solar * 2.6
            )
        },
        capturedAt: Date(timeIntervalSince1970: 1_788_386_400)
    )
}
