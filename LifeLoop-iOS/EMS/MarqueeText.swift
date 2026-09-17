//
//  MarqueeText.swift
//  LifeLoop
//
//  Created by Jes206 on 9/16/26.
//

import SwiftUI

struct MarqueeText: View {
    let text: String
    let fontName: String
    @State private var offset: CGFloat = 0
    
    var body: some View {
        // Repeat the text enough times so it doesn't run out during the loop
        Text(String(repeating: "\(text)   ", count: 15))
            .font(.custom(fontName, size: 28))
            .foregroundStyle(Color.red)
            .lineLimit(1)
            .fixedSize()
            .offset(x: offset)
            .onAppear {
                // Infinite linear scrolling animation
                withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
                    offset = -250
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 45)
            .background(Color.black)
            .clipped()
    }
}
