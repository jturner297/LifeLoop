# LifeLoop iOS - Project Context

## Architecture & Stack
- **UI Framework:** SwiftUI exclusively.
- **App Routing:** A dual-role state machine managed by `AppRootView` and `@AppStorage("userRole")`. 
  - `AppRole.wearer`: Patient dashboard interacting with local hardware.
  - `AppRole.family`: Caregiver dashboard monitoring AWS telemetry.
- **Hardware Integration:** nRF52840 microcontroller via `CoreBluetooth`.
- **Cloud Backend:** AWS API Gateway and DynamoDB. No direct peer-to-peer phone communication.

## Strict Conventions
- **Secrets Management:** Never hardcode phone numbers, AWS endpoints, or API keys in Swift files. Always load them dynamically from `Info.plist`, which pulls from `.gitignore`d `.xcconfig` files.
- **Bluetooth Reliability:** Critical BLE writes (like canceling the hardware alarm) must use `.withResponse` to force iOS to wait for hardware acknowledgment and prevent packet dropping.
- **Emergency Overrides:** The `EmergencyAlarmManager` must maintain the `AVAudioSession` category `.playback` with `.duckOthers` to bypass the physical iPhone silent switch. Haptics must use legacy `AudioToolbox` (`kSystemSoundID_Vibrate`) for maximum intensity rather than standard UI feedback.

## Prohibitions
- Do not suggest `UIKit` view controllers unless wrapping a component unavailable in SwiftUI.
- Do not attempt to inject audio directly into live cellular phone calls (violates iOS sandboxing). Route TTS scripts through the AWS JSON payload.
