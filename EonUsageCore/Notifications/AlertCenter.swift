import Foundation
import UserNotifications

/// The app's one notification surface.
///
/// These are local notifications scheduled on the device, not remote pushes — there is no
/// server in this design, and none is needed: the readings behind the alert are already
/// a day old by the time E.ON publishes them.
struct AlertCenter: Sendable {
    static let shared = AlertCenter()

    enum Alert: String, CaseIterable {
        /// Nothing at all has reached the grid for the configured stretch.
        case feedInStopped = "feed-in-stopped"
        case feedInResumed = "feed-in-resumed"
        /// Export is still happening but has collapsed against this site's own normal.
        case outputDropped = "feed-in-dropped"
        case outputRecovered = "feed-in-recovered"

        /// Faults interrupt; the all-clears do not.
        var isFault: Bool { self == .feedInStopped || self == .outputDropped }
    }

    private var center: UNUserNotificationCenter { .current() }

    /// Asks once; returns whether notifications may be posted now.
    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    func post(_ alert: Alert, title: String, body: String) async {
        guard await isAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = alert.isFault ? .timeSensitive : .active

        // A nil trigger delivers immediately; the identifier replaces any earlier copy so
        // the alert never stacks up.
        let request = UNNotificationRequest(identifier: alert.rawValue, content: content, trigger: nil)
        try? await center.add(request)
    }

    func clear(_ alert: Alert) {
        center.removeDeliveredNotifications(withIdentifiers: [alert.rawValue])
        center.removePendingNotificationRequests(withIdentifiers: [alert.rawValue])
    }
}
