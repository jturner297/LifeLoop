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
    
    private init() {
        // Initialize the audio session and pre-load the audio file into memory
        // the moment the app launches, eliminating any delay during an actual fall.
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
            try session.setActive(true)
            
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
        audioPlayer?.play()
        
        // Fires a heavy system impact every 0.6 seconds to match the visual strobe.
        // [weak self] prevents a retain cycle memory leak between the timer and this class.
        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] timer in
            // Safely unwrap self and verify the audio is still actively playing.
            // If the audio stopped (meaning the alarm was canceled), invalidate the timer to stop vibrations.
            guard let self = self, self.audioPlayer?.isPlaying == true else {
                timer.invalidate()
                return
            }
            self.fireHapticPulse()
        }
    }
    
    /// Instantly halts all audio and resets the track position for the next event.
    func stopAlarm() {
        audioPlayer?.stop()
        
        // Rewind the track to 0.0 seconds so the next time it triggers, it doesn't start mid-siren.
        audioPlayer?.currentTime = 0
    }
    
    /// Generates a singular, maximum-intensity physical strike using the Taptic Engine.
    private func fireHapticPulse() {
        // UIImpactFeedbackGenerator interfaces directly with UIKit to produce standard OS-level feedback.
        // .heavy pushes the Taptic Engine to simulate the feeling of a dense physical object striking the device.
        let generator = UIImpactFeedbackGenerator(style: .heavy)
        AudioServicesPlayAlertSound(kSystemSoundID_Vibrate)
        
        // Wakes up the Taptic Engine hardware to ensure zero latency on the strike.
        generator.prepare()
        
        // Executes the physical vibration.
        generator.impactOccurred()
    }
}
