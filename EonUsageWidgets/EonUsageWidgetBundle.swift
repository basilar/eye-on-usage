import SwiftUI
import WidgetKit

@main
struct EonUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageWidget()
        UsageControl()
    }
}
