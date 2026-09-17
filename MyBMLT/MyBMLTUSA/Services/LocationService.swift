import Foundation
import CoreLocation
import Observation
import UIKit

/// `CLLocationManager` wrapper.
///
/// Location is **opt-in and never blocks a screen**. The Meetings tab is fully
/// usable without it (Area search by ZIP/city), and Near Me offers an explicit
/// "browse by Area instead" path when permission is refused.
///
/// Uses `requestLocation()` (one-shot) rather than `startUpdatingLocation()`,
/// because every consumer here wants a single fix, not a continuous stream.
@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {

    private(set) var currentLocation: CLLocation?
    private(set) var authStatus: CLAuthorizationStatus = .notDetermined
    private(set) var lastError: String?

    /// True once we have asked and the user said no. Distinguished from
    /// `.notDetermined`, where we have not asked yet — the UI shows different
    /// copy for each.
    var isDenied: Bool { authStatus == .denied || authStatus == .restricted }

    var hasFix: Bool { currentLocation != nil }

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authStatus = manager.authorizationStatus
    }

    /// Requests permission if undetermined, otherwise fetches a fix.
    /// Safe to call repeatedly.
    func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            lastError = nil
            manager.requestLocation()
        default:
            break
        }
    }

    /// Explicit user action from the permission prompt UI. Same as
    /// `requestLocation` but signals deliberate intent, so we do not treat a
    /// passive tab appearance as consent.
    func requestAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            requestLocation()
        }
    }

    func openSettings() {
        #if os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        Task { @MainActor in
            self.currentLocation = latest
            self.lastError = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor in
            self.lastError = error.localizedDescription
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authStatus = status
            switch status {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            default:
                break
            }
        }
    }
}
