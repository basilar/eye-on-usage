import Foundation
import WidgetKit

/// Runs the feed-in check and raises (or clears) the alert.
///
/// Called from three places: after the dashboard loads, from the background refresh task,
/// and from the Settings "check now" button. All three funnel through here so the
/// de-duplication rules live in one place.
@MainActor
final class FeedInMonitor {
    static let shared = FeedInMonitor()

    enum Outcome: Sendable, Equatable {
        case disabled
        case notConfigured
        case noReadings
        case quiet(FeedInWatch.Verdict)
        case warned(FeedInWatch.Verdict)
        case resumed(FeedInWatch.Verdict)
        /// Still exporting, but far below what this site normally manages.
        case degraded(OutputWatch.Verdict)
        case failed(String)
    }

    /// The app will not nag more often than this while the fault persists.
    private static let repeatInterval: TimeInterval = 24 * 3600
    /// How often an unforced check will actually go to the network.
    private static let throttle: TimeInterval = 3 * 3600
    /// Extra days fetched beyond the threshold, to cover the portal's publishing lag and
    /// to find the last export that came before the silence.
    private static let marginDays = 3

    private let repository: UsageRepository
    private let alerts: AlertCenter
    private let store: PreferencesStore
    private var isRunning = false

    init(
        repository: UsageRepository = UsageRepository(),
        alerts: AlertCenter = .shared,
        store: PreferencesStore = .shared
    ) {
        self.repository = repository
        self.alerts = alerts
        self.store = store
    }

    /// - Parameters:
    ///   - series: readings the caller already has. Used only when they span at least the
    ///     alert threshold, otherwise a wider window is fetched.
    ///   - force: ignore the throttle. The dashboard checks on every load, so without a
    ///     throttle a day view — which spans just under 24 hours — would trigger a fresh
    ///     multi-day fetch every single time.
    @discardableResult
    func check(using series: EnergySeries? = nil, force: Bool = false) async -> Outcome {
        guard !isRunning else { return .disabled }
        isRunning = true
        defer { isRunning = false }

        let preferences = store.value
        guard preferences.feedInAlertEnabled else { return .disabled }
        guard let podID = preferences.podID, let partnerID = preferences.partnerID else {
            return .notConfigured
        }
        if !force, let checked = preferences.lastFeedInCheckedAt,
           Date().timeIntervalSince(checked) < Self.throttle {
            return .disabled
        }

        let threshold = preferences.feedInAlertThreshold
        let readings: EnergySeries
        // The drop check needs weeks of history to have a baseline at all, so a day's
        // worth handed over by the dashboard is never enough for it.
        if let series, !preferences.watchesOutputDrop, spans(series, atLeast: threshold) {
            readings = series
        } else {
            do {
                readings = try await fetch(podID: podID, partnerID: partnerID, preferences: preferences)
            } catch {
                return .failed((error as? PortalError)?.errorDescription ?? error.localizedDescription)
            }
        }

        let gap = FeedInWatch.evaluate(readings, threshold: threshold)
        let output = preferences.watchesOutputDrop
            ? OutputWatch.evaluate(
                readings,
                recentDays: preferences.outputDropDays,
                threshold: preferences.outputDropRatio
              )
            : .inconclusive(.off)

        record(gap: gap, output: output)
        publishSnapshot(podID: podID, from: readings)

        guard gap.hasReadings else { return .noReadings }

        // Total silence is the louder fault and takes precedence; a collapse is only
        // interesting while something is still coming through.
        if gap.isBreached { return await raise(gap) }
        let settled = await standDown(gap)

        if output.isBreached { return await raiseDrop(output) }
        await clearDrop(output)
        return settled
    }

    // MARK: - Alerting

