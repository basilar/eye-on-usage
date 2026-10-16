import AppIntents

/// Runs the feed-in health check without opening the app.
///
/// This exists because `BGAppRefreshTask` cannot be relied on for this job, and fails
/// worst in exactly this case: iOS hands out background refresh in proportion to how
/// often you open an app, so an alarm you never open the app to read is the first thing
/// it starves. The way out, with no server in the design, is to let the user schedule the
/// check themselves — a Shortcuts personal automation set to a time of day, running this
/// action. Time-of-day automations fire without asking, and this intent never opens the
/// app, so the whole thing happens silently until something is actually wrong.
///
/// Deliberately declared in the app target rather than in `EonUsageCore`: everything in
/// Core is built into the widget extension too, and an intent resolved there would run in
/// a process that cannot read the app's keychain item, so the check would fail to sign in.
struct CheckFeedInIntent: AppIntent {
    static let title: LocalizedStringResource = "Check feed-in health"
    static let description = IntentDescription(
        """
        Fetches the newest readings and warns if the inverter has stopped exporting, or if \
        its output has collapsed against what this site normally produces. Add it to a \
        daily automation in Shortcuts to have it run on its own.
        """
    )

    /// The point of the action is that nothing appears unless there is something wrong.
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        let outcome = await FeedInMonitor.shared.check(force: true)
        let sentence = FeedInMonitor.summary(outcome)
        return .result(value: sentence, dialog: IntentDialog(stringLiteral: sentence))
    }
}
