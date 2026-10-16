import Foundation

/// A delivery point — the physical connection where consumption is measured.
struct DeliveryPoint: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let sparte: String
    let subtitle: String?

    var isElectricity: Bool { sparte == Sparte.electricity }

    /// PODs are 33 characters of unbroken identifier; grouping them makes them readable.
    var formattedID: String {
        guard id.count > 12 else { return id }
        return stride(from: 0, to: id.count, by: 6).map { offset in
            let start = id.index(id.startIndex, offsetBy: offset)
            let end = id.index(start, offsetBy: min(6, id.count - offset))
            return String(id[start..<end])
        }
        .joined(separator: " ")
    }
}

enum Sparte {
    static let electricity = "01"
    static let gas = "02"

    static func title(_ code: String) -> String {
        switch code {
        case electricity: return "Electricity"
        case gas: return "Gas"
        default: return "Division \(code)"
        }
    }
}

/// What a measured variable means for the household's energy balance.
enum ChannelDirection: String, Codable, Sendable, CaseIterable {
    /// Energy drawn from the grid.
    case consumption
    /// Energy fed back into the grid by the inverter.
    case feedIn
    /// Anything the app could not place — reactive power, registers, gas volume.
    case other

    var title: String {
        switch self {
        case .consumption: return "From grid"
        case .feedIn: return "To grid"
        case .other: return "Other"
        }
    }
}

/// One measured variable ("curve") offered for a POD at a given resolution.
struct MeasurementChannel: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let name: String
    let intervalID: String
    let sparte: String
    /// `true` for channels whose values may be summed over time (energy per interval);
    /// `false` for cumulative meter registers, which must not be added up.
    let isSummable: Bool
    var direction: ChannelDirection
}

/// A single reading slot.
struct EnergySample: Identifiable, Hashable, Sendable {
    let start: Date
    var consumption: Double?
    var feedIn: Double?

    var id: Date { start }

    var net: Double { (consumption ?? 0) - (feedIn ?? 0) }
    var hasReading: Bool { consumption != nil || feedIn != nil }
}

/// The resolution a series is expressed in.
enum SeriesResolution: Int, Sendable, Codable {
    case quarterHour = 15
    case hour = 60
    case day = 1440

    var minutes: Int { rawValue }

    var title: String {
        switch self {
        case .quarterHour: return "15 min"
        case .hour: return "Hourly"
        case .day: return "Daily"
        }
    }
}

/// Which way a window's energy balance came out.
enum EnergyBalance: Sendable, Hashable {
    /// More drawn from the grid than fed back.
    case taken
    /// The two cancelled out.
    case balanced
    /// More fed back than drawn.
    case sentBack

    /// Names what the accompanying percentage measures, so the figure reads on its own.
    var shareTitle: String {
        switch self {
        case .taken: return "Net taken"
        case .balanced: return "Level"
        case .sentBack: return "Surplus sent back"
        }
    }

    /// Names the accompanying absolute figure.
    var totalTitle: String {
        switch self {
        case .taken: return "Net imported"
        case .balanced: return "Balanced"
        case .sentBack: return "Net exported"
        }
    }
}

/// An ordered run of samples plus the arithmetic every screen needs from it.
struct EnergySeries: Sendable {
    var resolution: SeriesResolution
    var samples: [EnergySample]
    var unit: String

    init(resolution: SeriesResolution, samples: [EnergySample], unit: String = "kWh") {
        self.resolution = resolution
        self.samples = samples.sorted { $0.start < $1.start }
        self.unit = unit
    }

    static let empty = EnergySeries(resolution: .quarterHour, samples: [])

    var isEmpty: Bool { samples.allSatisfy { !$0.hasReading } }

    var totalConsumption: Double { samples.compactMap(\.consumption).reduce(0, +) }
    var totalFeedIn: Double { samples.compactMap(\.feedIn).reduce(0, +) }
    /// Positive when the household drew more than it exported over the window.
    var netImport: Double { totalConsumption - totalFeedIn }

    var peakConsumption: EnergySample? {
        samples.filter { $0.consumption != nil }.max { ($0.consumption ?? 0) < ($1.consumption ?? 0) }
    }

    var peakFeedIn: EnergySample? {
        samples.filter { $0.feedIn != nil }.max { ($0.feedIn ?? 0) < ($1.feedIn ?? 0) }
    }

    /// Largest single-sample magnitude in either direction — the chart's y-extent.
    var magnitude: Double {
        let values: [Double] = samples.flatMap { [$0.consumption ?? 0, $0.feedIn ?? 0] }
        return values.max() ?? 0
    }

    /// The net position as a share of what was drawn from the grid.
    ///
    /// Anchored at break-even rather than at zero flow. Nothing fed back reads 100%: the
    /// whole draw was net. Feed-in matching consumption reads 0% — the meter came out
    /// level. Past that the figure climbs again as surplus: 701 kWh exported against 544
    /// kWh drawn is 29% more sent back than taken. `balance` says which side it fell on,
    /// so the same magnitude is never ambiguous.
    ///
    /// `nil` when nothing was drawn at all, which leaves the share undefined.
    var netShare: Double? {
        guard totalConsumption > 0 else { return nil }
        return abs(totalConsumption - totalFeedIn) / totalConsumption
    }

    /// Which side the window's balance fell on.
    ///
    /// Tied to `netShare` *as displayed*: anything rounding to 0% counts as level, so the
    /// neutral reading is exactly the case that shows zero rather than a near-miss that
    /// claims a direction it cannot see.
    var balance: EnergyBalance {
        guard let share = netShare, share >= 0.005 else { return .balanced }
        return totalFeedIn > totalConsumption ? .sentBack : .taken
    }

    /// Rolls the samples up into coarser buckets, keeping "no reading" distinct from zero.
    func aggregated(to target: SeriesResolution) -> EnergySeries {
        guard target.minutes > resolution.minutes else { return self }

        let calendar = Calendar.sapWallClock
        var buckets: [Date: EnergySample] = [:]

        for sample in samples where sample.hasReading {
            let key = Self.bucketStart(for: sample.start, resolution: target, calendar: calendar)
            var bucket = buckets[key] ?? EnergySample(start: key, consumption: nil, feedIn: nil)
            if let consumption = sample.consumption {
                bucket.consumption = (bucket.consumption ?? 0) + consumption
            }
            if let feedIn = sample.feedIn {
                bucket.feedIn = (bucket.feedIn ?? 0) + feedIn
            }
            buckets[key] = bucket
        }

        return EnergySeries(resolution: target, samples: Array(buckets.values), unit: unit)
    }

    private static func bucketStart(
        for date: Date,
        resolution: SeriesResolution,
        calendar: Calendar
    ) -> Date {
        switch resolution {
        case .quarterHour:
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            components.minute = ((components.minute ?? 0) / 15) * 15
            return calendar.date(from: components) ?? date
        case .hour:
            return calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: date)) ?? date
        case .day:
            return calendar.startOfDay(for: date)
        }
    }
}
