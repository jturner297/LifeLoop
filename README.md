# LifeLoop iOS App Documentation

## Overview
LifeLoop is an iOS application built with SwiftUI, integrating Bluetooth Low Energy (BLE) hardware telemetry monitoring, location services via CoreLocation, AWS Amplify with Cognito User Pools and AppSync GraphQL services for family health monitoring, hardware check-in pinging, real-time alert subscriptions, and emergency dispatching.

The app supports dual operation modes: a streamlined **Watch Wearer** mode optimized for device control, power management, and instant emergency calling/cancellation; and a **Caretaker / Family** mode providing a full health dashboard, live maps, shared device telemetry, and family group management.

---

## Architecture & Core Components

### 1. Application Lifecycle & Configuration
* **App Initialization (`LifeLoopApp`):** Configures AWS Amplify (Auth and API plugins), configures local notification categories (including time-sensitive emergency countdown alerts), and requests user notification authorizations (`.alert`, `.sound`, `.badge`) on launch.
* **Background Modes:** Configured in `Info.plist` for `bluetooth-central`, `bluetooth-peripheral`, `processing`, `location`, `remote-notification`, and `audio` playback.
* **Bundle Identifier:** Configured dynamically via Xcode build target settings (`app.ShortCircuit.LifeLoop-conf0`).

---

### 2. UI, Roles & User Flows

#### Dual User Roles (`AppRole`)
The application adapts its navigation and interface based on the user's selected role:
* **Watch Wearer (`AppRole.wearer`):** A simplified dashboard focused on quick access to manual SOS emergency triggers, battery percentage monitoring, sleep/wake power controls for paired hardware, and basic family link status.
* **Caretaker / Family (`AppRole.family`):** A comprehensive 4-tab navigation interface providing family device monitoring, map locations, group management, emergency contact configuration, and member health check-ins.

Role assignment is specified during account registration or set when continuing without an account, and is synchronized via Cognito user attributes (`profile`) or saved locally (`userRole`).

#### Account Setup & Authentication (`AccountSetupView`)
* **Cognito Authentication:** Supports sign in, sign up, email verification code confirmation, password reset, and challenge/MFA flows.
* **Password Validation Checklist:** Provides real-time feedback against security rules during sign up and password reset:
  * At least 8 characters
  * At least 1 uppercase letter (`A–Z`)
  * At least 1 lowercase letter (`a–z`)
  * At least 1 numeric digit (`0–9`)
  * At least 1 special character (`!@#$%^&*`)
  * Displays specific missing criteria in red error prompts if submission fails.
* **Role Selection:** Allows selecting between **Caretaker / Family** and **Watch Wearer** roles during registration.
* **Skip Option:** Users can choose "Continue without an account (Wearer Mode)" to use local Bluetooth hardware features without AWS cloud integration.

#### Root Navigation & Onboarding (`AppRootView`, `WelcomeView`, `QuickStartGuideSheet`)
* **Onboarding Flow:** Prompts new users for display name, optional phone number, email address, contact sharing consent, and presents an interactive **Quick Start Guide**.
* **Appearance Configuration:** Supports dynamic appearance modes (`light`, `dark`, or `system`), adjusting color schemes across the app.
* **Quick Start Guide (`QuickStartGuideSheet` & `QuickStartCardsSection`):**
  * Accessible from onboarding, home headers, wearer view, and profile settings.
  * Guides **Watch Wearers** through BLE pairing, checking battery %, toggling Sleep Mode, and canceling 30-second emergency countdowns.
  * Guides **Family Caregivers** through creating/joining family groups (6-character invitation code), linking shared devices, and adding emergency call contacts.

#### Wearer Dashboard (`ContentView` - Wearer Role)
* **SOS Action Button:** Large full-width button to initiate an emergency SOS countdown or cancel an active emergency alert.
* **My Watch Section:** Card list displaying paired BLE devices, connection state, battery level, live BPM, and a single-tap **"Turn Watch Off (Sleep Mode)"** / **"Turn Watch On (Wake Up)"** button.
* **Family Link Banner:** Displays active family group count and provides quick access to join groups or manage cloud sign-in.

