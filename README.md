# LifeLoop iOS (SwiftUI)

This Xcode project is the iOS version of the LifeLoop Android prototype.

## Updated dashboard
The main screen now follows the Android screenshot style:
- dark navy dashboard
- time-aware “Good morning / afternoon / evening” greeting
- device-attention subtitle
- teal ECG waveform
- LifeLoop Band device rows with status/battery text
- blue active-device indicator
- floating teal + button for BLE scanning

## Bluetooth
The existing CoreBluetooth implementation is preserved. Tap the active device row or the + button to scan for the LifeLoop BLE peripheral. When connected, the first device row updates to the connected peripheral name.

For BLE testing, run on a physical iPhone.

## Xcode setup
1. Open `LifeLoop.xcodeproj`.
2. Select the LifeLoop target.
3. Under Signing & Capabilities, choose your Apple Developer Team.
4. Connect an iPhone and Run.
