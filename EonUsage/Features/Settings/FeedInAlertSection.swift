import SwiftUI

/// Settings for the "the inverter has stopped exporting" warning.
struct FeedInAlertSection: View {
    @Environment(AppModel.self) private var app

    @State private var isAuthorized = true
    @State private var isChecking = false
    @State private var resultText: String?

    private static let thresholdChoices = [12, 24, 36, 48, 72]
    /// Fraction of a normal peak below which output counts as collapsed. Zero is off.
    private static let dropChoices: [Double] = [0, 0.5, 0.35, 0.2, 0.1]

    var body: some View {
        @Bindable var preferences = app.preferences

        Section {
            Toggle("Warn me when feed-in stops", isOn: $preferences.value.feedInAlertEnabled)
                .onChange(of: preferences.value.feedInAlertEnabled) { _, enabled in
                    Task { await apply(enabled: enabled) }
                }

            if preferences.value.feedInAlertEnabled {
                Picker("After", selection: $preferences.value.feedInAlertThresholdHours) {
                    ForEach(Self.thresholdChoices, id: \.self) { hours in
                        Text(hours < 48 ? "\(hours) hours" : "\(hours / 24) days").tag(hours)
                    }
                }

                Picker("Or drops below", selection: $preferences.value.outputDropRatio) {
                    ForEach(Self.dropChoices, id: \.self) { ratio in
                        Text(ratio == 0 ? "Off" : "\(Format.percent(ratio)) of normal").tag(ratio)
                    }
                }

                if !isAuthorized {
                    Label(
                        "Notifications are turned off for this app. Enable them in iOS Settings.",
                        systemImage: "bell.slash"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }

                status

                Button {
                    Task { await checkNow() }
                } label: {
                    HStack {
                        Text("Check now")
                        if isChecking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isChecking || app.isDemo)

                if let resultText {
                    Text(resultText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Feed-in alert")
        } footer: {
            Text(footerText)
        }
        .task { isAuthorized = await AlertCenter.shared.isAuthorized() }

        if app.preferences.value.feedInAlertEnabled {
            scheduleSection
        }
    }

    @ViewBuilder
    private var status: some View {
        let preferences = app.preferences.value

        if let seen = preferences.lastFeedInSeenAt {
            LabeledContent("Last feed-in", value: "\(Format.day(seen)) \(Format.time(seen))")
        } else if preferences.lastFeedInCheckedAt != nil {
            LabeledContent("Last feed-in", value: "None in the window")
        }

        if let gap = preferences.lastFeedInGapHours {
            LabeledContent("Silent for", value: gap < 48 ? "\(Int(gap.rounded())) hours" : "\(Int(gap / 24)) days")
        }

        if preferences.watchesOutputDrop {
            if let days = preferences.lastOutputDayCount, days > 0 {
                LabeledContent("History", value: days == 1 ? "1 day" : "\(days) days")
            }
            if let baseline = preferences.lastOutputBaseline, let observed = preferences.lastOutputObserved {
                LabeledContent("Normal peak", value: Format.energy(baseline))
                LabeledContent("Best recent peak", value: Format.energy(observed))
            }
            if let ratio = preferences.lastOutputRatio {
                LabeledContent("Output now") {
                    Text(Format.percent(ratio) + " of normal")
                        .foregroundStyle(ratio < preferences.outputDropRatio ? Palette.consumption : .primary)
                }
            } else if let note = preferences.lastOutputNote {
                // Say why the panel is empty. Silence here is indistinguishable from
                // "everything is fine", which is the one thing it must not look like.
                Label(note, systemImage: "questionmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        if let checked = preferences.lastFeedInCheckedAt {
            LabeledContent("Last checked", value: Format.relative(checked))
        }
    }

    /// iOS will not run this often enough on its own to be trusted, so say so, and say
    /// what to do instead.
    private var scheduleSection: some View {
        Section {
            Label("Shortcuts \u{25B8} Automation \u{25B8} + \u{25B8} Time of Day", systemImage: "1.circle")
            Label("Pick a time, and choose Run Immediately", systemImage: "2.circle")
            Label("Add the action Check feed-in health", systemImage: "3.circle")
        } header: {
            Text("Checking without opening the app")
        } footer: {
            Text(
                """
                The app asks iOS for a background check every six hours, but iOS grants those \
                in proportion to how often an app is opened \u{2014} an alarm you never open \
                the app to read is the first thing it starves. A daily automation in Shortcuts \
                runs the same check on a schedule you choose. E.ON publishes about a day late, \
                so any time of day works.
                """
            )
        }
    }

    private var footerText: String {
        let base = """
        The gap is measured to the newest reading E.ON has published, not to right now — \
        readings arrive about a day late, so measuring against the clock would raise a \
        false alarm every day.
        """
        guard app.preferences.value.feedInAlertEnabled else { return base }
        var text = base + " A threshold under a day will fire most nights, when a solar inverter is idle anyway."
        if app.preferences.value.watchesOutputDrop {
            text += """
             The drop check catches the other failure \u{2014} an inverter that still trickles \
            a few watts, so the silence never begins. It compares the best quarter hour of the \
            last few days against this site's own normal, so the weather has to beat every one \
            of those days to raise it.
            """
        }
        return text
    }

    // MARK: - Actions

    private func apply(enabled: Bool) async {
        resultText = nil

        guard enabled else {
            BackgroundRefresh.cancel()
            for alert in AlertCenter.Alert.allCases { AlertCenter.shared.clear(alert) }
            app.preferences.value.lastFeedInAlertAt = nil
            app.preferences.value.lastOutputDropAlertAt = nil
            return
        }

        isAuthorized = await AlertCenter.shared.requestAuthorization()
        BackgroundRefresh.schedule()
        await checkNow()
    }

    private func checkNow() async {
        guard !app.isDemo else {
            resultText = "Not available on sample data."
            return
        }

        isChecking = true
        defer { isChecking = false }

        let outcome = await FeedInMonitor.shared.check(force: true)
        var text = FeedInMonitor.summary(outcome)
        // The gap check can be perfectly happy while the drop check never ran at all.
        if let note = app.preferences.value.lastOutputNote { text += " " + note }
        resultText = text
    }
}