#### Caregiver Tab Navigation (`ContentView` - Family Role)
Houses a 4-tab bottom navigation bar for caregivers:
1. **Home:** Greeting, member/device search bar, view filters (Home, Family, Map), local device cards, manual "Call Help" button, persistent emergency cancellation failure cards, and group member lists.
2. **Devices:** Pair and view saved BLE hardware peripherals, connection statuses, live BPM, battery warnings, and Sleep Mode status.
3. **Groups:** Manage family groups, invitation codes, member roles, call contacts, and shared device configurations.
4. **Profile:** Account management, notification options, appearance theme picker, Quick Start guide, and privacy settings.

#### Devices Tab & Device Profiles (`ContentView`, `DeviceProfileSheet`, `AddDeviceSheet`)
* **BLE Device List:** Displays saved hardware peripherals, live heart rate (BPM), connection status (Connected, Connecting, Offline), low battery warnings (<= 10%), and Sleep Mode indicators (`state 6`).
* **Sleep Mode Controls:** Direct action buttons and context menu options to toggle devices between **Sleep Mode** (`"SLEEP"`) and **Normal Operation** (`"WAKE"`).
* **Add Device Sheet (`AddDeviceSheet`):** Scans for nearby LifeLoop BLE peripherals using `BLEMonitor`, listing discovered devices for one-tap pairing.
* **Device Profile Sheet (`DeviceProfileSheet`):** Displays detailed hardware state (Normal, Recovering, Emergency, Check-In Ping, Sleep Mode), battery level, live BPM, coordinates, location map preview, raw BLE text payload, connection log, renaming controls, Sleep/Wake toggles, and device deletion options.

#### Groups & Family Management (`GroupsView`, `GroupDetailView`, `FamilyManagementViews`)
* **Group Operations:** Create new family groups or join existing ones using 6-character invitation codes. Customize local nicknames.
* **Members & Roles (`FamilyMembersView`):** View members and assign roles (`CREATOR`, `ADMIN`, `MEMBER`). Admin and Creator roles can modify member roles, remove members, or block/unblock users.
* **Emergency Call Contacts (`FamilyContactsView` & `ContactEditor`):**
  * Manage up to 10 emergency call contacts per family group.
  * Includes explicit warnings reminding users to enter phone numbers for family members or caregivers—**not the watch wearer's own phone number**.
  * **Self-Number Warning:** Validates entered phone numbers against the current user profile. Displays an orange warning prompt if a user attempts to add their own phone number as an emergency call contact.
  * Contact validation enforces E.164 phone formatting (`+1...`) and consent verification.
* **Shared Devices (`GroupSharingView`):** Select which local BLE devices are shared with specific family groups.
* **Member Details & Check-In (`MemberInfoView`):** Displays telemetry, BPM, online status, reverse-geocoded address, location map (`MemberMap`), and hardware state (including Sleep Mode). Includes **"Send 'Check-In' Ping"** action.

#### Profile & Settings (`ProfileView`, `SettingsView`, `NotificationsView`)
* **User Profile (`ProfileView`):** Avatar, joined family count, Quick Start guide launcher, notifications settings, and profile options.
* **Personal & Privacy Settings (`SettingsView`):**
  * **Appearance Picker:** Choose between Light, Dark, or System system scheme.
  * **Personal Information:** Edit display name, optional birthday (updates calculated user age), phone number, email address, and contact sharing consent.
  * **Privacy Toggles:** Toggles for location sharing (`com.lifeloop.family.locationSharingEnabled`) and device information sharing (`profile.shareDeviceInformation`).
* **Notification Settings (`NotificationsView`):** Configure emergency alerts, sound toggles, authorization status link, and test notification triggers.

#### Emergency Overlay, Cancellation & Notifications (`EMSCountdown`, `SOSAlertStatusView`, `LoopNotifications`)
* **Emergency Countdown (`EMSCountdown` / `EmergencyCountdownScreen`):**
  * Presented automatically when a fall or cardiac abnormality is detected, or when manual SOS is pressed.
  * 30-second countdown ring, trigger reason, dynamic font sizing, accessibility reduce-motion support, and an explicit **"I’m OK — Cancel alert"** button.
