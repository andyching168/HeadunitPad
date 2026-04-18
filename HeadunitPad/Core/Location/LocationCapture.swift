import Foundation
import CoreLocation

final class LocationCapture: NSObject {
    var onLocation: ((CLLocation) -> Void)?

    private let manager = CLLocationManager()
    private var wantsUpdates = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 3
        manager.pausesLocationUpdatesAutomatically = true
    }

    func requestPermissionIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func start() {
        wantsUpdates = true
        let status = manager.authorizationStatus

        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        default:
            print("LocationCapture: Location permission not granted")
        }
    }

    func stop() {
        wantsUpdates = false
        manager.stopUpdatingLocation()
    }
}

extension LocationCapture: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if wantsUpdates {
            start()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        guard latest.horizontalAccuracy >= 0 else { return }
        onLocation?(latest)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("LocationCapture: Failed to update location: \(error)")
    }
}
