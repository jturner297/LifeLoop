import AVFoundation
import UIKit // Swapped from CoreHaptics to access system-level haptic patterns
import AudioToolbox

/// The EmergencyAlarmManager is a centralized singleton responsible for handling
/// critical audio and haptic feedback during a detected LifeLoop emergency (State 4).
/// It bypasses standard iOS silent mode restrictions to ensure the user is alerted.
final class EmergencyAlarmManager {
    // Shared instance allows the timer manager to trigger the alarm globally
    // without needing to pass this object through the SwiftUI view hierarchy.
    static let shared = EmergencyAlarmManager()
    
    // Core audio component used to play the looping siren MP3.
    private var audioPlayer: AVAudioPlayer?
    private var hapticTimer: Timer?
    private let impactGenerator = UIImpactFeedbackGenerator(style: .heavy)
    
    private init() {
        // Pre-load the audio file into memory ahead of time so it fires instantly when startAlarm() is called.
        setupAudioSession()
    }
    
    // MARK: - Setup
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            
            // .playback: Forces audio to play even if the physical mute switch is flipped.
            // .default: Standard audio routing (speakers).
            // .duckOthers: Temporarily lowers the volume of other background audio (like Spotify)
            // so the emergency siren takes absolute priority.
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            
            // Locate the physical MP3 file bundled inside the Xcode project.
            guard let url = Bundle.main.url(forResource: "Danger Alarm Sound Effect", withExtension: "mp3") else {
                print("Error: Could not find alarm audio file in bundle.")
                return
            }
            
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            
            // A value of -1 instructs AVFoundation to loop the track infinitely.
            audioPlayer?.numberOfLoops = -1
            
            // Decodes the audio file ahead of time so it fires instantly when startAlarm() is called.
            audioPlayer?.prepareToPlay()
        } catch {
            print("Failed to configure audio session: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Alarm Controls
    
    /// Triggers the emergency siren and begins the looping haptic pulse.
    func startAlarm() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            print("Failed to activate audio session: \(error.localizedDescription)")
        }

        audioPlayer?.play()
        impactGenerator.prepare()
        
        hapticTimer?.invalidate()
        // Fires a heavy system impact every 0.6 seconds to match the visual strobe.
        hapticTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.fireHapticPulse()
        }
    }
    
    /// Instantly halts all audio, deactivates ducking, and resets the track position for the next event.
    func stopAlarm() {
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        hapticTimer?.invalidate()
        hapticTimer = nil
        
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            print("Failed to deactivate audio session: \(error.localizedDescription)")
        }
    }
    
    /// Generates a singular, maximum-intensity physical strike using the Taptic Engine.
    private func fireHapticPulse() {
        AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
        impactGenerator.impactOccurred()
        impactGenerator.prepare()
    }
}