* **Time-Sensitive Local Notification:**
  * When a countdown begins, a time-sensitive local notification (`LOCAL_EMERGENCY_COUNTDOWN`) is posted: *"EMERGENCY ALERT — Do you need help?"*.
  * Features an interactive notification action **"I’m OK — Cancel Alert"** (`CANCEL_EMERGENCY`), allowing users to cancel emergency countdowns directly from the iOS lock screen or notification center.
* **Background Task Protection:** The countdown manager registers an iOS background task (`LifeLoopEmergencyCountdown`) to ensure the 30-second timer runs to completion even if the app is backgrounded.
* **Cancellation Feedback & Warning Card:**
  * If the user cancels an alert but the AWS GraphQL cancellation mutation fails, the screen presents a "Cancellation Unconfirmed" alert prompt.
  * A yellow warning card appears on the Home view above the emergency button, allowing the user to retry cloud cancellation explicitly without restarting an alert.
* **Alert Status (`SOSAlertStatusView`):** Active status view presented after countdown expiry informing user of dispatch progress, grace period, and cancellation options.

---

### 3. Design System & Styling (`LoopStyle`, `LifeLoopBrand`)
* **Dynamic Theme Support:** Full support for Light and Dark system appearance options.
* **Color Palette:**
  * `LoopStyle.green` (`#38FF14` / RGB 0.22, 1.0, 0.08)
  * `LoopStyle.mint` (Dynamic light/dark background accent green)
  * `LoopStyle.background` (Dynamic page background)
  * `LoopStyle.card` (Dynamic card surface: white in Light mode, dark slate in Dark mode)
  * `LoopStyle.ink` (Dynamic text color)
  * `LoopStyle.darkInk` (Fixed dark ink color `#1A2924` for high contrast on green buttons)
* **Components & Modifiers:**
  * `.loopCard()`: Styled rounded card container matching active light/dark theme.
  * `.loopPage()`: Standard background and tint styling for view pages.
  * `ProfileAvatar`: Circle avatar rendering initials or fallback icon.
  * `MemberMap`: SwiftUI `Map` wrapper showing member coordinates and fallback states.

---

### 4. Bluetooth Low Energy Integration & Hardware Firmware (`BLEMonitor` & `UpdatedNrfCode.ino`)

#### Hardware Firmware & State Machine (`UpdatedNrfCode.ino`)
* **Hardware Sensors:** Arduino-compatible nRF hardware with an LSM6DS3 IMU for fall detection (Edge Impulse ML model) and MAX30105 optical sensor for heart rate DSP.
* **Firmware State Machine (`FallDetection` enum):**
  * `Normal (0)`: Standard telemetry monitoring.
  * `Recovering (3)`: Post-impact observation window.
  * `Emergency (4)`: Fall/Emergency state; red LED flash, 3000 Hz buzzer tone.
  * `Ping (5)`: Check-in request state; blue LED flash, 2000 Hz buzzer tone.
  * `Sleeping (6)`: Low-power sleep state; optical sensor shut down (`particleSensor.shutDown()`), heart rate sampling paused, LEDs off, buzzer disabled.
* **Hardware BLE RX Commands:**
  * `"CANCEL"`: Resets state to `Normal (0)` (wakes optical sensor if sleeping), turns off buzzer, restores default LEDs.
  * `"SOS"`: Wakes optical sensor if sleeping, transitions state to `Emergency (4)`, activates red LED and 3000 Hz buzzer.
  * `"PING"`: Wakes optical sensor if sleeping, transitions state to `Ping (5)`, activates blue LED and 2000 Hz buzzer. Physical button hold (>= 500 ms) acknowledges check-in and restores `Normal (0)`.
  * `"SLEEP"`: Transitions state to `Sleeping (6)`, resets HR, shuts down optical sensor (`particleSensor.shutDown()`), turns off buzzer, turns off LEDs.
  * `"WAKE"`: Wakes optical sensor (`particleSensor.wakeUp()`), resets HR, transitions state to `Normal (0)`, turns off buzzer, restores LEDs.

