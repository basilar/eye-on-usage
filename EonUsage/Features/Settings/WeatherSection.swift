import SwiftUI

/// Settings for the cloud-cover overlay: whether to draw it, and where to fetch it for.
struct WeatherSection: View {
    @Environment(AppModel.self) private var app

    @State private var query = ""
    @State private var results: [WeatherLocation] = []
    @State private var isSearching = false
    @State private var isLocating = false
    @State private var message: String?
    @State private var finder = LocationFinder()

    var body: some View {
        @Bindable var preferences = app.preferences

        Section {
            if let location = preferences.value.weatherLocation {
                LabeledContent("Location") {
                    Text(location.summary)
                        .multilineTextAlignment(.trailing)
                }
                Button("Clear location", role: .destructive) {
                    app.preferences.value.weatherLocation = nil
                    message = nil
                }
            } else {
                Text("Set a location to fetch cloud cover for.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await locate() }
            } label: {
                HStack {
                    Label("Use my location", systemImage: "location")
                    if isLocating {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(isLocating)

            HStack {
                TextField("Search for a place", text: $query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await search() } }
                if isSearching { ProgressView() }
            }

            ForEach(results, id: \.self) { place in
                Button {
                    app.preferences.value.weatherLocation = place
                    results = []
                    query = ""
                    message = nil
                } label: {
                    Label(place.summary, systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                }
            }

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Cloud cover")
        } footer: {
            Text(footerText)
        }
    }

    private var footerText: String {
        guard app.preferences.value.weatherLocation != nil else {
            return """
            Set a location and the day view gains a cloud button, for reading a thin day \
            against the weather that caused it. History comes from Open-Meteo, which needs \
            no account.
            """
        }
        return """
        Switch the overlay on with the cloud button in the day view. Hourly cover is drawn \
        as a grey line over the bars, on a 0–100% scale sharing their gridlines. Only this \
        coordinate is ever sent, and only when a chart is drawn — never the readings, and \
        never anything identifying.
        """
    }

    // MARK: - Actions

    private func locate() async {
        isLocating = true
        message = nil
        defer { isLocating = false }

        do {
            let coordinate = try await finder.current()
            app.preferences.value.weatherLocation = WeatherLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                name: nil
            )
        } catch {
            message = error.localizedDescription
        }
    }

    private func search() async {
        let name = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count >= 2 else { return }

        isSearching = true
        message = nil
        defer { isSearching = false }

        do {
            results = try await app.places(matching: name)
            if results.isEmpty { message = "Nothing found for \"\(name)\"." }
        } catch {
            results = []
            message = (error as? PortalError)?.errorDescription ?? error.localizedDescription
        }
    }
}
