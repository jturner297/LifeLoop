import SwiftUI
import MapKit

struct MapScreen: View {
    let targetLat: Double?
    let targetLon: Double?
    let statusText: String

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        ZStack(alignment: .top) {
            if let coordinate {
                Map(position: $position) {
                    Marker("Current Position", coordinate: coordinate)
                    UserAnnotation()
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                    MapScaleView()
                }
                .onAppear {
                    updatePosition(to: coordinate)
                }
                .onChange(of: targetLat) { _, _ in
                    if let updatedCoordinate = self.coordinate {
                        updatePosition(to: updatedCoordinate)
                    }
                }
                .onChange(of: targetLon) { _, _ in
                    if let updatedCoordinate = self.coordinate {
                        updatePosition(to: updatedCoordinate)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Current Location Unavailable",
                    systemImage: "location.slash",
                    description: Text(statusText)
                )
            }

            if coordinate != nil {
                Text(statusText)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(.top, 12)
            }
        }
    }

    private var coordinate: CLLocationCoordinate2D? {
        guard let targetLat, let targetLon else { return nil }
        return CLLocationCoordinate2D(latitude: targetLat, longitude: targetLon)
    }

    private func updatePosition(to coordinate: CLLocationCoordinate2D) {
        position = .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))
    }
}

#Preview {
    MapScreen(targetLat: 34.038, targetLon: -84.582, statusText: "Location updated")
}
