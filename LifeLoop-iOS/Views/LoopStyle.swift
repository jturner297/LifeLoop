import SwiftUI
import MapKit
import UIKit

enum AppAppearance: String, CaseIterable, Identifiable {
    case light = "light"
    case dark = "dark"
    case system = "system"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .system: return "System"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }
}

enum LoopStyle {
    static let green = Color(red: 0.22, green: 1.0, blue: 0.08)
    static let darkInk = Color(red: 0.10, green: 0.16, blue: 0.14)

    static let mint = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.14, green: 0.26, blue: 0.17, alpha: 1.0)
            : UIColor(red: 0.86, green: 0.98, blue: 0.84, alpha: 1.0)
    })

    static let background = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.07, green: 0.10, blue: 0.09, alpha: 1.0)
            : UIColor(red: 0.95, green: 0.97, blue: 0.96, alpha: 1.0)
    })

    static let card = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.12, green: 0.17, blue: 0.15, alpha: 1.0)
            : UIColor.white
    })

    static let ink = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.93, green: 0.97, blue: 0.95, alpha: 1.0)
            : UIColor(red: 0.10, green: 0.16, blue: 0.14, alpha: 1.0)
    })
}

extension View {
    func loopCard() -> some View {
        padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(LoopStyle.card, in: RoundedRectangle(cornerRadius: 22))
    }
    func loopPage() -> some View {
        scrollContentBackground(.hidden).background(LoopStyle.background)
            .foregroundStyle(LoopStyle.ink).tint(LoopStyle.green)
    }
}

struct LandscapeArt: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            ZStack {
                LinearGradient(colors: [Color(red: 0.73, green: 0.88, blue: 0.83), Color(red: 0.91, green: 0.93, blue: 0.83)], startPoint: .top, endPoint: .bottom)
                Circle().fill(Color.orange.opacity(0.85))
                    .frame(width: w * 0.17, height: w * 0.17)
                    .position(x: w * 0.77, y: h * 0.25)
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.63))
                    p.addLines([CGPoint(x: w * 0.2, y: h * 0.40), CGPoint(x: w * 0.38, y: h * 0.56), CGPoint(x: w * 0.58, y: h * 0.32), CGPoint(x: w * 0.8, y: h * 0.58), CGPoint(x: w, y: h * 0.46), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)])
                }.fill(Color(red: 0.43, green: 0.68, blue: 0.60))
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.84))
                    p.addLines([CGPoint(x: w * 0.2, y: h * 0.64), CGPoint(x: w * 0.38, y: h * 0.78), CGPoint(x: w * 0.58, y: h * 0.58), CGPoint(x: w * 0.8, y: h * 0.82), CGPoint(x: w, y: h * 0.70), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)])
                }.fill(LoopStyle.green)
            }
        }.accessibilityHidden(true)
    }
}

struct ProfileAvatar: View {
    let name: String
    var size: CGFloat = 54
    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
        Group {
            if initials.isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45, weight: .bold))
            } else {
                Text(initials)
                    .font(.title3.bold())
            }
        }
        .foregroundStyle(LoopStyle.darkInk)
        .frame(width: size, height: size)
        .background(LoopStyle.green, in: Circle())
        .accessibilityHidden(true)
    }
}

struct MemberMap: View {
    let name: String
    let latitude: Double
    let longitude: Double
    let shared: Bool
    var body: some View {
        if shared && CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)) && (latitude != 0 || longitude != 0) {
            Map(initialPosition: .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude), span: MKCoordinateSpan(latitudeDelta: 0.015, longitudeDelta: 0.015)))) {
                Marker(name, coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            }
            .frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 24))
        } else {
            ContentUnavailableView(shared ? "Waiting for location" : "Location is private", systemImage: "map")
                .frame(height: 190).background(LoopStyle.mint, in: RoundedRectangle(cornerRadius: 24))
        }
    }
}
