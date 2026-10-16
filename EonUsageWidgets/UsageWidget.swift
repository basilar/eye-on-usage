import Charts
import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
    /// True for the widget gallery, where sample figures must not look like real ones.
    let isPlaceholder: Bool
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, snapshot: DemoData.snapshot(), isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let stored = SnapshotStore.shared.load()
        completion(
            UsageEntry(
                date: .now,
                snapshot: stored ?? DemoData.snapshot(),
                isPlaceholder: stored == nil
            )
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = UsageEntry(date: .now, snapshot: SnapshotStore.shared.load(), isPlaceholder: false)
        // The app writes a new snapshot and reloads the timeline itself; this cadence is
        // only a backstop so the "last updated" wording does not go stale.
        let next = Calendar.current.date(byAdding: .hour, value: 3, to: .now) ?? .now.addingTimeInterval(10800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct UsageWidget: Widget {
    static let kind = "hu.randart.EonUsage.usage"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: UsageProvider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Electricity")
        .description("Energy drawn from the grid and fed back on your most recent day.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .accessoryInline:
                Text("↓\(Format.number(snapshot.consumption)) ↑\(Format.number(snapshot.feedIn)) kWh")
            case .accessoryRectangular:
                AccessoryView(snapshot: snapshot)
            case .systemMedium:
                MediumView(snapshot: snapshot, redacted: entry.isPlaceholder)
            default:
                SmallView(snapshot: snapshot, redacted: entry.isPlaceholder)
            }
        } else {
            EmptyStateView()
        }
    }
}

// MARK: - Families

private struct SmallView: View {
    let snapshot: UsageSnapshot
    var redacted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DayCaption(snapshot: snapshot)

            Spacer(minLength: 6)

            FlowRow(direction: .consumption, value: snapshot.consumption)
            FlowRow(direction: .feedIn, value: snapshot.feedIn)

            Spacer(minLength: 6)

            MiniChart(bars: snapshot.bars)
                .frame(height: 30)
        }
        .privacySensitive(redacted)
    }
}

private struct MediumView: View {
    let snapshot: UsageSnapshot
    var redacted = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                DayCaption(snapshot: snapshot)
                Spacer(minLength: 8)
                FlowRow(direction: .consumption, value: snapshot.consumption)
                FlowRow(direction: .feedIn, value: snapshot.feedIn)
                Spacer(minLength: 4)
                Text(balance)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 132, alignment: .leading)

            MiniChart(bars: snapshot.bars, showsAxis: true)
        }
        .privacySensitive(redacted)
    }

    private var balance: String {
        snapshot.net < 0
            ? "Net export \(Format.energy(-snapshot.net))"
            : "Net import \(Format.energy(snapshot.net))"
    }
}

private struct AccessoryView: View {
    let snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Format.day(snapshot.day))
                .font(.caption2)
                .widgetAccentable()
            Text("↓ \(Format.energy(snapshot.consumption))")
                .font(.headline)
            Text("↑ \(Format.energy(snapshot.feedIn))")
                .font(.caption)
        }
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "bolt.slash")
                .foregroundStyle(.secondary)
            Text("Open the app to load readings")
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Pieces

private struct DayCaption: View {
    let snapshot: UsageSnapshot

    var body: some View {
        Text(Format.day(snapshot.day))
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct FlowRow: View {
    let direction: ChannelDirection
    let value: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Palette.color(for: direction))
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
            Text(Format.number(value))
                .font(.system(.title3, design: .rounded, weight: .semibold))
            Text("kWh")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityLabel("\(direction.title) \(Format.energy(value))")
    }
}

/// Hourly buckets, drawn on the same signed baseline as the app's chart.
private struct MiniChart: View {
    let bars: [UsageSnapshot.Bar]
    var showsAxis = false

    var body: some View {
        Chart {
            ForEach(bars, id: \.start) { bar in
                if bar.consumption > 0 {
                    BarMark(
                        x: .value("Hour", bar.start, unit: .hour),
                        yStart: .value("Energy", 0),
                        yEnd: .value("Energy", bar.consumption),
                        width: .ratio(0.7)
                    )
                    .foregroundStyle(Palette.consumption)
                }
                if bar.feedIn > 0 {
                    BarMark(
                        x: .value("Hour", bar.start, unit: .hour),
                        yStart: .value("Energy", -bar.feedIn),
                        yEnd: .value("Energy", 0),
                        width: .ratio(0.7)
                    )
                    .foregroundStyle(Palette.feedIn)
                }
            }
        }
        .chartYAxis(.hidden)
        .chartXAxis {
            if showsAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) {
                    AxisValueLabel(format: .dateTime.hour().onMeterClock)
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.axis)
                }
            }
        }
        .chartLegend(.hidden)
    }
}

#Preview(as: .systemMedium) {
    UsageWidget()
} timeline: {
    UsageEntry(date: .now, snapshot: DemoData.snapshot(), isPlaceholder: true)
}
