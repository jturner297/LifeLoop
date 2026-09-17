//
//  EMSCountdown.swift
//  LifeLoop
//
//  Created by Jes206 on 9/15/26.
//

import SwiftUI

struct EMSCountdown: View {
    // Watch timer for any changes
    @ObservedObject var timerManager: EMSTimerManager
    
    @State private var isFlashing = false
    
    let mainWarningFont = "Helvetica-Neue-Condensed-Black"
    let secondaryFont = "Futura-CondensedMedium"
    
    var body: some View {
        ZStack {
            // Background layer
            // Dark background to make the red pop out more
            Color(red: 0.45, green: 0.05, blue: 0.05).ignoresSafeArea()
            
            // The Geometric Pointy-Topped Hexagon Grid
            HexagonGrid()
                .ignoresSafeArea()
            
            // Strobing red overlay
            Color.red
                .opacity(isFlashing ? 0.65 : 0.0) // Pulse between visible and hidden
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.35).repeatForever(autoreverses: true), value: isFlashing)
            
            VStack(spacing: 0) {
                // Top Marquee Tape
                MarqueeText(text: "EMERGENCY", fontName: mainWarningFont)
                
                Spacer()
                
                VStack(spacing: 10) {
                    // Warning Header
                    Text("FALL DETECTED")
                        .font(.custom(mainWarningFont, size: 50)) // Scaled down to prevent crowding
                        .foregroundStyle(Color.white)
                        .shadow(color: .black, radius: 2, x: 2, y: 2)
                    
                    Text("EMS will be dispatched in:")
                        .font(.custom(secondaryFont, size: 22))
                        .foregroundStyle(Color.white) // Matched to the red in the target image
                    
                    // Live countdown that will update every second due to @ObservedObject
                    Text("\(timerManager.timeRemaining)")
                        .font(.custom(mainWarningFont, size: 120)) // Scaled down for breathing room
                        .foregroundStyle(Color.white)
                        .shadow(color: .black, radius: 4, x: 3, y: 3)
                        .padding(.vertical, -10)
                }
                
                Spacer()
                
                // Warning Tape Block
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.red)
                        .frame(height: 5) // Top warning border
                    
                    // Cancellation button
                    Button(action: {
                        timerManager.cancelCountdown()
                    }) {
                        Text("CANCEL ALARM")
                            .font(.custom(mainWarningFont, size: 30))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 65)
                            .background(Color.black)
                    }
                    
                    Rectangle()
                        .fill(Color.red)
                        .frame(height: 5) // Bottom warning border
                }
                .padding(.bottom, 40) // Adds spacing before the bottom marquee
                
                // Bottom Marquee Tape
                MarqueeText(text: "EMERGENCY", fontName: mainWarningFont)
            }
        }
        .onAppear {
            // Start flashing loop when screen appears
            isFlashing = true
        }
    }
}

// Preview provider allows us to see the UI in Xcode without running it on an iphone
struct EMSCountdown_Previews: PreviewProvider {
    static var previews: some View {
        EMSCountdown(timerManager: EMSTimerManager())
    }
}
