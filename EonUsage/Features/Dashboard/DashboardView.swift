import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var app
    @State private var dashboard = DashboardModel()
    @State private var showingSettings = false
    @State private var showingTable = false

    var body: some View {
        @Bindable var dashboard = dashboard

        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Picker("Window", selection: $dashboard.span) {
                        ForEach(TimeSpan.allCases) { span in
                            Text(span.title).tag(span)
                        }
                    }
                    .pickerStyle(.segmented)

                    WindowStepper(dashboard: dashboard)
                        .padding(.top, 2)

                    chartCard

                    SummaryTiles(series: dashboard.chartSeries, span: dashboard.span)

                    footer
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(app.isDemo ? "Sample data" : "Electricity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Readings", systemImage: "tablecells") { showingTable = true }
                        .disabled(dashboard.chartSeries.samples.isEmpty)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Only in day view, and only once there is somewhere to fetch for —
                    // a toggle that cannot do anything is worse than no toggle.
                    if dashboard.showsCloud, app.preferences.value.weatherLocation != nil {
                        Button {
                            app.preferences.value.showsCloudCover.toggle()
                        } label: {
                            Label(
                                "Cloud cover",
                                systemImage: app.preferences.value.showsCloudCover ? "cloud.fill" : "cloud"
                            )
                        }
                        .accessibilityLabel(
                            app.preferences.value.showsCloudCover ? "Hide cloud cover" : "Show cloud cover"
                        )
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if dashboard.showsCloud, app.preferences.value.weatherLocation != nil {
                        Button {
                            app.preferences.value.showsDaylight.toggle()
                        } label: {
                            Label(
                                "Daylight",
                                systemImage: app.preferences.value.showsDaylight ? "sun.max.fill" : "sun.max"
                            )
                        }
                        .accessibilityLabel(
                            app.preferences.value.showsDaylight ? "Hide daylight shading" : "Shade hours after dark"
                        )
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Settings", systemImage: "gearshape") { showingSettings = true }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingTable) {
                ReadingsTableView(series: dashboard.chartSeries, span: dashboard.span)
            }
            .refreshable { await dashboard.load(using: app) }
            .task(id: reloadKey) { await dashboard.load(using: app) }
            // Flipping the overlay refetches the weather only; the readings are unchanged.
            .task(id: skyKey) { await dashboard.refreshSky(using: app) }
        }
    }

    /// Any change to these three has to trigger a fetch.
    private var reloadKey: String {
        "\(dashboard.span.rawValue)-\(dashboard.anchor.timeIntervalSince1970)-\(app.selectedPoint?.id ?? "")"
    }

    /// The weather alone depends on these.
    private var skyKey: String {
        let preferences = app.preferences.value
        return [
            "\(preferences.showsCloudCover)",
            "\(preferences.showsDaylight)",
            preferences.weatherLocation?.summary ?? "",
            reloadKey,
        ].joined(separator: "-")
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if dashboard.isLoading && dashboard.series.samples.isEmpty {
                placeholder { ProgressView() }
            } else if let message = dashboard.errorMessage {
                placeholder {
                    ContentUnavailableView {
                        Label("No readings", systemImage: "bolt.slash")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") {
                            Task { await dashboard.load(using: app) }
                        }
                    }
                }
            } else if dashboard.chartSeries.isEmpty {
                placeholder {
                    ContentUnavailableView(
                        "Nothing recorded",
                        systemImage: "bolt.slash",
                        description: Text("The portal has no readings for \(dashboard.span.label(for: dashboard.anchor)).")
                    )
                }
            } else {
                UsageChart(
                    series: dashboard.chartSeries,
                    span: dashboard.span,
                    window: dashboard.span.chartDomain(around: dashboard.anchor),
                    sky: dashboard.chartSky,
                    selection: $dashboard.selection
                )
                .frame(height: 260)

                Text("\(dashboard.chartSeries.resolution.title) buckets · \(dashboard.chartSeries.unit) per bucket")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            if dashboard.isLoading && !dashboard.series.samples.isEmpty {
                ProgressView().padding(12)
            }
        }
        // On the whole card, not just the plot: a window with no readings is exactly the
        // one you most want to swipe straight off.
        .contentShape(.rect)
        .simultaneousGesture(pageGesture)
    }

    /// Flick left for the next window, right for the previous — see `pageStep`.
    private var pageGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { drag in
                guard let direction = DashboardModel.pageStep(
                    translation: drag.translation,
                    predictedEnd: drag.predictedEndTranslation
                ) else { return }

                guard direction < 0 || !dashboard.isAtNewestWindow else { return }
                dashboard.step(direction)
            }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 6) {
            if let point = app.selectedPoint {
                Text(point.formattedID)
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("Readings are published by E.ON with about a day's delay.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func placeholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .frame(height: 260)
    }
}

/// Previous / next window, with the current window named in between. The name is also
/// the way in to a calendar: stepping is fine for a neighbour, hopeless for last March.
struct WindowStepper: View {
    @Bindable var dashboard: DashboardModel
    @State private var showingCalendar = false

    var body: some View {
        HStack {
            Button {
                dashboard.step(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 40, height: 32)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Previous \(dashboard.span.title.lowercased())")

            Spacer(minLength: 8)

            Button {
                showingCalendar = true
            } label: {
                HStack(spacing: 5) {
                    Text(dashboard.span.label(for: dashboard.anchor))
                        .font(.subheadline.weight(.medium))
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Image(systemName: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose a date. Showing \(dashboard.span.label(for: dashboard.anchor))")
            .sheet(isPresented: $showingCalendar) {
                DayPicker(selection: $dashboard.pickedDay, latest: DashboardModel.today)
                    .presentationDetents([.height(540)])
                    .presentationDragIndicator(.visible)
            }

            Spacer(minLength: 8)

            Button {
                dashboard.step(1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 40, height: 32)
            }
            .buttonStyle(.bordered)
            .disabled(dashboard.isAtNewestWindow)
            .accessibilityLabel("Next \(dashboard.span.title.lowercased())")
        }
    }
}
