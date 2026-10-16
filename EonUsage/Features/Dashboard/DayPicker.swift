import SwiftUI

/// A month grid for choosing the day on screen.
///
/// Rolled by hand rather than wrapping `DatePicker(.graphical)`. That control sizes itself
/// from its container and quietly drops columns when it gets less width than it wants — in
/// a popover it collapses to three weekdays and an unreadable header — and it works in the
/// device's calendar and time zone, which is the wrong clock for a meter reading.
struct DayPicker: View {
    /// The chosen day. Written on the meter's clock; the caller normalises it.
    @Binding var selection: Date
    /// The newest selectable day. The portal has nothing beyond it.
    let latest: Date

    @Environment(\.dismiss) private var dismiss
    @State private var visibleMonth: Date

    private let calendar = Calendar.sapWallClock
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    init(selection: Binding<Date>, latest: Date) {
        _selection = selection
        self.latest = latest
        _visibleMonth = State(initialValue: Calendar.sapWallClock.startOfMonth(for: selection.wrappedValue))
    }

    var body: some View {
        VStack(spacing: 18) {
            header
            VStack(spacing: 10) {
                weekdays
                grid
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 26)
        .padding(.bottom, 24)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            // The month steps one at a time; the year is a menu, because paging back two
            // years of history one month at a time is not navigation.
            Menu {
                ForEach(selectableYears, id: \.self) { year in
                    Button { show(year: year) } label: { Text(verbatim: "\(year)") }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(Format.month(visibleMonth))
                        .font(.title3.weight(.semibold))
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            }
            .accessibilityLabel("Year")

            Spacer(minLength: 0)

            Button { step(-1) } label: {
                Image(systemName: "chevron.left").frame(width: 36, height: 34)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Previous month")

            Button { step(1) } label: {
                Image(systemName: "chevron.right").frame(width: 36, height: 34)
            }
            .buttonStyle(.bordered)
            .disabled(!canStepForward)
            .accessibilityLabel("Next month")
        }
    }

    private var weekdays: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Grid

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                if let day {
                    cell(day)
                } else {
                    Color.clear.frame(height: Self.cell)
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ day: Date) -> some View {
        let isSelected = calendar.isDate(day, inSameDayAs: selection)
        let isToday = calendar.isDate(day, inSameDayAs: latest)
        let isUnpublished = day > latest

        Button {
            selection = day
            dismiss()
        } label: {
            Text(verbatim: "\(calendar.component(.day, from: day))")
                .font(.title3.weight(isSelected || isToday ? .semibold : .regular))
                .monospacedDigit()
                .frame(width: Self.cell, height: Self.cell)
                .background {
                    if isSelected {
                        Circle().fill(Color.accentColor)
                    } else if isToday {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
                    }
                }
                .foregroundStyle(foreground(isSelected: isSelected, isUnpublished: isUnpublished))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(isUnpublished)
        .accessibilityLabel(Format.longDay(day))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func foreground(isSelected: Bool, isUnpublished: Bool) -> Color {
        if isSelected { return .white }
        if isUnpublished { return Color(uiColor: .tertiaryLabel) }
        return .primary
    }

    private var footer: some View {
        Button {
            selection = latest
            dismiss()
        } label: {
            Label("Today", systemImage: "calendar")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(calendar.isDate(selection, inSameDayAs: latest))
    }

    // MARK: - Layout of the month

    /// The month laid out in weeks, with leading blanks so the 1st lands on its weekday
    /// and trailing blanks to a constant six rows — otherwise the sheet would change
    /// height as you page between a five-row month and a six-row one.
    private var cells: [Date?] {
        let first = calendar.startOfMonth(for: visibleMonth)
        guard let days = calendar.range(of: .day, in: .month, for: first) else { return [] }

        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - calendar.firstWeekday + 7) % 7

        var result: [Date?] = Array(repeating: nil, count: leading)
        result += days.map { calendar.date(byAdding: .day, value: $0 - 1, to: first) }
        result += Array(repeating: nil, count: max(0, Self.rows * 7 - result.count))
        return result
    }

    /// Six weeks is the most any month can touch.
    private static let rows = 6
    /// Day cells sized for a thumb rather than a cursor.
    private static let cell: CGFloat = 46

    /// The calendar's own symbols, rotated to start on its first weekday — Monday here.
    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let shift = min(max(calendar.firstWeekday - 1, 0), symbols.count - 1)
        return Array(symbols[shift...] + symbols[..<shift])
    }

    // MARK: - Moving about

    private var canStepForward: Bool {
        guard let next = calendar.date(byAdding: .month, value: 1, to: visibleMonth) else { return false }
        return next <= calendar.startOfMonth(for: latest)
    }

    private func step(_ direction: Int) {
        guard let moved = calendar.date(byAdding: .month, value: direction, to: visibleMonth) else { return }
        visibleMonth = min(moved, calendar.startOfMonth(for: latest))
    }

    private var selectableYears: [Int] {
        let current = calendar.component(.year, from: latest)
        return Array(((current - 5)...current).reversed())
    }

    private func show(year: Int) {
        var components = calendar.dateComponents([.year, .month], from: visibleMonth)
        components.year = year
        guard let moved = calendar.date(from: components) else { return }
        visibleMonth = min(moved, calendar.startOfMonth(for: latest))
    }
}

private extension Calendar {
    func startOfMonth(for date: Date) -> Date {
        self.date(from: dateComponents([.year, .month], from: date)) ?? startOfDay(for: date)
    }
}

#Preview {
    @Previewable @State var day = Calendar.sapWallClock.startOfDay(for: .now)
    DayPicker(selection: $day, latest: Calendar.sapWallClock.startOfDay(for: .now))
}
