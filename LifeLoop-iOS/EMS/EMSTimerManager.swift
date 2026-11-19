//
//  EMSTimerManager.swift
//  LifeLoop
//
//  Created by Jes206 on 9/16/26.
//

import Foundation
import Combine
import UIKit

@MainActor
final class EMSTimerManager: ObservableObject {
    
    static let shared = EMSTimerManager()
    
    //@Published allows SwiftUI view to see these variables
    @Published var timeRemaining = 30
    @Published var isActive: Bool = false
    @Published var isAlertTriggered: Bool = false
    @Published var isCountingDown = false
    @Published var triggerReason: String = "EMERGENCY DETECTED"
    
    private(set) var triggerDeviceID: String?
    var onImmediateTrigger: ((String) -> Void)?
    
    // Actual iOS timer object
    private var timer: Timer?
    private var callDeadline: Date?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    func synchronizeCallDeadline(_ date: Date) {
        callDeadline = date
        timeRemaining = max(0, Int(ceil(date.timeIntervalSinceNow)))
    }
    
    private func beginBackgroundCountdownTask() {
        endBackgroundCountdownTask()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "LifeLoopEmergencyCountdown") { [weak self] in
            self?.endBackgroundCountdownTask()
        }
    }
    
    private func endBackgroundCountdownTask() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }
    
    // Timer countdown function
    func startCountdown(reason: String, deviceID: String? = nil) {
        // Fall has been detected (isActive) but set the isAlertTriggered to false so the emergency protocol doesn't start immediately
        
        guard !isCountingDown, !isActive, !isAlertTriggered else { return }
        
        beginBackgroundCountdownTask()
        
        // Store state before triggering alarm, notifications, or cloud dispatch callbacks
        self.triggerReason = reason
        triggerDeviceID = deviceID
        timeRemaining = 30
        callDeadline = Date().addingTimeInterval(30)
        isActive = true
        isAlertTriggered = false
        isCountingDown = true

        EmergencyAlarmManager.shared.startAlarm()
        LoopNotifications.shared.postLocalEmergencyCountdown(reason: reason)
        onImmediateTrigger?(reason)
        
        /*
         Allows for repetition of subtracting exactly one second for the countdown within the infinite loop that fires once every second
         [weak self] and guard let prevents memory leak
         */
        let newTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isCountingDown else { return }

                // Whenever there is more than 0 time remaining continue to subtract 1 second until you reach 0
                self.timeRemaining = max(0, Int(ceil((self.callDeadline ?? Date()).timeIntervalSinceNow)))
                if self.timeRemaining == 0 {
                    self.timer?.invalidate()
                    self.timer = nil
                    // Keep the emergency presentation visible as it transitions to delivery status.
                    self.isAlertTriggered = true
                    self.isActive = false
                    self.isCountingDown = false

                    EmergencyAlarmManager.shared.stopAlarm()
                    self.endBackgroundCountdownTask()
                }
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }
    
    /*
     Function that allows for the cancellation of the countdown
     Resets the timer back to 30, and sets the EMS dispatch to false (isAlertTriggered)
     */
    
    func cancelCountdown() {
        timer?.invalidate()
        timer = nil
        callDeadline = nil
        triggerDeviceID = nil
        isActive = false
        timeRemaining = 30
        isAlertTriggered = false
        isCountingDown = false
        EmergencyAlarmManager.shared.stopAlarm()
        LoopNotifications.shared.clearLocalEmergencyCountdown()
        endBackgroundCountdownTask()
    }
}
