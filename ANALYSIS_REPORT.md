# LifeLoop Codebase Analysis & Optimization Report

A comprehensive audit of the **LifeLoop iOS** application codebase and the associated **nRF52840 (UpdatedNrfCode.ino)** firmware.

---

## 1. Critical Bugs & Safety Issues

### 1.1 Cloud Alert Cancellation Feedback on Wearer Device — **[FIXED]**
- **File:** [`ContentView.swift`](file:///Users/jes206/Desktop/LifeLoop/LifeLoop-iOS/Views/ContentView.swift#L307-L365)
- **Status:** **RESOLVED**
- **Issue:** When the wearer tapped *"I’m OK — Cancel alert"* on the countdown screen, `closeEmergency()` immediately executed `timer.cancelCountdown()`. This caused the `.fullScreenCover` to instantly dismiss. If a network drop or AWS error occurred in the background task, the error message was lost because its container was already gone, leaving the wearer unaware that the AWS cloud alert remained `PENDING`.
- **Resolution:**
  - Added a dedicated `.alert("Cancellation Unconfirmed", isPresented: $showCancellationAlert)` with a *"Retry Cancellation"* action.
  - Added a persistent alert card directly on `ContentView`'s Home screen above the emergency button showing the failure details with a *"Retry Cloud Cancellation"* button if AWS cancellation fails.
  - Cleared cancellation error state when cloud cancellation succeeds.

---

### 1.2 Audio Ducking of System Music at App Launch — **[FIXED]**
- **File:** [`EmergencyAlarmManager.swift`](file:///Users/jes206/Desktop/LifeLoop/LifeLoop-iOS/EMS/EmergencyAlarmManager.swift#L24-L85)
- **Status:** **RESOLVED**
- **Issue:** `AVAudioSession.sharedInstance().setActive(true)` with `.duckOthers` was invoked in `setupAudioSession()` during `EmergencyAlarmManager.init()` when the app booted up, causing all background audio (Spotify, Apple Music, podcasts) to be permanently lowered in volume. Furthermore, when the alarm was stopped, the audio session was never deactivated.
- **Resolution:**
  - Removed `setActive(true)` from `setupAudioSession()`.
  - Added `setActive(true)` only when `startAlarm()` is actively called during an emergency.
  - Added `setActive(false, options: [.notifyOthersOnDeactivation])` in `stopAlarm()` to immediately restore background audio volume.
  - Reused a single `UIImpactFeedbackGenerator` instance and explicitly tracked `hapticTimer` so multiple alarms cannot leave orphaned timers.

---

### 1.3 Cardiac Abnormalities Cannot Be Canceled from the Wearer Hardware — **[PENDING]**
- **Files:** [`UpdatedNrfCode.ino`](file:///Users/jes206/Desktop/LifeLoop/EdgeImpulse/UpdatedNrfCode.ino#L303-L359), [`BLEMonitor.swift`](file:///Users/jes206/Desktop/LifeLoop/LifeLoop-iOS/Bluetooth/BLEMonitor.swift#L321-L326)
- **Status:** **PENDING FIRMWARE UPDATE**
- **Issue:** When heart rate drops to abnormal levels (`bpm > 0 && bpm <= 40`), `BLEMonitor` triggers an emergency alarm countdown on the phone. However, the hardware state remains in `Normal` (State `0`). The nRF52840 firmware only reads the physical button during `Recovering`, `Emergency`, or `Ping` states.
- **Consequence:** If an abnormal heart-rate warning occurs, the wearer cannot cancel the alarm using the watch button; they can only cancel it from the iPhone screen.
- **Recommended Fix:** Allow the button hold to be detected during `Normal` or send a state command (e.g. `ALARM`) from iOS to the watch so the watch enters an active alarm state and recognizes the cancel hold.

---

### 1.4 Manual SOS Command Not Queued During BLE Reconnection — **[PENDING]**
- **File:** [`BLEMonitor.swift`](file:///Users/jes206/Desktop/LifeLoop/LifeLoop-iOS/Bluetooth/BLEMonitor.swift#L380-L394)
- **Status:** **PENDING**
- **Issue:** While `sendCancelCommand()` and `sendPingCommand()` queue pending commands (`pendingCancels`, `pendingPings`) if the peripheral is currently reconnecting, `sendSOSCommand()` immediately drops the command if `rxCharacteristics[id]` is not already discovered.
- **Recommended Fix:** Implement `pendingSOS` queue with `flushPendingSOS` to ensure manual emergency triggers are guaranteed to reach the device once connected.

---

## 2. Network & Cloud Inefficiencies

### 2.1 Redundant `linkDevice` Mutation on Every Telemetry Packet — **[FIXED]**
- **File:** [`FamilyDeviceManager.swift`](file:///Users/jes206/Desktop/LifeLoop/LifeLoop-iOS/Family/FamilyDeviceManager.swift#L130-L140)
- **Status:** **RESOLVED**
- **Issue:** Inside `uploadLocalDevices()`, line 133 executed `try await apiClient.linkDevice(...)` on **every single telemetry upload** (every 3–4 seconds or whenever BPM changed by 1.0), causing high AWS GraphQL/DynamoDB write costs and network latency.
- **Resolution:** Added `linkedDeviceKeys` set cache. `linkDevice` is now only invoked once per device/group/name, completely eliminating redundant AWS mutations during live telemetry streaming.

---

### 2.2 AppSync Emergency Alert Real-Time Subscription — **[FIXED]**
- **Files:** [`FamilyAPIClient.swift`](file:///Users/jes206/Desktop/LifeLoop/LifeLoop-iOS/Networking/FamilyAPIClient.swift#L214-L225), [`FamilyDeviceManager.swift`](file:///Users/jes206/Desktop/LifeLoop/LifeLoop-iOS/Family/FamilyDeviceManager.swift#L400-L450)
- **Status:** **RESOLVED**
- **Issue:** The AWS GraphQL schema defined `onAlertChange`, but the iOS app previously polled `alerts(code:)` on a 5-second timer, introducing up to 5 seconds of delay before caregivers received emergency notifications.
- **Resolution:**
  - Implemented `subscribeToAlerts(code:)` on `FamilyAPIClient` using Amplify's GraphQL subscription client.
  - Implemented `ensureAlertSubscription()` and `handleAlertUpdate(_:)` in `FamilyDeviceManager` to listen for real-time WebSocket events.
  - Integrated `LoopNotifications.shared.receive([alert])` to immediately trigger notifications with zero polling delay.
  - Wired proper cancellation of alert subscriptions in `stopSharing()`.

---

### 2.3 Aggressive CLGeocoder Reverse Geocoding Rate-Limiting Risk — **[PENDING]**
- **File:** [`FamilyDeviceManager.swift`](file:///Users/jes206/Desktop/LifeLoop/LifeLoop-iOS/Family/FamilyDeviceManager.swift#L223-L251)
- **Status:** **PENDING**
- **Issue:** In `MemberInfoView`, a loop runs every 2 seconds calling `resolveAddress(for: member)`. If the initial geocoding request fails, `lastLocations[device.id]` is not set, spawning a new `CLGeocoder().reverseGeocodeLocation()` request every 2 seconds.
- **Consequence:** Apple strictly rate-limits `CLGeocoder` (approx. 1 request per minute). Rapid repeated calls trigger `kCLErrorNetwork` / `kCLErrorDomain 2`.
- **Recommended Fix:** Add a timestamp throttle (minimum 60 seconds between attempts per device).

---

## 3. Performance, Battery & Resource Leaks

### 3.1 Unused `LocationManager` Instance Inside `BLEMonitor` — **[PENDING]**
- **File:** [`BLEMonitor.swift`](file:///Users/jes206/Desktop/LifeLoop/LifeLoop-iOS/Bluetooth/BLEMonitor.swift#L21)
- **Status:** **PENDING**
- **Issue:** `BLEMonitor` declares `private let locationManager = LocationManager()` which is never used anywhere in the class.
- **Consequence:** Runs an extra redundant GPS manager alongside `ContentView`'s location manager, unnecessarily consuming battery.
- **Recommended Fix:** Remove the property declaration.

---

### 3.2 Battery Drain from BLE Scan with `AllowDuplicatesKey: true` — **[PENDING]**
- **File:** [`BLEMonitor.swift`](file:///Users/jes206/Desktop/LifeLoop/LifeLoop-iOS/Bluetooth/BLEMonitor.swift#L94-L96)
- **Status:** **PENDING**
- **Issue:** `startScanning()` passes `CBCentralManagerScanOptionAllowDuplicatesKey: true`.
- **Consequence:** Invokes `didDiscover` dozens of times per second, triggering high CPU usage and rapid `@Published discoveredPeripherals` updates.
- **Recommended Fix:** Omit or set `CBCentralManagerScanOptionAllowDuplicatesKey: false`.

---

### 3.3 Cold Launch State Loss in `UserProfile` — **[PENDING]**
- **File:** [`UserProfile.swift`](file:///Users/jes206/Desktop/LifeLoop/LifeLoop-iOS/Models/UserProfile.swift#L41-L46)
- **Status:** **PENDING**
- **Issue:** Lines 41–45 decode `groups` from `UserDefaults`, but line 46 immediately resets `groups = []`.
- **Consequence:** On every cold launch, the user sees an empty group list until AWS network calls finish.
- **Recommended Fix:** Keep decoded groups as the initial cache and update when `refreshFamilies()` completes.

---

## 4. Hardware Firmware (nRF52840) Optimizations

### 4.1 Missing Battery Telemetry in Firmware — **[PENDING]**
- **File:** [`UpdatedNrfCode.ino`](file:///Users/jes206/Desktop/LifeLoop/EdgeImpulse/UpdatedNrfCode.ino#L514-L519)
- **Status:** **PENDING FIRMWARE UPDATE**
- **Issue:** The firmware transmits `BPM:%.1f|State:%d\n` without measuring or sending battery voltage.
- **Recommended Fix:** Read `analogRead(PIN_VBAT)` and append `|Bat:%d` to the BLE payload.

---

### 4.2 I2C Blocking During Machine Learning Classification — **[PENDING]**
- **File:** [`UpdatedNrfCode.ino`](file:///Users/jes206/Desktop/LifeLoop/EdgeImpulse/UpdatedNrfCode.ino#L318-L320)
- **Status:** **PENDING FIRMWARE UPDATE**
- **Issue:** Synchronous Edge Impulse execution blocks `loop()` for 15–35ms, causing MAX30105 sample drops.
- **Recommended Fix:** Utilize the MAX30105 hardware FIFO buffer.

---

## 5. Summary Status

| Priority | Item | Component | Status |
| :--- | :--- | :--- | :--- |
| **High** | Fix cloud alert cancellation feedback when modal is dismissed | `ContentView.swift` | **FIXED** |
| **High** | Defer `AVAudioSession.setActive(true)` until emergency occurs | `EmergencyAlarmManager.swift` | **FIXED** |
| **High** | Subscribe to AppSync `onAlertChange` instead of polling | `FamilyAPIClient.swift` / `FamilyDeviceManager.swift` | **FIXED** |
| **Medium** | Remove redundant `linkDevice` mutation on every telemetry send | `FamilyDeviceManager.swift` | **FIXED** |
| **Medium** | Delete unused `LocationManager` in `BLEMonitor` | `BLEMonitor.swift` | Pending |
| **Medium** | Disable `allowDuplicatesKey: true` in BLE scan | `BLEMonitor.swift` | Pending |
| **Medium** | Throttle `CLGeocoder` reverse geocoding in `FamilyDeviceManager` | `FamilyDeviceManager.swift` | Pending |
| **Low** | Implement battery reporting in firmware | `UpdatedNrfCode.ino` | Pending |
| **Low** | Preserve cached groups across app restarts | `UserProfile.swift` | Pending |
