//
//  EMSTimerManager.swift
//  LifeLoop
//
//  Created by Jes206 on 9/16/26.
//

import Foundation
import Combine

class EMSTimerManager: ObservableObject {
    
    static let shared = EMSTimerManager()
    
    //@Published allows SwiftUI view to see these variables
    @Published var timeRemaining = 30
    @Published var isActive: Bool = false
    @Published var isAlertTriggered: Bool = false
    @Published var isCountingDown = false
    @Published var triggerReason: String = "EMERGENCY DETECTED"
    
    // Actual iOS timer object
    private var timer: Timer?
    
    // Timer countdown function
    func startCountdown(reason: String) {
        // Fall has been detected (isActive) but set the isAlertTriggered to false so the emergency protocol doesn't start immediately
        
        guard !isCountingDown else { return }
        
        //Store the message for the UI
        self.triggerReason = reason
        
        isCountingDown = true
        timeRemaining = 30
        
        isActive = true
        isAlertTriggered = false
        
        /*
         Allows for repetition of subtracting exactly one second for the countdown within the infinite loop that fires once every second
         [weak self] and guard let prevents memory leak
         */
        
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else {return}
            
            // Whenever there is more than 0 time remaning continue to subtract 1 second until you reach 0
            if self.timeRemaining > 0 {
                self.timeRemaining -= 1
                
            // Users did not cancel countdown (physical or hardware), so kill timer, the countdown is over (isActive), and now call EMS (isAlertTriggered)
                
            } else {
                self.timer?.invalidate()
                self.isActive = false
                self.isAlertTriggered = true
                self.isCountingDown = false
            }
            
        }
    }
    
    /*
     Function that allows for the cancellation of the countdown
     Resets the timer back to 30, and sets the EMS dispatch to false (isAlertTriggered)
     */
    
    func cancelCountdown() {
        timer?.invalidate()
        isActive = false
        timeRemaining = 30
        isAlertTriggered = false
        isCountingDown = false
    }
}
