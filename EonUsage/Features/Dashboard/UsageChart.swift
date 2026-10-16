import Charts
import SwiftUI

/// Consumption and feed-in on one signed axis: bars above the baseline are energy taken
/// from the grid, bars below it are energy the inverter pushed back. One axis, one
/// baseline — the two flows stay directly comparable.
struct UsageChart: View {
    let series: EnergySeries
    let span: TimeSpan
    /// The window the chart draws, readings or not — see `TimeSpan.chartDomain(around:)`.
    let window: ClosedRange<Date>
    /// Weather over the same window. Either half is empty when its overlay is off.
    var sky: Sky = .empty
    @Binding var selection: Date?

    private var magnitude: Double {
        max(series.magnitude, 0.001)
    }

    /// Half-height of the energy plot.
    private var extent: Double { magnitude * 1.12 }

    private var showsCloud: Bool { !sky.cloud.isEmpty }

    private var domain: ClosedRange<Double> { -extent...extent }

    /// Cloud shares the energy axis's own extent rather than the whole plot: 0% sits on
    /// the bottom gridline and 100% on the top one, so one set of gridlines rules both
    /// scales and the two read against each other instead of being merely superimposed.
    private var cloudSpan: Double { energyTicks.last ?? magnitude }

    private func cloudY(_ percent: Double) -> Double {
        -cloudSpan + min(max(percent, 0), 100) / 100 * (2 * cloudSpan)
    }

    /// Ticks for the energy axis, rounded to a 1/2/2.5/5 multiple so the labels read as
    /// round numbers rather than as whatever the day's peak happened to be.
    private var energyTicks: [Double] {
        let step = Self.niceStep(magnitude / 2)
        let count = Int((magnitude / step).rounded(.down))
        guard count >= 1 else { return [0] }
        return (-count...count).map { Double($0) * step }
    }

    private static func niceStep(_ rough: Double) -> Double {
        guard rough > 0, rough.isFinite else { return 1 }
        let base = pow(10, (log10(rough)).rounded(.down))
        let fraction = rough / base
        let nice = fraction <= 1 ? 1.0 : fraction <= 2 ? 2.0 : fraction <= 2.5 ? 2.5 : fraction <= 5 ? 5.0 : 10.0
        return nice * base
    }