    private func raise(_ verdict: FeedInWatch.Verdict) async -> Outcome {
        let now = Date()
        if let last = store.value.lastFeedInAlertAt, now.timeIntervalSince(last) < Self.repeatInterval {
            return .warned(verdict)
        }

        await alerts.post(
            .feedInStopped,
            title: Self.warningTitle(verdict),
            body: Self.warningBody(verdict)
        )
        store.value.lastFeedInAlertAt = now
        return .warned(verdict)
    }

    private func standDown(_ verdict: FeedInWatch.Verdict) async -> Outcome {
        // Only worth saying "it's back" to someone who was told it had stopped.
        guard store.value.lastFeedInAlertAt != nil else { return .quiet(verdict) }

        alerts.clear(.feedInStopped)
        if let resumed = verdict.lastFeedIn {
            await alerts.post(
                .feedInResumed,
                title: "Feed-in resumed",
                body: "Your inverter exported to the grid again on \(Self.stamp(resumed))."
            )
        }
        store.value.lastFeedInAlertAt = nil
        return .resumed(verdict)
    }

    private func raiseDrop(_ verdict: OutputWatch.Verdict) async -> Outcome {
        let now = Date()
        if let last = store.value.lastOutputDropAlertAt, now.timeIntervalSince(last) < Self.repeatInterval {
            return .degraded(verdict)
        }

        await alerts.post(.outputDropped, title: Self.dropTitle(verdict), body: Self.dropBody(verdict))
        store.value.lastOutputDropAlertAt = now
        return .degraded(verdict)
    }

    /// Stands the drop alert down, but only once output is clearly back — releasing at
    /// the same ratio that raised it would flap on and off across the threshold.
    private func clearDrop(_ verdict: OutputWatch.Verdict) async {
        guard store.value.lastOutputDropAlertAt != nil,
              verdict.isConclusive,
              let ratio = verdict.ratio,
              ratio >= min(1, store.value.outputDropRatio * 1.5)
        else { return }

        alerts.clear(.outputDropped)
        await alerts.post(
            .outputRecovered,
            title: "Feed-in back to normal",
            body: "Export is back to \(Format.percent(ratio)) of what this delivery point usually produces."
        )
        store.value.lastOutputDropAlertAt = nil
    }

    // MARK: - Copy

    nonisolated static func warningTitle(_ verdict: FeedInWatch.Verdict) -> String {
        guard let gap = verdict.gap else { return "No feed-in to the grid" }
        let hours = Int((gap / 3600).rounded())
        if hours >= 48 {
            return "No feed-in for \(hours / 24) days"
        }
        return "No feed-in for \(hours) hours"
    }

    nonisolated static func warningBody(_ verdict: FeedInWatch.Verdict) -> String {
        let upTo = verdict.newestReading.map { "Readings up to \(stamp($0)) show none since." } ?? ""

        if let last = verdict.lastFeedIn {
            return "Your inverter last sent power to the grid on \(stamp(last)). \(upTo)"
                .trimmingCharacters(in: .whitespaces)
        }
        return "No export appears anywhere in the readings the portal has published. \(upTo)"
            .trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func dropTitle(_ verdict: OutputWatch.Verdict) -> String {
        guard let ratio = verdict.ratio else { return "Feed-in has dropped" }
        return "Feed-in down to \(Format.percent(ratio)) of normal"
    }

    nonisolated static func dropBody(_ verdict: OutputWatch.Verdict) -> String {
        guard let baseline = verdict.baseline, let observed = verdict.observed else {
            return "Export has fallen well below what this delivery point usually produces."
        }
        return "The best quarter hour across the last \(verdict.recent.count) days reached \(Format.energy(observed)), against \(Format.energy(baseline)) on a normal day. Worth looking at the inverter."
    }

    /// One line describing an outcome, for Settings and for the Shortcuts action.
    nonisolated static func summary(_ outcome: Outcome) -> String {
        switch outcome {
        case .disabled:
            return "The alert is off."
        case .notConfigured:
            return "Choose a delivery point first."
        case .noReadings:
            return "The portal returned no readings, so nothing could be judged."
        case .quiet:
            return "Feed-in looks normal."
        case .warned(let verdict):
            return warningTitle(verdict) + " \u{2014} you have been notified."
        case .resumed:
            return "Feed-in has resumed."
        case .degraded(let verdict):
            return dropTitle(verdict) + " \u{2014} you have been notified."
        case .failed(let message):
            return message
        }
    }

    private nonisolated static func stamp(_ date: Date) -> String {
        "\(Format.longDay(date)) at \(Format.time(date))"
    }

    // MARK: - Plumbing

    private func fetch(
        podID: String,
        partnerID: String,
        preferences: Preferences
    ) async throws -> EnergySeries {
        try await repository.restoreSession(partnerID: partnerID)
        let catalogue = try await repository.catalogue(
            sparte: preferences.sparte,
            overrides: preferences.channelOverrides
        )

        let calendar = Calendar.sapWallClock
        var wanted = Int(ceil(preferences.feedInAlertThreshold / 86400)) + Self.marginDays
        if preferences.watchesOutputDrop {
            // Enough history for a baseline as well as the recent window.
            wanted = max(wanted, preferences.outputDropDays + OutputWatch.baselineDays + Self.marginDays)
        }
        // Weeks of history would be dear to fetch on every check; `ReadingsCache` means
        // only the newest day or two actually reaches the portal.
        let days = min(31, wanted)
        let end = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -days, to: end) ?? end

        return try await repository.readings(
            podID: podID,
            channels: catalogue.channels,
            interval: catalogue.interval,
            from: start,
            to: end
        )
    }

