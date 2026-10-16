import Foundation

enum Format {
    /// Energy figures earn a decimal place or two depending on how small they are —
    /// a 0.04 kWh quarter-hour and a 312 kWh month should both read sensibly.
    static func energy(_ value: Double, unit: String = "kWh") -> String {
        "\(number(value)) \(unit)"
    }

    static func number(_ value: Double, fractionDigits: Int? = nil) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(fractionDigits ?? self.fractionDigits(for: value)))
                .grouping(.automatic)
        )
    }

    /// The decimals `number(_:)` gives a value on its own. A figure derived from others —
    /// a net against its two totals — should be asked for the finest precision of its
    /// inputs, or it reads as rounded away next to the numbers it was subtracted from.
    static func fractionDigits(for value: Double) -> Int {
        let magnitude = abs(value)
        return magnitude >= 100 ? 0 : (magnitude >= 10 ? 1 : 2)
    }

    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Timestamps come back on the meter's wall clock; format them on that clock too,
    /// otherwise a reading at 13:15 would shift with the phone's time zone.
    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().onMeterClock)
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).onMeterClock)
    }

    static func longDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).onMeterClock)
    }

    static func month(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year().onMeterClock)
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

extension Date.FormatStyle {
    /// Renders on the meter's wall clock instead of the device's time zone, so a reading
    /// recorded at 13:15 reads as 13:15 wherever the phone happens to be.
    var onMeterClock: Date.FormatStyle {
        var copy = self
        copy.timeZone = Calendar.sapWallClock.timeZone
        return copy
    }
}
