import Foundation

/// Decides whether the inverter is still producing what this site normally produces.
///
/// `FeedInWatch` asks "has export stopped?", which a half-dead inverter defeats: it keeps
/// trickling a few watts, every bucket clears the noise floor, the silence never begins
/// and no alarm ever fires. This asks the other question — "is the export still the size
/// it used to be?" — and answers it by measuring the site against its own recent history,
/// which is the only baseline available without a weather feed.
///
/// Two choices carry the whole design:
///
/// * The statistic is the **peak bucket**, not the day's total. Cloud cover halves a
///   daily total routinely; it does not stop a working array from spiking during a break
///   in the weather. A collapsed peak is much closer to evidence of a fault.
/// * The recent window is scored by its **best** day and the baseline by its **median**.
///   One clear hour on any recent day clears the alarm, and a run of cloud in the
///   baseline cannot drag the reference down. Both choices bias hard against crying wolf,
///   which is the only way a warning like this stays worth reading.
enum OutputWatch {
    /// One day reduced to the two numbers that matter.
    struct DayStat: Sendable, Equatable, Hashable {
        var day: Date
        /// The largest single bucket, standing in for peak power.
        var peak: Double
        var total: Double
    }

    struct Verdict: Sendable, Equatable {
        /// Median peak across the baseline window — what a normal day looks like here.
        var baseline: Double?
        /// Best peak across the recent window.
        var observed: Double?
        /// `observed / baseline`.
        var ratio: Double?
        var recent: [DayStat]
        var baselineCount: Int
        /// Days of readings the check actually had to work with.
        var dayCount: Int
        var isBreached: Bool
        /// False when there is too little history, or too little output, to judge — which
        /// is not the same as healthy, and must never raise an alarm.
        var isConclusive: Bool
        /// Why it could not judge. Nil once conclusive.
        var reason: Reason?

        /// An inconclusive check has to be able to say what it was missing. Showing
        /// nothing at all — the first version of this — leaves no way to tell a healthy
        /// site from a check that never ran.
        enum Reason: Sendable, Equatable {
            case off
            case notEnoughHistory(days: Int, needed: Int)
            case outputTooSmall(peak: Double)

            var explanation: String {
                switch self {
                case .off:
                    return "The drop check is off."
                case .notEnoughHistory(let days, let needed):
                    return "The drop check needs \(needed) days of readings to have a baseline, and this delivery point returned \(days)."
                case .outputTooSmall(let peak):
                    return "Normal output here peaks at \(Format.energy(peak)) per quarter hour, too small to judge a drop against."
                }
            }
        }

        static func inconclusive(_ reason: Reason, days: Int = 0) -> Verdict {
            Verdict(
                baseline: nil, observed: nil, ratio: nil, recent: [],
                baselineCount: 0, dayCount: days, isBreached: false,
                isConclusive: false, reason: reason
            )
        }
    }

    /// A site whose normal peak sits below this is too small — or too deep into winter —
    /// for a ratio against it to mean anything. 0.05 kWh in a quarter hour is 200 W.
    static let floor = 0.05

    /// Days of history used as the reference, taken immediately before the recent window.
    static let baselineDays = 21
    /// Fewest baseline days that will support a judgement at all.
    static let minimumBaselineDays = 7

    /// Reduces a series to one entry per day that has readings.
    static func dailyStats(_ series: EnergySeries) -> [DayStat] {
        let calendar = Calendar.sapWallClock
        var byDay: [Date: DayStat] = [:]

        for sample in series.samples where sample.hasReading {
            let day = calendar.startOfDay(for: sample.start)
            var stat = byDay[day] ?? DayStat(day: day, peak: 0, total: 0)
            let value = sample.feedIn ?? 0
            stat.peak = max(stat.peak, value)
            stat.total += value
            byDay[day] = stat
        }

        return byDay.values.sorted { $0.day < $1.day }
    }

    /// - Parameters:
    ///   - recentDays: how many days at the end of the series are judged together.
    ///   - threshold: the fraction of normal below which output counts as collapsed.
    /// Fewest days of readings that can support a judgement at all.
    static func daysNeeded(recentDays: Int) -> Int { recentDays + minimumBaselineDays }

    static func evaluate(_ series: EnergySeries, recentDays: Int, threshold: Double) -> Verdict {
        guard threshold > 0, recentDays > 0 else { return .inconclusive(.off) }

        let stats = dailyStats(series)
        let needed = daysNeeded(recentDays: recentDays)
        guard stats.count >= needed else {
            return .inconclusive(.notEnoughHistory(days: stats.count, needed: needed), days: stats.count)
        }

        let recent = Array(stats.suffix(recentDays))
        let baseline = Array(stats.dropLast(recent.count).suffix(baselineDays))

        let usual = median(baseline.map(\.peak))
        let best = recent.map(\.peak).max() ?? 0

        guard usual >= floor else {
            var verdict = Verdict.inconclusive(.outputTooSmall(peak: usual), days: stats.count)
            verdict.baseline = usual
            verdict.observed = best
            verdict.recent = recent
            verdict.baselineCount = baseline.count
            return verdict
        }

        let ratio = best / usual
        return Verdict(
            baseline: usual, observed: best, ratio: ratio, recent: recent,
            baselineCount: baseline.count, dayCount: stats.count,
            isBreached: ratio < threshold, isConclusive: true, reason: nil
        )
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
