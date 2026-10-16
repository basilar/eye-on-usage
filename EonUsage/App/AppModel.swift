import Foundation
import SwiftUI
import WidgetKit

/// Session and delivery-point state for the whole app.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case launching
        case signedOut
        case choosingDeliveryPoint
        case ready
    }

    private(set) var phase: Phase = .launching
    private(set) var partners: [PartnerDTO] = []
    private(set) var deliveryPoints: [DeliveryPoint] = []
    private(set) var channels: [MeasurementChannel] = []
    private(set) var interval: IntervalDTO?
    private(set) var selectedPoint: DeliveryPoint?

    /// Set when there are no credentials and the user asked to look around anyway.
    private(set) var isDemo = false

    var statusMessage: String?
    var isWorking = false

    let preferences = PreferencesStore.shared
    private let repository = UsageRepository()
    private let weather = WeatherClient()

    // MARK: - Launch

    func bootstrap() async {
        guard phase == .launching else { return }

        // Lets a simulator run or a UI test land straight on the charts.
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            enterDemoMode()
            return
        }

        guard await repository.hasStoredCredentials else {
            phase = .signedOut
            return
        }

        guard let partnerID = preferences.value.partnerID else {
            phase = .signedOut
            return
        }

        do {
            let partner = try await repository.restoreSession(partnerID: partnerID)
            applyPartner(partner)
            try await loadDeliveryPoints()
            try await restoreDeliveryPoint()
        } catch {
            statusMessage = (error as? PortalError)?.errorDescription ?? error.localizedDescription
            phase = .signedOut
        }
    }

    // MARK: - Sign in

    func signIn(email: String, password: String) async {
        isWorking = true
        statusMessage = nil
        defer { isWorking = false }

        do {
            let account = try await repository.signIn(email: email, password: password)
            partners = account.partners

            // Electricity first; a household account usually has exactly one partner, but a
            // business one can carry several and only some of them meter anything.
            let ordered = account.partners.filter { $0.sparte == Sparte.electricity }
                + account.partners.filter { $0.sparte != Sparte.electricity }

            for partner in ordered {
                try await repository.selectPartner(partner)
                applyPartner(partner)
                try await loadDeliveryPoints()
                if !deliveryPoints.isEmpty { break }
            }

            try await restoreDeliveryPoint()
        } catch {
            statusMessage = (error as? PortalError)?.errorDescription ?? error.localizedDescription
            phase = .signedOut
        }
    }

    func enterDemoMode() {
        isDemo = true
        deliveryPoints = DemoData.deliveryPoints
        channels = DemoData.channels
        selectedPoint = DemoData.deliveryPoints[0]
        interval = nil
        phase = .ready
    }

    func signOut() {
        Task { await repository.signOut() }
        BackgroundRefresh.cancel()
        for alert in AlertCenter.Alert.allCases { AlertCenter.shared.clear(alert) }
        preferences.reset()
        SnapshotStore.shared.clear()
        WidgetCenter.shared.reloadAllTimelines()
        partners = []
        deliveryPoints = []
        channels = []
        selectedPoint = nil
        interval = nil
        isDemo = false
        phase = .signedOut
    }

    // MARK: - Delivery points

    func loadDeliveryPoints() async throws {
        let points = try await repository.deliveryPoints()
        let electricity = points.filter(\.isElectricity)
        deliveryPoints = electricity.isEmpty ? points : electricity
    }

    func select(_ point: DeliveryPoint) async {
        isWorking = true
        statusMessage = nil
        defer { isWorking = false }

        do {
            let catalogue = try await repository.catalogue(
                sparte: point.sparte,
                overrides: preferences.value.channelOverrides
            )
            channels = catalogue.channels
            interval = catalogue.interval
            selectedPoint = point

            preferences.value.podID = point.id
            preferences.value.sparte = point.sparte
            preferences.value.intervalID = catalogue.interval.intervalId
            phase = .ready
        } catch {
            statusMessage = (error as? PortalError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Reading

    /// Loads a range of readings, or generates them when running in demo mode.
    func readings(from: Date, to: Date) async throws -> EnergySeries {
        if isDemo { return DemoData.series(from: from, to: to) }

        guard let point = selectedPoint, let interval else {
            throw PortalError.notConfigured("Choose a delivery point first.")
        }
        return try await repository.readings(
            podID: point.id,
            channels: channels,
            interval: interval,
            from: from,
            to: to
        )
    }

    /// Cloud cover and daylight over the delivery point, for the chart overlays.
    func sky(at location: WeatherLocation, from: Date, to: Date) async throws -> Sky {
        if isDemo { return DemoData.sky(from: from, to: to) }
        return try await weather.sky(at: location, from: from, to: to)
    }

    /// Looks a place up by name for the weather setting.
    func places(matching name: String) async throws -> [WeatherLocation] {
        try await weather.places(matching: name)
    }

    /// Publishes a day's totals to the widgets.
    func publishSnapshot(day: Date, series: EnergySeries) {
        guard let podID = selectedPoint?.id else { return }
        SnapshotStore.shared.save(UsageSnapshot(podID: podID, day: day, series: series))
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Helpers

    private func applyPartner(_ partner: PartnerDTO) {
        preferences.value.partnerID = partner.partner
        preferences.value.partnerAuthID = partner.authid
    }

    private func restoreDeliveryPoint() async throws {
        if let savedID = preferences.value.podID,
           let match = deliveryPoints.first(where: { $0.id == savedID }) {
            await select(match)
        } else if deliveryPoints.count == 1 {
            await select(deliveryPoints[0])
        } else {
            phase = .choosingDeliveryPoint
        }
    }
}