    /// Keeps the widgets current even when nobody opens the app.
    ///
    /// The app writes a snapshot whenever a single day is on screen, which is no help to
    /// someone who has not opened it in a week — the widget just goes on showing whatever
    /// day they last looked at. This check has already signed in and fetched several weeks
    /// of readings, so publishing the newest finished day out of them costs one file write.
    private func publishSnapshot(podID: String, from series: EnergySeries) {
        let calendar = Calendar.sapWallClock
        let today = calendar.startOfDay(for: Date())
        let byDay = Dictionary(grouping: series.samples.filter(\.hasReading)) {
            calendar.startOfDay(for: $0.start)
        }

        // Today is normally absent and always partial; the newest finished day is the one
        // the widget wants.
        guard let day = byDay.keys.filter({ $0 < today }).max(),
              let samples = byDay[day]
        else { return }

        // Never move a widget backwards: a check whose window ends before the day already
        // on show has nothing to add.
        if let current = SnapshotStore.shared.load(), current.podID == podID, current.day >= day {
            return
        }

        let daySeries = EnergySeries(resolution: series.resolution, samples: samples, unit: series.unit)
        SnapshotStore.shared.save(UsageSnapshot(podID: podID, day: day, series: daySeries))
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func spans(_ series: EnergySeries, atLeast threshold: TimeInterval) -> Bool {
        guard let first = series.samples.first?.start, let last = series.samples.last?.start else {
            return false
        }
        return last.timeIntervalSince(first) >= threshold
    }

    private func record(gap: FeedInWatch.Verdict, output: OutputWatch.Verdict) {
        store.value.lastFeedInCheckedAt = Date()
        store.value.lastFeedInSeenAt = gap.lastFeedIn
        store.value.lastFeedInGapHours = gap.gap.map { $0 / 3600 }

        store.value.lastOutputDayCount = output.dayCount

        // Figures from a run that could not judge would be worse than none: a stale
        // "Output now" reads as a live verdict. Clear them and say what was missing.
        if output.isConclusive {
            store.value.lastOutputRatio = output.ratio
            store.value.lastOutputBaseline = output.baseline
            store.value.lastOutputObserved = output.observed
            store.value.lastOutputNote = nil
        } else {
            store.value.lastOutputRatio = nil
            store.value.lastOutputBaseline = nil
            store.value.lastOutputObserved = nil
            store.value.lastOutputNote = output.reason?.explanation
        }
    }
}
