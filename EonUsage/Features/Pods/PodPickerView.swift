import SwiftUI

/// Shown when the account covers more than one delivery point, or none at all.
struct PodPickerView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.deliveryPoints.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .navigationTitle("Choose a POD")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if model.isWorking { ProgressView() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Sign out", role: .destructive) { model.signOut() }
                }
            }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(model.deliveryPoints) { point in
                    Button {
                        Task { await model.select(point) }
                    } label: {
                        PodRow(point: point, isSelected: model.selectedPoint?.id == point.id)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Delivery points")
            } footer: {
                Text("A POD identifies the metering point where consumption is measured. You can switch later in Settings.")
            }

            if let message = model.statusMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No delivery points", systemImage: "bolt.slash")
        } description: {
            Text(model.statusMessage ?? "This E.ON account has no metering point the portal will report on. Sign in with a different account.")
        } actions: {
            Button("Use a different account") { model.signOut() }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct PodRow: View {
    let point: DeliveryPoint
    var isSelected = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: point.isElectricity ? "bolt.fill" : "flame.fill")
                .font(.footnote)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(point.isElectricity ? Palette.consumption : .orange, in: .rect(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(point.subtitle ?? Sparte.title(point.sparte))
                    .font(.body)
                Text(point.formattedID)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
    }
}
