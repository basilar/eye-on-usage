import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                deliveryPointSection
                WeatherSection()
                FeedInAlertSection()
                widgetSection

                Section {
                    Button("Sign out", role: .destructive) { confirmingSignOut = true }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Sign out of the E.ON portal?",
                isPresented: $confirmingSignOut,
                titleVisibility: .visible
            ) {
                Button("Sign out", role: .destructive) {
                    app.signOut()
                    dismiss()
                }
            } message: {
                Text("Your saved password and cached readings are removed from this device.")
            }
        }
    }

    @ViewBuilder
    private var deliveryPointSection: some View {
        Section {
            ForEach(app.deliveryPoints) { point in
                Button {
                    Task { await app.select(point) }
                } label: {
                    PodRow(point: point, isSelected: app.selectedPoint?.id == point.id)
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Delivery point")
        }
    }

    private var widgetSection: some View {
        Section {
            LabeledContent("Shared with widgets", value: SharedContainer.isSharing ? "On" : "Off")
            if let snapshot = SnapshotStore.shared.load() {
                LabeledContent("Last published", value: Format.relative(snapshot.capturedAt))
            }
        } header: {
            Text("Widgets")
        } footer: {
            Text("Home Screen and Lock Screen widgets show the most recent day you opened in the app.")
        }
    }

}
