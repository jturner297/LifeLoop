# LifeLoop iOS App Documentation

## Overview
LifeLoop is an iOS application built with SwiftUI, integrating Bluetooth Low Energy (BLE) hardware telemetry monitoring, location services via CoreLocation, AWS Amplify with Cognito User Pools and AppSync GraphQL services for family health monitoring, hardware check-in pinging, real-time alert subscriptions, and emergency dispatching.

---

## Architecture & Core Components

### 1. Application Lifecycle & Configuration
* **App Initialization (`LifeLoopApp`):** Configures AWS Amplify (Auth and API plugins) and requests user notification authorizations (`.alert`, `.sound`, `.badge`) on app launch.
* **Bundle Identifier:** Configured dynamically via Xcode build target settings.

### 2. UI & User Flows

#### Root Navigation & Onboarding (`AppRootView`, `AccountSetupView`, `WelcomeView`)
* **Initial Setup Flow:**
  * If account setup is incomplete, the app presents `AccountSetupView` for AWS Cognito authentication (sign in, sign up, email verification code, password reset, challenge/MFA, or option to skip/continue without an account).
  * If account setup is complete but onboarding has not finished, `WelcomeView` prompts the user for their name, optional phone number, email address, and contact sharing consent.
  * Once onboarded, the app displays the main tab interface (`ContentView`).

#### Main Application Navigation (`ContentView`)
* **Tab Navigation:** Houses a 4-tab bottom navigation interface:
  1. **Home:** Main dashboard featuring user greeting, member/device search bar, view filters (Home, Family, Map), local device quick cards, manual "Call Help" emergency button, persistent emergency cancellation failure cards, and group member lists.
  2. **Devices:** Lists all saved LifeLoop BLE hardware peripherals, connection statuses, battery levels, and controls for connecting new peripherals.
  3. **Groups:** Displays family groups, invitation codes, member management, call contacts, and shared device configurations.
  4. **Profile:** Displays user profile details, privacy settings, notification configurations, and account management options.

#### Home Tab (`ContentView`)
* **Manual Emergency Call:** Provides a prominent "Call Help" button to initiate the emergency countdown (`EMSTimerManager`) and issue an `SOS` command to connected BLE devices.
* **Cloud Cancellation Warning Card:** Displays a prominent yellow warning card directly above the emergency button if a cloud emergency cancellation attempt fails on AWS, allowing the wearer to retry cloud cancellation explicitly without restarting an alert.
* **Search & Filters:** Enables filtering by Home view, Family member cards, or interactive group map view.

#### Devices Tab & Device Profiles (`ContentView`, `DeviceProfileSheet`, `AddDeviceSheet`)
* **BLE Device List:** Displays saved hardware peripherals, live heart rate (BPM), connection status (Connected, Connecting, Offline), and low battery warnings (<= 10%).
* **Add Device Sheet (`AddDeviceSheet`):** Scans for nearby LifeLoop BLE peripherals using `BLEMonitor`, listing discovered devices for one-tap pairing.
* **Device Profile Sheet (`DeviceProfileSheet`):** Shows detailed hardware state, battery level, live BPM, coordinates, last update timestamp, location map preview, raw BLE text payload, connection log, option to rename the device, and an explicit removal alert confirmation that disconnects and purges saved peripheral references.

#### Groups & Family Management (`GroupsView`, `GroupDetailView`, `FamilyManagementViews`)
* **Group Management:**
  * **Create & Join:** Users can create new family groups or join existing ones using an alphanumeric invitation code.
  * **Group Details:** Displays invitation code sharing options, local group nickname customization, list of family members, emergency call contacts, and device sharing toggles.
* **Members & Roles (`FamilyMembersView`):**
  * Displays group members and assigned roles (`CREATOR`, `ADMIN`, `MEMBER`).
  * Admin and Creator roles can modify member roles, remove members, or block/unblock users.
* **Emergency Call Contacts (`FamilyContactsView` & `ContactEditor`):**
  * Allows managing up to 10 emergency call contacts per family group.
  * Contact addition requires explicitly validating the contact's name, phone number (E.164 format), and user consent confirmation.
* **Shared Devices (`GroupSharingView`):**
  * Controls which local BLE devices are shared with specific family groups.
* **Member Details & Check-In (`MemberInfoView`):**
  * Shows a family member's telemetry, BPM, online status, reverse-geocoded street address, interactive location map (`MemberMap`), and status of active check-in requests.
  * Includes a **"Send 'Check-In' Ping"** action to send a hardware check-in prompt to the target member's device.

