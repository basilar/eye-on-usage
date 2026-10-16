import SwiftUI

/// The headline figures for the window on screen.
struct SummaryTiles: View {
    let series: EnergySeries
    let span: TimeSpan

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    var body: some View {
        VStack(spacing: 12) {
            LazyVGrid(columns: columns, spacing: 12) {
                StatTile(
                    title: ChannelDirection.consumption.title,
                    value: Format.number(series.totalConsumption, fractionDigits: series.summaryDigits),
                    unit: series.unit,
                    accent: Palette.consumption,
                    symbol: "arrow.down.to.line"
                )
                StatTile(
                    title: ChannelDirection.feedIn.title,
                    value: Format.number(series.totalFeedIn, fractionDigits: series.summaryDigits),
                    unit: series.unit,
                    accent: Palette.feedIn,
                    symbol: "arrow.up.to.line"
                )
            }

            BalanceTile(series: series, span: span)
        }
    }
}

extension EnergySeries {
    /// One precision for all three headline figures. The net is the difference of the two
    /// totals above it, so rounding them apart makes the subtraction fail on screen: 26,69
    /// shown as 26,7 leaves 26,7 − 2,58 = 24,12 against a correct net of 24,11.
    var summaryDigits: Int {
        max(
            Format.fractionDigits(for: totalConsumption),
            Format.fractionDigits(for: totalFeedIn)
        )
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let unit: String
    let accent: Color
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }
}

/// Net position plus the peaks — the two questions a summary always gets asked next.
struct BalanceTile: View {
    let series: EnergySeries
    let span: TimeSpan

    /// Both figures say the same thing — one in kWh, one against what was drawn — so both
    /// wear the same colour: red when the meter ran net inwards, green when it ran net
    /// outwards, plain when the two cancelled.
    private var tint: Color { Palette.color(for: series.balance) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(series.balance.totalTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(Format.number(abs(series.netImport), fractionDigits: series.summaryDigits))
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                            .contentTransition(.numericText())
                            .foregroundStyle(tint)
                        Text(series.unit)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if let share = series.netShare {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(series.balance.shareTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(Format.percent(share))
                            .font(.system(.title2, design: .rounded, weight: .semibold))
                            .contentTransition(.numericText())
                            .foregroundStyle(tint)
                    }
                }
            }

            Divider()

            HStack(spacing: 16) {
                PeakLabel(
                    caption: "Peak \(ChannelDirection.consumption.title.lowercased())",
                    sample: series.peakConsumption,
                    value: series.peakConsumption?.consumption,
                    unit: series.unit,
                    accent: Palette.consumption,
                    span: span
                )
                PeakLabel(
                    caption: "Peak \(ChannelDirection.feedIn.title.lowercased())",
                    sample: series.peakFeedIn,
                    value: series.peakFeedIn?.feedIn,
                    unit: series.unit,
                    accent: Palette.feedIn,
                    span: span
                )
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }
}

private struct PeakLabel: View {
    let caption: String
    let sample: EnergySample?
    let value: Double?
    let unit: String
    let accent: Color
    let span: TimeSpan

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent)
                    .frame(width: 7, height: 7)
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value.map { Format.energy($0, unit: unit) } ?? "—")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
            Text(sample.map { stamp(for: $0) } ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stamp(for sample: EnergySample) -> String {
        switch span {
        case .day: return Format.time(sample.start)
        case .week: return "\(Format.day(sample.start)) \(Format.time(sample.start))"
        case .month: return Format.day(sample.start)
        }
    }
}
