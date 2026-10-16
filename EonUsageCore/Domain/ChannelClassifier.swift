import Foundation

/// Works out which measured variables represent energy taken from the grid and which
/// represent energy pushed back into it by an inverter.
///
/// W1000 names channels in a mix of Hungarian prose and metering shorthand — `+A` / `-A`
/// for the quarter-hourly active-energy channels, OBIS `1.8.0` / `2.8.0` for the
/// cumulative registers. The user can always override the result in Settings, so this is
/// a starting guess rather than the last word.
enum ChannelClassifier {
    private static let feedInMarkers = [
        "2.8.0", "betapl", "visszatapl", "termel", "kiadott", "leadott", "export", "feed",
    ]

    private static let consumptionMarkers = [
        "1.8.0", "vetelez", "fogyaszt", "vett", "import", "consumption", "veteli",
    ]

    static func direction(id: String, name: String) -> ChannelDirection {
        let haystack = normalise(name + " " + id)

        // The signed active-energy channels are the unambiguous case, and they must be
        // tested before the prose markers: "-A" beats a description mentioning fogyasztás.
        if hasSignedToken(haystack, sign: "-") { return .feedIn }
        if hasSignedToken(haystack, sign: "+") { return .consumption }

        if feedInMarkers.contains(where: haystack.contains) { return .feedIn }
        if consumptionMarkers.contains(where: haystack.contains) { return .consumption }

        // Reactive power (R), apparent power (S) and gas volume are deliberately "other".
        return .other
    }

    /// Matches a standalone `+A` / `-A` token rather than any stray sign in the text.
    private static func hasSignedToken(_ text: String, sign: Character) -> Bool {
        let characters = Array(text)
        for index in characters.indices where characters[index] == sign {
            guard index + 1 < characters.count, characters[index + 1] == "a" else { continue }
            let followsEnd = index + 2 == characters.count || !characters[index + 2].isLetter
            let precedesStart = index == 0 || !characters[index - 1].isLetter
            if followsEnd && precedesStart { return true }
        }
        return false
    }

    private static func normalise(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "hu_HU"))
    }

    /// Picks the resolution that matches the 15-minute profile the app is built around.
    ///
    /// The service labels its intervals in Hungarian and the ids are not stable enough to
    /// hard-code, so this prefers an explicit "15", then the shortest horizon (the raw
    /// interval series always has the tightest day limit), then id `1`.
    static func quarterHourInterval(from intervals: [IntervalDTO]) -> IntervalDTO? {
        if let explicit = intervals.first(where: { $0.description.contains("15") }) {
            return explicit
        }
        let withHorizon = intervals.filter { $0.horizon > 0 }
        if let tightest = withHorizon.min(by: { $0.horizon < $1.horizon }) {
            return tightest
        }
        return intervals.first { $0.intervalId == "1" } ?? intervals.first
    }
}