#### Profile & Settings (`ProfileView`, `SettingsView`, `NotificationsView`)
* **User Profile (`ProfileView`):** Displays user initials/avatar, joined family count, and navigation to settings sections.
* **Personal & Privacy Settings (`SettingsView`):**
  * Edits display name, optional birthday (automatically updating calculated user age), phone number, email address, and contact sharing consent.
  * **Privacy Toggles:** Global toggles for `Share location` (`com.lifeloop.family.locationSharingEnabled`) and `Share device information` (`profile.shareDeviceInformation`).
* **Notification Settings (`NotificationsView`):**
  * Configures emergency alerts, call-workflow status updates, and sound toggles.
  * Displays system authorization status, provides a direct link to iOS App Settings, and includes a test notification trigger.

#### Emergency Overlay, Cancellation & Dispatch Status (`EMSCountdown`, `SOSAlertStatusView`)
* **Emergency Countdown (`EMSCountdown` / `EmergencyCountdownScreen`):**
  * Full-screen emergency presentation triggered automatically when a fall or cardiac abnormality is detected, or when manual SOS is pressed.
  * Displays a 30-second countdown ring, trigger reason, dynamic font sizing, accessibility reduce-motion awareness, and an explicit **"I’m OK — Cancel alert"** button.
* **Cancellation Feedback & Retry Alert:**
  * If the wearer cancels an alert but the AWS GraphQL cancellation mutation fails, the screen presents a "Cancellation Unconfirmed" alert prompt with options to retry cancellation or dismiss, ensuring the wearer is explicitly informed that emergency contacts may still be notified.
* **Alert Status (`SOSAlertStatusView`):**
  * Full-screen view presented after the countdown expires while the alert is active on AWS AppSync.
  * Informs the user of dispatch progress, grace period status, and option to request cancellation before emergency calls begin.

---

### 3. Design System & Styling (`LoopStyle`, `LifeLoopBrand`)
* **Color Palette:**
  * `LoopStyle.green` (`#38FF14` / RGB 0.22, 1.0, 0.08)
  * `LoopStyle.mint` (Light background accent)
  * `LoopStyle.background` (Off-white page background)
  * `LoopStyle.ink` (Dark text color)
* **Components & Modifiers:**
  * `.loopCard()`: Styled rounded card container for content blocks.
  * `.loopPage()`: Standard background and tint styling for views.
  * `ProfileAvatar`: Circle avatar rendering initials or fallback icon.
  * `MemberMap`: Standard SwiftUI `Map` wrapper showing member coordinates and fallback states.
  * `LandscapeArt`: Vector gradient and mountain landscape illustration.

---

### 4. Bluetooth Low Energy Integration & Hardware Firmware (`BLEMonitor` & `UpdatedNrfCode.ino`)

#### Hardware Firmware & Hardware State Machine (`UpdatedNrfCode.ino`)
* **Hardware Sensors:** Operates on Arduino-compatible nRF hardware with an LSM6DS3 IMU for accelerometer data and a MAX30105 optical pulse sensor for heart rate DSP. Runs an Edge Impulse Machine Learning model for fall classification.
* **Firmware State Machine (`FallDetection` enum):**
  * `Normal (0)`: Standard monitoring state.
  * `Recovering (3)`: Post-impact observation window.
  * `Emergency (4)`: Fall/Emergency state; flashes red LED and activates 3000 Hz buzzer tone.
  * `Ping (5)`: Check-in request state; flashes blue LED and activates 2000 Hz buzzer tone.
* **Hardware BLE Commands (Received via RX Characteristic):**
  * `"CANCEL"`: Resets state to `Normal (0)`, turns off buzzer, and restores default LEDs.
  * `"SOS"`: Transitions state directly to `Emergency (4)`, activates red LED and 3000 Hz buzzer.
  * `"PING"`: Transitions state to `Ping (5)`, activates blue LED and 2000 Hz buzzer. Pressing the physical hardware button (hold >= 500 ms) acknowledges the check-in and resets state to `Normal (0)`.

