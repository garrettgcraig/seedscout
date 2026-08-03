import CoreLocation
import Foundation

/// One-shot location fixes for the crosshair button.
///
/// Requests `whenInUse` only, and asks for reduced accuracy: the model resolves
/// to a 25 km occurrence grid, so a precise fix would buy nothing and would make
/// the app ask for a permission it does not need.
@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case idle
        case locating
        case denied
        case failed
    }

    private(set) var state: State = .idle
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D, Error>?

    enum Failure: Error { case denied, unavailable }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    @MainActor
    func current() async throws -> CLLocationCoordinate2D {
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            state = .denied
            throw Failure.denied
        }
        state = .locating
        defer { if state == .locating { state = .idle } }

        return try await withCheckedThrowingContinuation { cont in
            // Only one request may be in flight; a second tap replaces the first
            // rather than leaking a continuation.
            continuation?.resume(throwing: Failure.unavailable)
            continuation = cont
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
        }
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        cont.resume(with: result)
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            if continuation != nil { m.requestLocation() }
        case .denied, .restricted:
            state = .denied
            finish(.failure(Failure.denied))
        default:
            break
        }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else {
            finish(.failure(Failure.unavailable))
            return
        }
        state = .idle
        finish(.success(c))
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        state = .failed
        finish(.failure(error))
    }
}
