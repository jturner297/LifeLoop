//
//  HexagonGrid.swift
//  LifeLoop
//
//  Created by Jes206 on 9/16/26.
//

import SwiftUI

struct Hexagon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.width / 2, y: rect.height / 2)
        let size = min(rect.width, rect.height) / 2

        // Subtracting 30 degrees shifts the geometry to Pointy-Topped hexagons
        let corners = (0..<6).map { i -> CGPoint in
            let angle_rad = CGFloat.pi / 180 * CGFloat(60 * i - 30)
            return CGPoint(
                x: center.x + size * cos(angle_rad),
                y: center.y + size * sin(angle_rad)
            )
        }

        path.move(to: corners[0])
        for corner in corners[1...] {
            path.addLine(to: corner)
        }
        path.closeSubpath()
        return path
    }
}

struct HexagonGrid: View {
    var body: some View {
        GeometryReader { geometry in
            let hexSize: CGFloat = 35 // Adjusted for the exact scale in the target image
            
            // Mathematical constants for perfectly interlocking Pointy-Topped hexagons
            let width = sqrt(3) * hexSize
            let height = 2 * hexSize
            let horizSpacing = width
            let vertSpacing = hexSize * 1.5
            
            let cols = Int(geometry.size.width / horizSpacing) + 2
            let rows = Int(geometry.size.height / vertSpacing) + 2

            ZStack {
                ForEach(0..<rows, id: \.self) { row in
                    ForEach(0..<cols, id: \.self) { col in
                        Hexagon()
                            .stroke(Color.black.opacity(0.85), lineWidth: 5)
                            .frame(width: width, height: height)
                            .position(
                                // Stagger every other row horizontally by half a width
                                x: CGFloat(col) * horizSpacing + (row.isMultiple(of: 2) ? 0 : horizSpacing / 2),
                                y: CGFloat(row) * vertSpacing
                            )
                    }
                }
            }
        }
    }
}
