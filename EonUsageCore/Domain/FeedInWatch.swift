import Foundation

/// Decides whether the inverter has stopped feeding the grid.
///
/// The one subtlety worth stating: the gap is measured from the last export **to the
/// newest reading the portal has published**, never to the current time. Readings arrive
/// about a day in arrears, so measuring against "now" would count E.ON's publishing lag
/// as an inverter fault and raise an alarm every day.
enum FeedInWatch {
    /// Below this a "reading" is meter noise rather than real export.
    static let noiseFloor = 0.001

    struct Verdict: Sendable, Equatable {
        /// Start of the last bucket that actually exported something.
        var lastFeedIn: Date?
        /// Start of the newest bucket the portal has any reading for.
        var newestReading: Date?
        /// How long the export has been absent, in the meter's own timeline.
        var gap: TimeInterval?
        /// True when nothing exported anywhere in the window, so `gap` is only a lower
        /// bound — the real silence may have begun before the window opened.
        var isLowerBound: Bool
        var isBreached: Bool
        /// False when the portal returned nothing at all, which proves nothing either way.
        var hasReadings: Bool

        static let noData = Verdict(
            lastFeedIn: nil, newestReading: nil, gap: nil,
            isLowerBound: false, isBreached: false, hasReadings: false
        )
    }

    static func evaluate(_ series: EnergySeries, threshold: TimeInterval) -> Verdict {
        let readings = series.samples.filter(\.hasReading)
        guard let oldest = readings.first?.start, let newest = readings.last?.start else {
            return .noData
        }

        let lastFeedIn = readings.last { ($0.feedIn ?? 0) > noiseFloor }?.start

        // The newest bucket covers time up to its own end, so count to there.
        let observedEnd = newest.addingTimeInterval(Double(series.resolution.minutes) * 60)
        let since = lastFeedIn ?? oldest
        let gap = observedEnd.timeIntervalSince(since)

        return Verdict(
            lastFeedIn: lastFeedIn,
            newestReading: newest,
            gap: gap,
            isLowerBound: lastFeedIn == nil,
            isBreached: gap >= threshold,
            hasReadings: true
        )
    }
}
