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
    
    // Published receives data from the class declared above, and anytime the latitude or longitude numbers change, the application with update with new coordinate data
    
    @Published var latitude = 0.0
    @Published var longitude = 0.0
    
    // Init is our constructor (runs soon as class is created)
    // Requires override since NSObject contains a default empty init(), we are replacing the parent default version
    // super.init is called to allow parent class to setup first
    
    override init () {
        super.init()
        
        // Manager finds location and gives it to LocationManager class
        
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }
    
    // Triggers iOS pop that asks user for permission to gather location data, and tells the GPS chip to start pinging satellites
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        
        // GPS could send an empty list so guard let checks the list to see if locations.last has data and if it does store it in latestLocation. If empty abort function to avoid app crashes.
        
        guard let latestLocation = locations.last else { return }
        
        // Extract numbers out of Apple object and save it into the published variables. These new numbers will be shown on the UI.
        
        latitude = latestLocation.coordinate.latitude
        longitude = latestLocation.coordinate.longitude
    }
    
    
    
    
    
    
}
