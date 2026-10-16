import CoreLocation
import Foundation

/// One-shot "where am I", for filling in the weather location.
///
/// Deliberately not a subscription: a delivery point does not move, so the app asks once,
/// stores the coordinate and never looks again. It lives in the app target because
/// authorisation has to be requested by the app, not by an extension.
@MainActor
final class LocationFinder: NSObject, CLLocationManagerDelegate {
    enum Failure: LocalizedError {
        case denied
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .denied:
                return "Location access is off for this app. Turn it on in iOS Settings, or search for a place instead."
            case .unavailable(let detail):
                return detail
            }
        }
    }

    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocationCoordinate2D, any Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func current() async throws -> CLLocationCoordinate2D {
        if waiting != nil { throw Failure.unavailable("A location request is already running.") }

        switch manager.authorizationStatus {
        case .denied, .restricted:
            throw Failure.denied
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            break
        }

        return try await withCheckedThrowingContinuation { continuation in
            waiting = continuation
            manager.requestLocation()
        }
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, any Error>) {
        guard let waiting else { return }
        self.waiting = nil
        waiting.resume(with: result)
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        Task { @MainActor in
            guard let coordinate else {
                self.finish(.failure(Failure.unavailable("No position was returned.")))
                return
            }
            self.finish(.success(coordinate))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // Reduced to a Sendable value out here: neither the manager nor an arbitrary error
        // may cross into the actor.
        let failure: Failure = (error as? CLError)?.code == .denied
            ? .denied
            : .unavailable(error.localizedDescription)
        Task { @MainActor in self.finish(.failure(failure)) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            // Only interesting while a request is outstanding: a denial has to end the wait.
            guard self.waiting != nil else { return }
            switch status {
            case .denied, .restricted: self.finish(.failure(Failure.denied))
            case .authorizedWhenInUse, .authorizedAlways: self.manager.requestLocation()
            default: break
            }
        }
    }
}
