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
    // GLGeocoder is Apple's built in geocoder object
    
    private let manager = CLLocationManager()
    private let geocoder = CLGeocoder()
    
    // Published receives data from the class declared above, and anytime the latitude or longitude numbers change, the application with update with new coordinate data
    
    @Published var latitude = 0.0
    @Published var longitude = 0.0
    @Published var currentAddress = "Locating..."

    private var lastGeocodeTime: Date?

    var statusText: String {
        currentAddress
    }
    
    // Init is our constructor (runs soon as class is created)
    // Requires override since NSObject contains a default empty init(), we are replacing the parent default version
    // super.init is called to allow parent class to setup first
    
    override init () {
        super.init()
        
        // Manager finds location and gives it to LocationManager class
        
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 20
        manager.startUpdatingLocation()
    }
    
    // Triggers iOS pop that asks user for permission to gather location data, and tells the GPS chip to start pinging satellites
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        
        // GPS could send an empty list so guard let checks the list to see if locations.last has data and if it does store it in latestLocation. If empty abort function to avoid app crashes.
        
        guard let latestLocation = locations.last else { return }
        
        // Extract numbers out of Apple object and save it into the published variables. These new numbers will be shown on the UI.
        
        latitude = latestLocation.coordinate.latitude
        longitude = latestLocation.coordinate.longitude

        if let lastGeocodeTime, Date().timeIntervalSince(lastGeocodeTime) < 60 {
            return
        }
        lastGeocodeTime = Date()
        
        geocoder.reverseGeocodeLocation(latestLocation) {[weak self] placemarks, error in
                // Block runs asynchronously when Apple's servers respond
            
            // Unwraps self and if manager is destroyed then abort
            guard let self = self else {return}
                //Check for server errors or lack of internet
                if error != nil {
                    self.currentAddress = "Address unavailable"
                    return
                }
                // Grab first result from server
                guard let placemark = placemarks?.first else { return }
                
                // Use placemark to build standard us address
                let streetNum = placemark.subThoroughfare ?? ""
                let streetName = placemark.thoroughfare ?? ""
                let city = placemark.locality ?? ""
                let state = placemark.administrativeArea ?? ""
                let zip = placemark.postalCode ?? ""
                
                self.currentAddress = "\(streetNum) \(streetName) \n \(city), \(state) \(zip)"
            }
        
    }
    
    
    
    
}
