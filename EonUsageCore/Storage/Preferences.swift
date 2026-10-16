import Foundation

/// Everything the app remembers between launches that isn't secret.
struct Preferences: Codable, Sendable, Equatable {
    var partnerID: String?
    var partnerAuthID: String?
    var sparte: String = Sparte.electricity
    var podID: String?
    var intervalID: String?
    /// Corrections to the automatic channel classification, keyed by variable id.
    ///
    /// Nothing writes this any more — the Settings picker is gone, because
    /// `ChannelClassifier` reads the portal's own `+A`/`-A` naming correctly. It is still
    /// read when building the catalogue, so an override stored by an earlier version keeps
    /// working rather than silently inverting somebody's charts.
    var channelOverrides: [String: ChannelDirection] = [:]

    // MARK: Feed-in alert

    var feedInAlertEnabled = false
    /// How long the grid may go without receiving anything before the app warns.
    var feedInAlertThresholdHours = 24
    /// When the app last raised the alarm, so it does not repeat more than daily.
    var lastFeedInAlertAt: Date?
    /// The last verdict, kept so Settings can show the current state without refetching.
    var lastFeedInGapHours: Double?
    var lastFeedInSeenAt: Date?
    var lastFeedInCheckedAt: Date?

    // MARK: Output-drop alert

    /// Fraction of this site's normal peak below which output counts as collapsed.
    /// Zero turns the check off. See `OutputWatch`.
    var outputDropRatio: Double = 0.2
    /// How many recent days are judged together before the app calls it.
    var outputDropDays = 3
    var lastOutputDropAlertAt: Date?
    var lastOutputRatio: Double?
    var lastOutputBaseline: Double?
    var lastOutputObserved: Double?
    /// Days of readings the last drop check had to work with.
    var lastOutputDayCount: Int?
    /// Why the last drop check could not judge, if it could not. Rendered at check time so
    /// Settings can explain an empty panel without re-deriving it.
    var lastOutputNote: String?

    // MARK: Weather overlay

    /// Where to fetch cloud cover for. A delivery point does not move, so this is set once
    /// rather than tracked.
    var weatherLocation: WeatherLocation?
    var showsCloudCover = false
    /// Shades the hours the sun was down.
    var showsDaylight = false

    var feedInAlertThreshold: TimeInterval {
        TimeInterval(feedInAlertThresholdHours) * 3600
    }

    var watchesOutputDrop: Bool { outputDropRatio > 0 }

    init() {}

    enum CodingKeys: String, CodingKey {
        case partnerID, partnerAuthID, sparte, podID, intervalID, channelOverrides
        case feedInAlertEnabled, feedInAlertThresholdHours, lastFeedInAlertAt
        case lastFeedInGapHours, lastFeedInSeenAt, lastFeedInCheckedAt
        case outputDropRatio, outputDropDays, lastOutputDropAlertAt
        case lastOutputRatio, lastOutputBaseline, lastOutputObserved
        case lastOutputDayCount, lastOutputNote
        case weatherLocation, showsCloudCover, showsDaylight
    }

    /// Decoded key by key rather than by the synthesised initialiser, which treats a
    /// missing key as a failure. `PreferencesStore` falls back to `.empty` when decoding
    /// throws, so under the synthesised version every new setting added here would silently
    /// wipe the delivery point, the partner and the channel overrides on first launch after
    /// the update. Absent keys keep their defaults instead.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }

        partnerID = try? container.decodeIfPresent(String.self, forKey: .partnerID)
        partnerAuthID = try? container.decodeIfPresent(String.self, forKey: .partnerAuthID)
        sparte = value(.sparte, Sparte.electricity)
        podID = try? container.decodeIfPresent(String.self, forKey: .podID)
        intervalID = try? container.decodeIfPresent(String.self, forKey: .intervalID)
        channelOverrides = value(.channelOverrides, [:])

        feedInAlertEnabled = value(.feedInAlertEnabled, false)
        feedInAlertThresholdHours = value(.feedInAlertThresholdHours, 24)
        lastFeedInAlertAt = try? container.decodeIfPresent(Date.self, forKey: .lastFeedInAlertAt)
        lastFeedInGapHours = try? container.decodeIfPresent(Double.self, forKey: .lastFeedInGapHours)
        lastFeedInSeenAt = try? container.decodeIfPresent(Date.self, forKey: .lastFeedInSeenAt)
        lastFeedInCheckedAt = try? container.decodeIfPresent(Date.self, forKey: .lastFeedInCheckedAt)

        outputDropRatio = value(.outputDropRatio, 0.2)
        outputDropDays = value(.outputDropDays, 3)
        lastOutputDropAlertAt = try? container.decodeIfPresent(Date.self, forKey: .lastOutputDropAlertAt)
        lastOutputRatio = try? container.decodeIfPresent(Double.self, forKey: .lastOutputRatio)
        lastOutputBaseline = try? container.decodeIfPresent(Double.self, forKey: .lastOutputBaseline)
        lastOutputObserved = try? container.decodeIfPresent(Double.self, forKey: .lastOutputObserved)
        lastOutputDayCount = try? container.decodeIfPresent(Int.self, forKey: .lastOutputDayCount)
        lastOutputNote = try? container.decodeIfPresent(String.self, forKey: .lastOutputNote)

        weatherLocation = try? container.decodeIfPresent(WeatherLocation.self, forKey: .weatherLocation)
        showsCloudCover = value(.showsCloudCover, false)
        showsDaylight = value(.showsDaylight, false)
    }

    static let empty = Preferences()
}

/// Reads and writes `Preferences` in the shared defaults so widgets see the same POD.
@MainActor
@Observable
final class PreferencesStore {
    static let shared = PreferencesStore()

    private let key = "preferences"
    private let defaults: UserDefaults

    var value: Preferences {
        didSet { persist() }
    }

    init(defaults: UserDefaults = SharedContainer.defaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder.portal.decode(Preferences.self, from: data) {
            value = stored
        } else {
            value = .empty
        }
    }

    func reset() {
        value = .empty
    }

    private func persist() {
        guard let data = try? JSONEncoder.portal.encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
