import AppIntents
import Foundation

/// Opens the app on the dashboard. Used by the Control Center control and by widget taps.
struct OpenDashboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Electricity Usage"
    static let description = IntentDescription("Opens the quarter-hourly consumption and feed-in charts.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// Reports the most recent day the app has fetched.
///
/// It answers from the shared snapshot rather than calling the portal: the readings are
/// settled data published a day in arrears, so there is nothing newer to fetch on demand,
/// and Siri stays instant.
struct EnergySummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Get electricity summary"
    static let description = IntentDescription(
        "Reports how much electricity was drawn from the grid and fed back on the most recent day."
    )

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let snapshot = SnapshotStore.shared.load() else {
            let message = "No readings have been downloaded yet. Open the app once to fetch them."
            return .result(value: message, dialog: IntentDialog(stringLiteral: message))
        }

        let day = Format.longDay(snapshot.day)
        let drawn = Format.energy(snapshot.consumption)
        let fed = Format.energy(snapshot.feedIn)
        let balance = snapshot.net < 0
            ? "a net export of \(Format.energy(-snapshot.net))"
            : "a net import of \(Format.energy(snapshot.net))"

        let sentence = "On \(day) you drew \(drawn) from the grid and fed back \(fed) — \(balance)."
        return .result(value: sentence, dialog: IntentDialog(stringLiteral: sentence))
    }
}
