import SwiftUI
import MapKit

struct MapScreen: View {
    let targetLat: Double?
    let targetLon: Double?
    let statusText: String
    var familyDevices: [FamilyDeviceSnapshot] = []

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        ZStack(alignment: .top) {
            if coordinate != nil || !visibleFamilyDevices.isEmpty {
                Map(position: $position) {
                    if let coordinate {
                        Marker("You", systemImage: "location.fill", coordinate: coordinate)
                            .tint(.blue)
                        UserAnnotation()
                    }

                    ForEach(visibleFamilyDevices) { device in
                        Marker(
                            device.displayName,
                            systemImage: device.isOnline ? "heart.fill" : "heart.slash",
                            coordinate: CLLocationCoordinate2D(
                                latitude: device.latitude,
                                longitude: device.longitude
                            )
                        )
                        .tint(device.isOnline ? .red : .gray)
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                    MapScaleView()
                }
                .onAppear {
                    updatePositionToBestRegion()
                }
                .onChange(of: targetLat) { _, _ in
                    updatePositionToBestRegion()
                }
                .onChange(of: targetLon) { _, _ in
                    updatePositionToBestRegion()
                }
                .onChange(of: familyDevices) { _, _ in
                    updatePositionToBestRegion()
                }
            } else {
                ContentUnavailableView(
                    "No Shared Locations",
                    systemImage: "location.slash",
                    description: Text(statusText)
                )
            }

            mapStatusCard
        }
    }

    private var mapStatusCard: some View {
        VStack(spacing: 4) {
            Text(statusText)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)

            if !visibleFamilyDevices.isEmpty {
                Text("\(visibleFamilyDevices.count) family location\(visibleFamilyDevices.count == 1 ? "" : "s") shared")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.top, 12)
    }

    private var coordinate: CLLocationCoordinate2D? {
        guard let targetLat, let targetLon else { return nil }
        return CLLocationCoordinate2D(latitude: targetLat, longitude: targetLon)
    }

    private var visibleFamilyDevices: [FamilyDeviceSnapshot] {
        familyDevices.filter { device in
            device.isLocationShared && (device.latitude != 0 || device.longitude != 0)
        }
    }

    private func updatePositionToBestRegion() {
        let coordinates = mapCoordinates
        guard !coordinates.isEmpty else { return }

        if coordinates.count == 1, let coordinate = coordinates.first {
            position = .region(MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
            return
        }

        let minLatitude = coordinates.map(\.latitude).min() ?? 0
        let maxLatitude = coordinates.map(\.latitude).max() ?? 0
        let minLongitude = coordinates.map(\.longitude).min() ?? 0
        let maxLongitude = coordinates.map(\.longitude).max() ?? 0
        let center = CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.01, (maxLatitude - minLatitude) * 1.6),
            longitudeDelta: max(0.01, (maxLongitude - minLongitude) * 1.6)
        )
        position = .region(MKCoordinateRegion(center: center, span: span))
    }

    private var mapCoordinates: [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        if let coordinate {
            coordinates.append(coordinate)
        }
        coordinates.append(contentsOf: visibleFamilyDevices.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        })
        return coordinates
    }
}

#Preview {
    MapScreen(
        targetLat: 34.038,
        targetLon: -84.582,
        statusText: "Location updated",
        familyDevices: [
            FamilyDeviceSnapshot(
                id: "preview-1",
                displayName: "Mom's LifeLoop",
                ownerName: "Mom",
                bpm: 72,
                state: 1,
                latitude: 34.04,
                longitude: -84.58,
                isLocationShared: true,
                isOnline: true,
                lastUpdated: Date()
            )
        ]
    )
}
