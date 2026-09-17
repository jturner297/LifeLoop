import SwiftUI

struct MarqueeText: View {
    let text: String
    let fontName: String
    @State private var offset: CGFloat = 0
    
    var body: some View {
        // 1. Repeat the string 100 times so it creates a massive, unending line of text
        Text(String(repeating: "\(text)      ", count: 100))
            .font(.custom(fontName, size: 28))
            .foregroundStyle(Color.red)
            .lineLimit(1)
            .fixedSize()
            .offset(x: offset)
            .onAppear {
                // 2. Animate it over 60 seconds.
                // Since the countdown is only 30s, the user will literally never see the reset jump.
                withAnimation(.linear(duration: 60.0).repeatForever(autoreverses: false)) {
                    offset = -4000 // Moves a massive distance to keep the speed steady
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 45)
            .background(Color.black)
            .clipped()
    }
}