    var body: some View {
        // Split into builders because the whole thing in one literal outruns the type
        // checker: four mark kinds, three of them conditional.
        Chart {
            nightShading
            bars
            cloudLine
            baseline
            callout
        }
        .chartForegroundStyleScale(styleScale)
        .chartLegend(position: .top, alignment: .leading, spacing: 12)
        .chartXScale(domain: window)
        .chartYScale(domain: domain)
        .chartYAxis {
            AxisMarks(position: .leading, values: energyTicks) { value in
                AxisGridLine().foregroundStyle(Palette.gridline)
                AxisValueLabel {
                    // The sign encodes direction, which the legend already names, so the
                    // labels show magnitude and stay readable.
                    if let number = value.as(Double.self) {
                        Text(Format.number(abs(number)))
                    }
                }
                .foregroundStyle(Palette.axis)
            }

            // Always present, hidden rather than removed when the overlay is off. Taking
            // the axis away gives its width back to the plot, and the bars slide sideways
            // every time the cloud button is pressed.
            AxisMarks(position: .trailing, values: [cloudY(0), cloudY(50), cloudY(100)]) { value in
                // Labels only: the leading axis already rules the plot, and a second set
                // of gridlines over the bars would be noise.
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        // Hidden, not absent: the text still takes its width, so the plot
                        // does not widen the moment the overlay is switched off.
                        Text(Format.percent(percentAt(number)))
                            .opacity(showsCloud ? 1 : 0)
                    }
                }
                .foregroundStyle(Palette.axis)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: span == .day ? 5 : 6)) { value in
                AxisGridLine().foregroundStyle(Palette.gridline)
                AxisValueLabel(format: axisFormat, centered: false)
                    .foregroundStyle(Palette.axis)
            }
        }
        .chartXSelection(value: $selection)
        .chartPlotStyle { plot in
            plot.background(Color.clear)
        }
        .accessibilityLabel("Energy from and to the grid")
        .accessibilityValue(
            "\(Format.energy(series.totalConsumption)) drawn, \(Format.energy(series.totalFeedIn)) fed back"
        )
    }

    // MARK: - Marks

    /// The hours the sun was down. First, so everything else sits on top of it.
    @ChartContentBuilder
    private var nightShading: some ChartContent {
        ForEach(sky.daylight.nights(in: window), id: \.start) { night in
            RectangleMark(
                xStart: .value("From", night.start),
                xEnd: .value("To", night.end),
                yStart: .value("Low", domain.lowerBound),
                yEnd: .value("High", domain.upperBound)
            )
            .foregroundStyle(Palette.night)
        }
    }

    @ChartContentBuilder
    private var bars: some ChartContent {
        ForEach(series.samples) { sample in
            // Bars are spanned explicitly rather than left to `BarMark`: on a continuous
            // date axis it has no bucket step to size a ratio against, and 15-minute marks
            // collapse to nothing.
            if let consumption = sample.consumption, consumption > 0 {
                RectangleMark(
                    xStart: .value("Start", sample.start),
                    xEnd: .value("End", barEnd(of: sample)),
                    yStart: .value("Energy", 0),
                    yEnd: .value("Energy", consumption)
                )
                .foregroundStyle(by: .value("Direction", ChannelDirection.consumption.title))
                .clipShape(.rect(topLeadingRadius: 2, topTrailingRadius: 2))
            }

            if let feedIn = sample.feedIn, feedIn > 0 {
                RectangleMark(
                    xStart: .value("Start", sample.start),
                    xEnd: .value("End", barEnd(of: sample)),
                    yStart: .value("Energy", -feedIn),
                    yEnd: .value("Energy", 0)
                )
                .foregroundStyle(by: .value("Direction", ChannelDirection.feedIn.title))
                .clipShape(.rect(bottomLeadingRadius: 2, bottomTrailingRadius: 2))
            }
        }
    }

    /// After the bars, so it reads as an overlay; the opacity is what keeps the bars
    /// underneath legible where the two cross.
    @ChartContentBuilder
    private var cloudLine: some ChartContent {
        ForEach(sky.cloud.samples) { sample in
            LineMark(
                x: .value("Time", sample.start),
                y: .value("Cloud", cloudY(sample.percent))
            )
            .foregroundStyle(by: .value("Direction", Self.cloudKey))
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.catmullRom)
            .opacity(0.55)
        }
    }

    @ChartContentBuilder
    private var baseline: some ChartContent {
        RuleMark(y: .value("Baseline", 0))
            .lineStyle(StrokeStyle(lineWidth: 1))
            .foregroundStyle(Palette.axis)
    }

    @ChartContentBuilder
    private var callout: some ChartContent {
        if let selected = selectedSample {
            RuleMark(x: .value("Selected", selected.start))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .foregroundStyle(Palette.axis)
                .annotation(
                    position: .top,
                    spacing: 4,
                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                ) {
                    ReadingCallout(sample: selected, span: span)
                }
        }
    }

    static let cloudKey = "Cloud"

    private var styleScale: KeyValuePairs<String, Color> {
        showsCloud
            ? [
                ChannelDirection.consumption.title: Palette.consumption,
                ChannelDirection.feedIn.title: Palette.feedIn,
                Self.cloudKey: Palette.cloud,
              ]
            : [
                ChannelDirection.consumption.title: Palette.consumption,
                ChannelDirection.feedIn.title: Palette.feedIn,
              ]
    }

    /// Inverts `cloudY`, so the trailing axis can label a plot coordinate as a percentage.
    private func percentAt(_ y: Double) -> Double {
        guard cloudSpan > 0 else { return 0 }
        return (y + cloudSpan) / (2 * cloudSpan)
    }

    /// Where a bucket's bar stops. The sliver left over separates neighbouring bars
    /// without eating into them when a day packs in 96 of them.
    private func barEnd(of sample: EnergySample) -> Date {
        sample.start.addingTimeInterval(Double(series.resolution.minutes) * 60 * 0.88)
    }

    /// The bucket under the touch, if there is one. The window is drawn whole even when
    /// the portal has only filled part of it, so a tap on an unpublished stretch has to
    /// come back empty rather than label the nearest bar days away.
    private var selectedSample: EnergySample? {
        guard let selection else { return nil }
        let nearest = series.samples.min {
            abs($0.start.timeIntervalSince(selection)) < abs($1.start.timeIntervalSince(selection))
        }
        let bucket = Double(series.resolution.minutes) * 60
        return nearest.flatMap {
            abs($0.start.timeIntervalSince(selection)) <= bucket ? $0 : nil
        }
    }

    private var axisFormat: Date.FormatStyle {
        switch span {
        case .day:
            return .dateTime.hour().onMeterClock
        case .week:
            return .dateTime.weekday(.abbreviated).onMeterClock
        case .month:
            return .dateTime.day().onMeterClock
        }
    }
}

/// The tooltip shown against the selected bar.
private struct ReadingCallout: View {
    let sample: EnergySample
    let span: TimeSpan

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(heading)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            row(ChannelDirection.consumption, value: sample.consumption)
            row(ChannelDirection.feedIn, value: sample.feedIn)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        // An opaque token, not a material. The annotation is allowed to overflow the
        // chart, and a material that lands outside its container samples a backdrop that
        // is not the card behind it — it rendered near black, and the figures, which
        // wear `.primary`, went black on black.
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.16), radius: 5, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.gridline, lineWidth: 0.5)
        )
    }

    private var heading: String {
        switch span {
        case .day: return Format.time(sample.start)
        case .week: return "\(Format.day(sample.start)) \(Format.time(sample.start))"
        case .month: return Format.day(sample.start)
        }
    }

    @ViewBuilder
    private func row(_ direction: ChannelDirection, value: Double?) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Palette.color(for: direction))
                .frame(width: 7, height: 7)
            Text(direction.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            // `nil` is not zero: a bucket the meter never reported says so rather than
            // claiming a measured 0,00.
            Text(value.map { Format.energy($0) } ?? "\u{2014}")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
    }
}

#Preview {
    let day = Calendar.sapWallClock.startOfDay(for: .now.addingTimeInterval(-86400))
    UsageChart(
        series: DemoData.series(from: day, to: day),
        span: .day,
        window: TimeSpan.day.chartDomain(around: day),
        sky: .empty,
        selection: .constant(nil)
    )
    .frame(height: 260)
    .padding()
}
