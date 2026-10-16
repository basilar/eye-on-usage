import SwiftUI

/// The chart's data as text — the accessible route to the same numbers, and the quickest
/// way to check one particular slot.
struct ReadingsTableView: View {
    let series: EnergySeries
    let span: TimeSpan

    @Environment(\.dismiss) private var dismiss

    private var rows: [EnergySample] {
        series.samples.filter(\.hasReading)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rows) { sample in
                        HStack {
                            Text(stamp(for: sample))
                                .font(.subheadline)
                                .monospacedDigit()
                            Spacer(minLength: 12)
                            value(sample.consumption, accent: Palette.consumption)
                            value(sample.feedIn, accent: Palette.feedIn)
                        }
                    }
                } header: {
                    HStack {
                        Text(series.resolution.title)
                        Spacer()
                        Text(ChannelDirection.consumption.title)
                            .frame(width: 74, alignment: .trailing)
                        Text(ChannelDirection.feedIn.title)
                            .frame(width: 74, alignment: .trailing)
                    }
                } footer: {
                    Text("All values in \(series.unit).")
                }
            }
            .navigationTitle("Readings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func value(_ number: Double?, accent: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: 6, height: 6)
            Text(number.map { Format.number($0) } ?? "—")
                .font(.subheadline)
                .monospacedDigit()
        }
        .frame(width: 74, alignment: .trailing)
    }

    private func stamp(for sample: EnergySample) -> String {
        switch span {
        case .day: return Format.time(sample.start)
        case .week: return "\(Format.day(sample.start)) \(Format.time(sample.start))"
        case .month: return Format.day(sample.start)
        }
    }
}