#### Hardware BLE Characteristics
* **Service UUID:** `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
* **TX Characteristic (Notify | Read):** `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` (streams payload `BPM:%.1f|State:%d\n`).
* **RX Characteristic (Write | Write Without Response):** `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`.

#### iOS BLE Central Manager (`BLEMonitor`)
* **Connection Maintenance (`maintainConnections`):** Automatically scans for missing saved devices and reconnects known peripherals. State restoration supported via `LifeLoopCentralManager` restore key.
* **Telemetry Parsing:** Parses `BPM:%.1f|State:%d` payloads or JSON structures. Updates heart rate, state, battery level, and location coordinates.
* **Emergency Detection:** Triggers countdown timer (`EMSTimerManager.shared.startCountdown`) upon cardiac abnormalities (BPM between 1 and 40) or fall state (`State 4`).
* **Power Command Management:**
  * `sendSleepCommand(deviceID:)`: Queues `"SLEEP"` command with 15-second expiration deadline, writes to peripheral RX characteristic, and updates local state to `State 6` with 0 BPM.
  * `sendWakeCommand(deviceID:)`: Queues `"WAKE"` command with 15-second deadline, writes to RX characteristic, and updates local state to `State 0`.
* **BLE Command Methods:**
  * `sendSOSCommand()`: Writes `"SOS"` to connected peripherals.
  * `sendCancelCommand()`: Writes `"CANCEL"` to connected peripherals.
  * `sendPingCommand(deviceID:)`: Writes `"PING"` to target device.

---

### 5. Emergency Management (`EMSTimerManager`, `EmergencyAlarmManager`)
* **Countdown Manager (`EMSTimerManager`):**
  * Manages the 30-second emergency countdown timer.
  * Schedules timer on `RunLoop.main` in `.common` mode to ensure continuous execution during scrolling or UI interactions.
  * **Background Task Integration:** Starts `UIBackgroundTaskIdentifier` (`LifeLoopEmergencyCountdown`) when countdown starts, releasing it when countdown completes or cancels.
  * Posts and clears local time-sensitive notifications (`LOCAL_EMERGENCY_COUNTDOWN`).
  * `synchronizeCallDeadline(_ date: Date)`: Synchronizes countdown deadline with backend response times.
* **Audio & Haptic Alarm (`EmergencyAlarmManager`):**
  * Pre-loads emergency alarm audio track at launch.
  * **Audio Session Management:** Activates `AVAudioSession` with `.playback` category and `.duckOthers` option only when `startAlarm()` is called during active emergencies. Uses iOS `audio` background capability.
  * **Haptic Vibration Loop:** `UIImpactFeedbackGenerator` (.heavy) repeating on a 0.6-second timer.
  * **Cleanup:** `stopAlarm()` halts playback, invalidates haptics, and releases audio session with `.notifyOthersOnDeactivation`.

---

### 6. Family Telemetry, Check-Ins & Synchronization (`FamilyDeviceManager`, `LoopNotifications`)
* **Sign-In Aware Subscriptions:**
  * Validates user sign-in state (`cloud.isSignedIn`) prior to starting cloud uploads or real-time WebSocket subscriptions.
  * `pauseCloudSubscriptions()`: Immediately cancels active check-in and alert GraphQL WebSocket subscriptions when signing out or switching accounts.
* **Exponential Subscription Backoff:**
  * Implements backoff retry logic (starting at 2 seconds up to 30 seconds) when WebSocket subscriptions encounter connection or unauthorized errors. Resets backoff delay to 2 seconds upon successful connection.
* **Telemetry Upload & Caching:**
  * Syncs device telemetry (BPM, state, GPS coordinates, location sharing settings) with AWS AppSync.
  * Caches `linkedDeviceKeys` in memory to perform `linkDevice` GraphQL mutations only once per connection cycle.
* **Reverse Geocoding:** Reverse-geocodes latitude and longitude coordinates into street addresses via `CLGeocoder`.
* **Real-Time Subscriptions & Check-Ins:**
  * `ensureCheckInSubscription()`: Subscribes to `onCheckInChange` WebSocket events.
  * `ensureAlertSubscription()`: Subscribes to `onAlertChange` WebSocket events, passing alert updates to `LoopNotifications`.
  * `requestCheckIn(for:)` / `acknowledgePing(checkInID:)`: Executes `sendPing` and `acknowledgePing` GraphQL mutations.
* **Alert Lifecycle & Cancellation:**
  * `sendMyEmergencyAlert`: Calls AWS AppSync `startEmergency` mutation with stable alert IDs, location coordinates, and dispatch reason.
  * `cancelMyOwnEmergency` / `cancelAlert` / `cancelEmergency`: Calls AWS AppSync `cancelEmergency` mutation.
* **Local Notifications (`LoopNotifications`):**
  * Handles local notification delivery for `FAMILY_ALERT` and `LOCAL_EMERGENCY_COUNTDOWN` categories.
  * Processes `CANCEL_EMERGENCY` notification actions by posting `.lifeLoopCancelEmergencyFromNotification` to dismiss emergency countdowns locally.

---

### 7. Cloud Infrastructure & Networking (`FamilyAPIClient`, AWS Amplify)
Communicates with AWS AppSync GraphQL API backend using Amplify API plugin with AWS Cognito User Pools authorization (`AMAZON_COGNITO_USER_POOLS`).

* **Authentication & Auth Plugin:**
  * User Pool ID: `us-east-2_zO8kdjTEs`
  * App Client ID: `si1qof5nhh76a6gguldcth0nn`
  * Region: `us-east-2`
  * Auth Flow: `USER_SRP_AUTH`
  * Cognito User Attributes: Synchronizes user role (`wearer` / `family`) under the `profile` attribute.

* **GraphQL API Operations (`FamilyAPIClient`):**
  * **Group & Membership Management:** `createFamily`, `joinFamily`, `myFamilies`, `members`, `blockedMembers`, `setRole`, `membershipAction`.
  * **Emergency Call Contacts:** `contacts`, `saveContact` (`addContact` / `updateContact`), `deleteContact`.
  * **Telemetry & Devices:** `linkDevice`, `uploadTelemetry`, `fetchFamilyDevices`.
  * **Alerts & Check-Ins:** `startEmergency`, `cancelEmergency`, `alerts`, `sendPing`, `acknowledgePing`, `subscribeToCheckIns`, `subscribeToAlerts`.

---

### 8. Location Services (`LocationManager`)
* **Location Tracking:** Manages user permissions, continuous CoreLocation positioning updates, and background location updates.
* **Coordinates Integration:** Supplies latitude and longitude for telemetry sync, map rendering, and emergency alert payloads when location sharing is enabled.

---

### 9. Infrastructure & Codebase Optimizations

#### Key Features & Technical Audits
* **Dual User Roles & Wearer Dashboard:** Added role separation with a dedicated Watch Wearer mode for simple device controls, SOS triggers, and battery monitoring.
* **Hardware Sleep Mode Support:** Integrated hardware `Sleeping (6)` state and `"SLEEP"` / `"WAKE"` commands across BLE firmware and iOS central manager.
* **Interactive Lock Screen Cancellation:** Time-sensitive countdown notifications with interactive `CANCEL_EMERGENCY` actions allow users to cancel emergency countdowns from the lock screen.
* **Emergency Backgrounding:** iOS background task protection (`LifeLoopEmergencyCountdown`) ensures countdown timers run reliably if the app is minimized.
* **Caregiver Phone Number Protection:** Contact creation UI includes validation to prevent users from adding their own phone number as an emergency call contact.
* **Dynamic Dark Mode:** Adaptation of `LoopStyle` design system for Light, Dark, and System color schemes.
* **Robust WebSocket Subscription Management:** Automatic pausing on sign-out and exponential backoff retry logic for authorized/unauthorized WebSocket connection drops.
* **Automated Documentation Workflow:** Maintains project documentation automatically via Gemini CLI workflow (`.github/workflows/auto-docs.yml`).
