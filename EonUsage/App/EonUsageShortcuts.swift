import AppIntents

/// Registers the phrases Siri and the Shortcuts app offer without any setup — which is
/// also how a Home automation can reach this data, since Home automations can run
/// shortcuts.
struct EonUsageShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: EnergySummaryIntent(),
            phrases: [
                "How much electricity did I use in \(.applicationName)",
                "Check my \(.applicationName) summary",
            ],
            shortTitle: "Electricity summary",
            systemImageName: "bolt.horizontal"
        )
        AppShortcut(
            intent: CheckFeedInIntent(),
            phrases: [
                "Check my \(.applicationName) feed-in",
                "Is my inverter working in \(.applicationName)",
            ],
            shortTitle: "Check feed-in",
            systemImageName: "bolt.badge.automatic"
        )
        AppShortcut(
            intent: OpenDashboardIntent(),
            phrases: ["Open \(.applicationName)"],
            shortTitle: "Open usage",
            systemImageName: "chart.bar.xaxis"
        )
    }
}
