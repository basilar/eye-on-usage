import SwiftUI

@main
struct EonUsageApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        BackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.bootstrap() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Re-arm on the way out; iOS drops pending requests when the app is killed.
            if phase == .background, PreferencesStore.shared.value.feedInAlertEnabled {
                BackgroundRefresh.schedule()
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .launching:
            LaunchView()
        case .signedOut:
            LoginView()
        case .choosingDeliveryPoint:
            PodPickerView()
        case .ready:
            DashboardView()
        }
    }
}

private struct LaunchView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Palette.consumption)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }
}
