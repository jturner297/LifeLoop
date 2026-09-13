//
//  MapScreen.swift
//  LifeLoop
//
//  Created by Jes206 on 9/3/26.
//

import SwiftUI
import MapKit


// Declare struct MapScreen that conforms to View
struct MapScreen: View {
    
    // Requirements for map
    let targetLat: Double
    let targetLon: Double
    
    // Building the UI
    var body: some View {
        // Convert doubles into Apple coordinate object
        let coordinates = CLLocationCoordinate2D(latitude: targetLat, longitude: targetLon)
        // Builds the map
        Map(initialPosition: .region(MKCoordinateRegion(
            center: coordinates,
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        ))){
            Marker("Current Position", coordinate: coordinates)
            
        }
    }
}

// Test position that should point to KSU 
#Preview {
    MapScreen(targetLat: 34.038, targetLon: -84.582)
}