#### Hardware BLE Characteristics
* **Service UUID:** `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
* **TX Characteristic (Notify | Read):** `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` (streams payload: `BPM:%.1f|State:%d\n`).
* **RX Characteristic (Write | Write Without Response):** `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`.

#### iOS BLE Central Manager (`BLEMonitor`)
* **Connection Maintenance (`maintainConnections`):** Automatically scans for missing saved devices and retrieves/reconnects known peripherals unless manually disconnected. State restoration is supported via `LifeLoopCentralManager` restore key.
* **Telemetry Parsing:** Parses standard `BPM:%.1f|State:%d` payloads or JSON structures. Extracts heart rate (`bpm`, `heartrate`, `hr`), state, battery level, and optional location coordinates.
* **Emergency Detection:** Automatically triggers the local countdown timer (`EMSTimerManager.shared.startCountdown`) upon detecting cardiac abnormalities (BPM between 1 and 40) or severe fall state (`State 4`).
* **Device Fall Cancellation:** Detects when the wearer manually cancels an emergency on the physical hardware button (transition from State 3/4 to State 0 without an app cancel pending) and posts a `DeviceCancellationRequest`.
* **Ping Acknowledgment:** Detects when a device in `Ping` state (State 5) transitions to `Normal` (State 0), clears active ping flags, updates sequence counters, and posts a `.lifeLoopPingAcknowledged` notification.
* **BLE Command Methods:**
  * `sendSOSCommand()`: Writes `"SOS"` to the RX characteristic of connected peripherals.
  * `sendCancelCommand()`: Writes `"CANCEL"` to connected peripherals.
  * `sendPingCommand(deviceID:)`: Queues and writes `"PING"` to target or all known peripherals.

---

### 5. Emergency Management (`EMSTimerManager`, `EmergencyAlarmManager`)
* **Countdown Manager (`EMSTimerManager`):**
  * Controls the 30-second emergency countdown timer when cardiac, fall, or manual SOS events occur.
  * Holds reference to `triggerDeviceID`, `triggerReason`, and `callDeadline`.
  * `synchronizeCallDeadline(_ date: Date)`: Synchronizes the local timer deadline with the earliest call time returned by AWS backend alerts.
* **Audio & Haptic Alarm (`EmergencyAlarmManager`):**
  * Pre-loads the emergency alarm audio track into memory at app boot without activating the system audio session.
  * **Lazy Audio Activation & Prioritization:** Dynamically activates `AVAudioSession` with `.playback` category and `.duckOthers` option only when `startAlarm()` is executed during an active emergency, ducking external audio (e.g. Spotify/Apple Music).
  * **Haptic Vibration Loop:** Uses a dedicated `UIImpactFeedbackGenerator` with `.heavy` style triggered on a 0.6-second repeating timer alongside system vibrations.
  * **Audio Session Cleanup:** Calling `stopAlarm()` halts playback, invalidates the haptic timer, resets track timing, and explicitly deactivates the audio session with `.notifyOthersOnDeactivation` to immediately restore background audio volume.

---

### 6. Family Telemetry, Check-Ins & Synchronization (`FamilyDeviceManager`, `LoopNotifications`)
* **Telemetry Upload & Link Optimization:**
  * Periodically syncs connected device telemetry (BPM, state, GPS coordinates, location sharing preferences, online status) with AWS AppSync for linked family devices.
  * Maintains an in-memory `linkedDeviceKeys` set cache (`\(code):\(deviceID):\(displayName)`) to execute `linkDevice` GraphQL mutations only once per device connection, eliminating redundant AWS write operations during continuous telemetry streams.
* **Reverse Geocoding:** Converts latitude and longitude coordinates into structured street addresses using `CLGeocoder`, caching results per device.
* **Real-Time Subscription Management:**
  * **Check-In Subscriptions (`ensureCheckInSubscription`):** Listens to GraphQL WebSocket updates (`onCheckInChange`) for prompt acknowledgment.
  * **Alert Subscriptions (`ensureAlertSubscription`):** Subscribes to real-time GraphQL WebSocket alert changes (`onAlertChange`) via `apiClient.subscribeToAlerts(code:)`. Immediately processes incoming alerts, updates active group alert states, and passes alert payloads directly to `LoopNotifications.shared.receive([alert])` without polling delays.
  * **Lifecycle Cleanup:** Cancels and resets WebSocket subscription sequences (`activeCheckInSequence`, `activeAlertSequence`) when leaving groups or invoking `stopSharing()`.
* **Check-In PING Management:**
  * `requestCheckIn(for:)`: Issues a `sendPing` GraphQL mutation to prompt a specific device.
  * `acknowledgePing(checkInID:)`: Issues an `acknowledgePing` GraphQL mutation once the hardware button press is recognized.
* **Alert Lifecycle & Cancellation:**
  * `sendMyEmergencyAlert`: Calls AWS AppSync `startEmergency` mutation with stable alert IDs, location coordinates, and dispatch reason.
  * `cancelMyOwnEmergency` / `cancelAlert` / `cancelEmergency`: Calls AWS AppSync `cancelEmergency` mutation to cancel pending alerts before emergency calls begin.
* **Local & Notification Center Management (`LoopNotifications`):**
  * Manages iOS local user notifications for family alerts and status updates (`FAMILY_ALERT` category).
  * Parses notification response deep links to navigate directly to the target family group.

---

### 7. Cloud Infrastructure & Networking (`FamilyAPIClient`, AWS Amplify)
Communicates with AWS AppSync GraphQL API backend using Amplify API plugin with AWS Cognito User Pools authorization (`AMAZON_COGNITO_USER_POOLS`).

* **Authentication & Auth Plugin:**
  * User Pool ID: `us-east-2_zO8kdjTEs`
  * App Client ID: `si1qof5nhh76a6gguldcth0nn`
  * Region: `us-east-2`
  * Auth Flow: `USER_SRP_AUTH`

* **GraphQL API Operations (`FamilyAPIClient`):**
  * **Group & Membership Management:**
    * `createFamily(displayName:)`: Creates a new family group.
    * `joinFamily(code:displayName:)`: Joins a family group via invitation code.
    * `myFamilies()`: Fetches families the authenticated user belongs to.
    * `members(code:)` / `blockedMembers(code:)`: Retrieves group members and blocked users.
    * `setRole(code:userID:role:)`: Modifies member role (`CREATOR`, `ADMIN`, `MEMBER`).
    * `membershipAction(_:code:userID:)`: Executes membership mutations (`leaveFamily`, `removeMember`, `unblockMember`).
  * **Emergency Call Contacts:**
    * `contacts(code:)`: Retrieves configured emergency contacts for a group.
    * `saveContact(code:contactID:name:phone:)`: Creates (`addContact`) or updates (`updateContact`) emergency contacts.
    * `deleteContact(code:contactID:)`: Deletes an emergency contact.
  * **Telemetry & Devices:**
    * `linkDevice(_:)`: Associates a BLE peripheral with a family group code.
    * `uploadTelemetry(_:)`: Transmits `FamilyTelemetryPayload` updates.
    * `fetchFamilyDevices(groupCode:)`: Queries current member device statuses, telemetry, and location data.
  * **Alerts & Check-Ins:**
    * `startEmergency(_:)`: Dispatches `StartEmergencyInput` to initiate emergency call workflows.
    * `cancelEmergency(alertID:)`: Cancels an active emergency alert.
    * `alerts(code:)`: Queries recent alerts (`alertsForGroup`) for a family group.
    * `sendPing(code:targetDeviceID:)` / `acknowledgePing(checkInID:)`: Sends or acknowledges check-in pings.
    * `subscribeToCheckIns(code:)`: Real-time subscription to `onCheckInChange`.
    * `subscribeToAlerts(code:)`: Real-time subscription to GraphQL `onAlertChange` events.

---

### 8. Location Services (`LocationManager`)
* **Location Tracking:** Manages user permissions, continuous positioning updates via CoreLocation, and background location updates.
* **Coordinates Integration:** Supplies real-time latitude and longitude data for telemetry sync, map rendering, and emergency alert payloads when location sharing is enabled.

---

### 9. Infrastructure & Codebase Optimizations

#### Key Audits & Fixes (`ANALYSIS_REPORT.md`)
* **Cloud Alert Cancellation Feedback:** Resolved state teardown issue during countdown dismissal by surfacing unconfirmed cancellations via native alert dialogs and Home view retry buttons.
* **Audio Session Priority & Deactivation:** Prevents background audio ducking at app launch by deferring `AVAudioSession` activation to active siren events and explicitly releasing the session on stop.
* **Real-time Alert Notifications:** Replaced polling mechanisms with real-time AWS AppSync GraphQL WebSocket subscriptions (`onAlertChange`) for instant caregiver emergency notifications.
* **GraphQL Write Reduction:** Implemented key caching for device linking to prevent unnecessary repeat `linkDevice` mutations during live device telemetry streaming.

#### Automated Documentation
* **Auto-Docs Workflow (`.github/workflows/auto-docs.yml`):** Utilizes Gemini CLI (`gemini-3.6-flash` model) for automated documentation maintenance upon repository pushes. Configured to maintain and commit updates directly to `README.md`.
