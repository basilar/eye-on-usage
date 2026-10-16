import AppIntents
import SwiftUI
import WidgetKit

/// A Control Center / Lock Screen control that shows the latest balance and opens the app.
struct UsageControl: ControlWidget {
    static let kind = "hu.randart.EonUsage.control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { value in
            ControlWidgetButton(action: OpenDashboardIntent()) {
                Label(value.headline, systemImage: value.symbol)
            }
        }
        .displayName("Electricity balance")
        .description("Shows the latest day's grid balance and opens the charts.")
    }

    struct Value {
        let headline: String
        let symbol: String

        static func describing(_ snapshot: UsageSnapshot?) -> Value {
            guard let snapshot else {
                return Value(headline: "No readings", symbol: "bolt.slash")
            }
            return snapshot.net < 0
                ? Value(headline: "↑ \(Format.energy(-snapshot.net))", symbol: "arrow.up.to.line")
                : Value(headline: "↓ \(Format.energy(snapshot.net))", symbol: "arrow.down.to.line")
        }
    }

    struct Provider: ControlValueProvider {
        var previewValue: Value { Value.describing(DemoData.snapshot()) }

        func currentValue() async throws -> Value {
            Value.describing(SnapshotStore.shared.load())
        }
    }
}
