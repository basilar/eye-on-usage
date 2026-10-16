import Foundation
import SwiftUI

/// The window the dashboard is showing.
enum TimeSpan: String, CaseIterable, Identifiable, Sendable {
    case day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }

    /// The bucket size the chart draws. A day keeps the meter's native 15-minute slots;
    /// wider windows are rolled up so the bars stay readable.
    var chartResolution: SeriesResolution {
        switch self {
        case .day: return .quarterHour
        case .week: return .hour
        case .month: return .day
        }
    }

    var calendarComponent: Calendar.Component {
        switch self {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    /// Inclusive first and last day covered by an anchor date.
    func range(around anchor: Date) -> ClosedRange<Date> {
        let calendar = Calendar.sapWallClock
        let start = calendar.startOfDay(for: anchor)

        switch self {
        case .day:
            return start...start
        case .week:
            let interval = calendar.dateInterval(of: .weekOfYear, for: start)
            let first = interval?.start ?? start
            let last = calendar.date(byAdding: .day, value: 6, to: first) ?? start
            return first...last
        case .month:
            let interval = calendar.dateInterval(of: .month, for: start)
            let first = interval?.start ?? start
            let last = calendar.date(byAdding: .day, value: -1, to: interval?.end ?? start) ?? start
            return first...last
        }
    }

    /// The x-extent the chart draws, whether or not there are readings to fill it.
    ///
    /// Swift Charts would otherwise infer the axis from the marks, which both overshoots
    /// the window — a month bleeding a few days into the next one — and undershoots it,
    /// stretching a half-published month across the full width. Pinning the domain to the
    /// calendar window keeps a partial month sitting in its real place, with the days the
    /// portal has not published yet simply blank.
    func chartDomain(around anchor: Date) -> ClosedRange<Date> {
        let calendar = Calendar.sapWallClock
        let window = range(around: anchor)
        let end = calendar.date(byAdding: .day, value: 1, to: window.upperBound) ?? window.upperBound
        return window.lowerBound...end
    }

    func label(for anchor: Date) -> String {
        let range = range(around: anchor)
        switch self {
        case .day:
            return Format.longDay(range.lowerBound)
        case .week:
            return "\(Format.day(range.lowerBound)) – \(Format.day(range.upperBound))"
        case .month:
            return Format.month(range.lowerBound)
        }
    }
}

@MainActor
@Observable
final class DashboardModel {
    var span: TimeSpan = .day {
        didSet { guard span != oldValue else { return }; selection = nil }
    }

    /// Defaults to yesterday: the portal publishes settled readings a day in arrears, so
    /// "today" is normally empty and would look like a failure.
    var anchor: Date = Calendar.sapWallClock.date(
        byAdding: .day, value: -1, to: Calendar.sapWallClock.startOfDay(for: Date())
    ) ?? Date()

    var selection: Date?

    /// The date the picker edits. Normalised to the meter's own start of day, so a date
    /// chosen on the device's clock cannot land the anchor on the neighbouring day.
    var pickedDay: Date {
        get { anchor }
        set {
            let day = Calendar.sapWallClock.startOfDay(for: newValue)
            guard day != anchor else { return }
            anchor = day
            selection = nil
        }
    }

    /// Today on the meter's clock — the newest window the picker and stepper allow.
    static var today: Date { Calendar.sapWallClock.startOfDay(for: Date()) }

    private(set) var series: EnergySeries = .empty
    private(set) var sky: Sky = .empty
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var lastLoaded: Date?

    /// The window `series` was loaded for. Readings and the axis they are drawn against
    /// have to belong to the same window.
    private(set) var loadedRange: ClosedRange<Date>?

    /// Bumped by every load, so a slow one can tell it has been overtaken.
    private var generation = 0

    /// The series at the resolution the current span draws.
    var chartSeries: EnergySeries {
        series.aggregated(to: span.chartResolution)
    }

    /// The overlay is a day-view thing only. Hourly cloud averaged over a week or a month
    /// says almost nothing — the interesting question is which hours of *this* day were
    /// overcast, and that resolution is gone by the time it is a bar per day.
    var showsCloud: Bool { span == .day }

    var chartSky: Sky {
        showsCloud ? sky : .empty
    }

    var selectedSample: EnergySample? {
        guard let selection else { return nil }
        let bucket = Double(chartSeries.resolution.minutes) * 60
        return chartSeries.samples
            .min { abs($0.start.timeIntervalSince(selection)) < abs($1.start.timeIntervalSince(selection)) }
            .flatMap { abs($0.start.timeIntervalSince(selection)) <= bucket ? $0 : nil }
    }

    /// True once the window contains today, which is as far forward as the app goes.
    var isAtNewestWindow: Bool {
        span.range(around: anchor).contains(Self.today) || anchor >= Self.today
    }

    func step(_ direction: Int) {
        let calendar = Calendar.sapWallClock
        guard let moved = calendar.date(byAdding: span.calendarComponent, value: direction, to: anchor) else { return }
        anchor = min(moved, Self.today)
        selection = nil
    }

    /// Reads a drag on the chart as a page turn: -1 for the previous window, +1 for the
    /// next, `nil` to leave it to the chart.
    ///
    /// The chart's own drag scrubs the callout along the readings, so the two gestures
    /// share a surface and have to be told apart. Distance alone will not do it — reading
    /// values off a day means dragging the full width of the plot. Velocity will: a flick
    /// is thrown, so `predictedEndTranslation` runs well past where the finger actually
    /// lifted, while a careful scrub predicts almost exactly where it ended.
    static func pageStep(translation: CGSize, predictedEnd: CGSize) -> Int? {
        let thrown = abs(predictedEnd.width) - abs(translation.width)
        guard thrown > 40,
              abs(predictedEnd.width) > 120,
              abs(predictedEnd.width) > 2 * abs(predictedEnd.height)
        else { return nil }
        return predictedEnd.width < 0 ? 1 : -1
    }

    /// Jumps to the window containing today. For a week or a month that is the current
    /// one; for a day it is today itself, which the portal will usually not have
    /// published yet — the chart says so rather than quietly showing yesterday.
    func goToToday() {
        anchor = Self.today
        selection = nil
    }

    func load(using app: AppModel) async {
        generation &+= 1
        let token = generation
        isLoading = true
        errorMessage = nil

        let range = span.range(around: anchor)

        // Whatever is on screen belongs to the window that was on screen. Moving to a new
        // one drops it rather than drawing the old readings against the new axis, where
        // they land outside the domain and pile up against the edge of the plot. A
        // refresh of the same window keeps its readings visible while it reloads.
        if loadedRange != range {
            series = .empty
            sky = .empty
            loadedRange = nil
        }

        // The window is drawn whole, but there is nothing to ask for beyond today: a
        // current month would otherwise request the rest of its own future.
        let fetchEnd = min(range.upperBound, Self.today)

        do {
            let loaded = try await app.readings(from: range.lowerBound, to: fetchEnd)
            guard isCurrent(token) else { return }

            series = loaded
            loadedRange = range
            lastLoaded = Date()
            isLoading = false

            await loadSky(using: app, from: range.lowerBound, to: fetchEnd, token: token)

            // Feed the widgets whenever a single day is on screen — that is the figure
            // they show, and it costs nothing extra.
            if span == .day, !loaded.isEmpty {
                app.publishSnapshot(day: range.lowerBound, series: loaded)
            }

            if !app.isDemo {
                await FeedInMonitor.shared.check(using: loaded)
            }
        } catch {
            guard isCurrent(token) else { return }

            series = .empty
            loadedRange = nil
            errorMessage = (error as? PortalError)?.errorDescription ?? error.localizedDescription
            isLoading = false
        }
    }

    /// The weather is decoration. It is fetched after the readings, never in front of
    /// them, and a failure leaves the chart alone rather than replacing it with an error —
    /// a portal outage and a weather-service hiccup are not the same news.
    private func loadSky(using app: AppModel, from: Date, to: Date, token: Int) async {
        let wanted = app.preferences.value
        guard showsCloud,
              wanted.showsCloudCover || wanted.showsDaylight,
              let location = wanted.weatherLocation
        else {
            sky = .empty
            return
        }

        // Clamped to today like the readings are: the weather service would happily serve
        // the rest of the month as forecast, and a grey line running on past the last bar
        // reads as measured history when it is not.
        let fetched = try? await app.sky(at: location, from: from, to: to)
        guard isCurrent(token) else { return }

        // One request brings both halves; each is shown only if its own switch is on.
        let preferences = app.preferences.value
        sky = Sky(
            cloud: preferences.showsCloudCover ? measured(fetched?.cloud ?? .empty) : .empty,
            daylight: preferences.showsDaylight ? (fetched?.daylight ?? .empty) : .empty
        )
    }

    /// Drops cloud samples for hours that have not happened.
    ///
    /// Asked for today, the weather service answers with all twenty-four hours — the rest
    /// of them forecast. Drawn in the same grey as the measured ones it reads as fact, and
    /// the curve sails on past the last bar to midnight. Clamping the *date* range does not
    /// help here: the window already is today.
    ///
    /// Daylight is deliberately left whole. Sunset is arithmetic, not a forecast, so
    /// shading this evening before it arrives states nothing that might turn out false.
    private func measured(_ cover: CloudCover) -> CloudCover {
        let cutoff = Self.wallClockNow
        guard cover.samples.contains(where: { $0.start > cutoff }) else { return cover }
        return CloudCover(samples: cover.samples.filter { $0.start <= cutoff })
    }

    /// Now, on the same clock the samples are stamped in.
    ///
    /// Both W1000 and Open-Meteo (`timezone=auto`) hand back *local* wall-clock times with
    /// no offset, which the app reads as UTC components — so a Hungarian 14:00 is the
    /// instant 14:00 UTC, two hours ahead of the real one in summer. Comparing those to a
    /// bare `Date()` would discard the last two hours of measured cloud every afternoon.
    /// Shifting by the device's own offset puts "now" into the same frame, which is exact
    /// for a phone in Hungary — and this app only works with a Hungarian meter.
    private static var wallClockNow: Date {
        Date().addingTimeInterval(Double(TimeZone.current.secondsFromGMT()))
    }

    /// Re-runs just the weather, for when the overlay is switched on or off. The readings
    /// are untouched — they have not changed.
    func refreshSky(using app: AppModel) async {
        let range = span.range(around: anchor)
        await loadSky(
            using: app,
            from: range.lowerBound,
            to: min(range.upperBound, Self.today),
            token: generation
        )
    }

    /// False once this load has been superseded or cancelled — stepping quickly through
    /// months leaves a trail of in-flight fetches, and a late or abandoned one must not
    /// overwrite the window the user is actually looking at, least of all with the
    /// failure that cancelling it produced.
    private func isCurrent(_ token: Int) -> Bool {
        token == generation && !Task.isCancelled
    }
}
