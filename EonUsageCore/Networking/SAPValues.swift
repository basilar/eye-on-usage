import Foundation

/// SAP Gateway (OData V2, JSON) serialises `Edm.DateTime` as `/Date(1750000000000)/`,
/// optionally with a trailing minute offset: `/Date(1750000000000+0060)/`.
///
/// The W1000 service encodes *local wall-clock* readings into that epoch value and the
/// portal's own web client renders them with `timeZone: "UTC"`. Decoding the epoch and
/// then reading its components in UTC therefore reproduces the timestamp the meter
/// actually recorded — see `Calendar.sapWallClock`.
enum SAPDate {
    static func parse(_ raw: String) -> Date? {
        guard let open = raw.firstIndex(of: "("), let close = raw.lastIndex(of: ")"), open < close else {
            return nil
        }
        var body = String(raw[raw.index(after: open)..<close])

        var offsetMinutes = 0
        if let signIndex = body.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) {
            let sign: Double = body[signIndex] == "-" ? -1 : 1
            let offsetText = body[body.index(after: signIndex)...]
            offsetMinutes = Int(sign * (Double(offsetText) ?? 0))
            body = String(body[body.startIndex..<signIndex])
        }

        guard let milliseconds = Double(body) else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000 + Double(offsetMinutes) * 60)
    }

    /// Formats a date the way the service expects it inside a `datetime'…'` key predicate.
    static func literal(_ date: Date, endOfDay: Bool) -> String {
        var components = Calendar.sapWallClock.dateComponents([.year, .month, .day], from: date)
        components.hour = endOfDay ? 23 : 0
        components.minute = endOfDay ? 59 : 0
        components.second = endOfDay ? 59 : 1
        let day = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
        let time = String(format: "%02d:%02d:%02d", components.hour ?? 0, components.minute ?? 0, components.second ?? 0)
        return "\(day)T\(time)"
    }
}

extension Calendar {
    /// The calendar to read W1000 timestamps with. The service bakes the meter's local
    /// wall-clock time into a UTC epoch, so UTC components are the meaningful ones.
    static let sapWallClock: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.firstWeekday = 2 // Monday, as in Hungary
        return calendar
    }()
}

/// SAP is inconsistent about whether a scalar arrives as a JSON number, a JSON bool or a
/// quoted string. These wrappers decode whichever form shows up.
struct SAPString: Codable, Sendable, Hashable {
    let value: String

    init(_ value: String) { self.value = value }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            value = text
        } else if let number = try? container.decode(Double.self) {
            value = number == number.rounded() ? String(Int(number)) : String(number)
        } else if let flag = try? container.decode(Bool.self) {
            value = flag ? "X" : ""
        } else {
            value = ""
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct SAPInt: Codable, Sendable, Hashable {
    let value: Int

    init(_ value: Int) { self.value = value }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            value = number
        } else if let text = try? container.decode(String.self) {
            value = Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
        } else if let number = try? container.decode(Double.self) {
            value = Int(number)
        } else {
            value = 0
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct SAPBool: Codable, Sendable, Hashable {
    let value: Bool

    init(_ value: Bool) { self.value = value }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            value = flag
        } else if let text = try? container.decode(String.self) {
            value = ["X", "true", "TRUE", "1", "Y"].contains(text)
        } else if let number = try? container.decode(Int.self) {
            value = number != 0
        } else {
            value = false
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// Parses the numeric strings the MeasData rows carry (`""` means "no reading").
enum SAPNumber {
    static func parse(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return Double(trimmed.replacingOccurrences(of: ",", with: "."))
    }
}
