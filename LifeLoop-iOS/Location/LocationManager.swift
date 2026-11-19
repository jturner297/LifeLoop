//
//  LocationManager.swift
//  LifeLoop
//
//  Created by Jes206 on 9/2/26.
//

// Load Apple's library of GPS and location tools
import CoreLocation

// NSObject is base class for Apple and is used to talk to older frameworks such as CoreLocation
// ObservableObject tells swift that there is data that will change and allows UI screens to use the data. Think about this as a radio station broadcasting.
// Tells swift that class has the fucntions required to obtain GPS coordinates

class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    // CLLocationManager is the system object that communicates with the actual antenna; made private so that no other file can interact with it and made into constant so it cannot be overwritten
    private let manager = CLLocationManager()

    private(set) var latitude = 0.0
    private(set) var longitude = 0.0

    // Init is our constructor (runs soon as class is created)
    // Requires override since NSObject contains a default empty init(), we are replacing the parent default version
    // super.init is called to allow parent class to setup first

    override init() {
        super.init()

        // Manager finds location and gives it to LocationManager class
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 20
        handleAuthorization(manager.authorizationStatus)
    }

    private func handleAuthorization(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            manager.stopUpdatingLocation()
        @unknown default:
            manager.stopUpdatingLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorization(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // GPS could send an empty list so guard let checks the list to see if locations.last has data and if it does store it in latestLocation. If empty abort function to avoid app crashes.
        guard let latestLocation = locations.last else { return }
        let lat = latestLocation.coordinate.latitude
        let lon = latestLocation.coordinate.longitude

        if Thread.isMainThread {
            latitude = lat
            longitude = lon
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.latitude = lat
                self?.longitude = lon
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location update error: \(error.localizedDescription)")
    }
}
