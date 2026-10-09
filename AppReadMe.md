# LifeLoop iOS App Documentation

## Overview
LifeLoop is an iOS application built with SwiftUI, integrating Bluetooth Low Energy (BLE) hardware connectivity, location services via CoreLocation, and AWS Amplify GraphQL services for family health telemetry monitoring and emergency alert dispatching.

---

## Architecture & Core Components

### 1. Application Lifecycle, Configuration & Role Management
* **App Entry Point (`LifeLoopApp`):** Initializes the application, configures AWS Amplify (Auth and API plugins), requests notification authorizations (`.alert`, `.sound`, `.badge`), and injects `BLEMonitor` into the environment while hosting `AppRootView`.
* **Role-Based Navigation (`AppRootView` & `RoleSelectionView`):**
  * Persists role configuration in `@AppStorage("userRole")` (`UserRole`: `.unassigned`, `.wearer`, `.family`).
  * On initial launch or role reset, presents `RoleSelectionView` to designate device usage:
    * **Wearer Role (`.wearer`):** Directs to `WearerDashboardView` for health telemetry tracking and emergency triggering.
    * **Family Member Role (`.family`):** Directs to `ContentView` for caregiver telemetry monitoring, device management, and map tracking.
* **Bundle Identifier:** Configured for development target `app.ShortCircuit.LifeLoop-dev-local`.

---

### 2. UI & User Flows

#### Role Selection (`RoleSelectionView`)
* Prompts initial setup choices:
  * **"I am the wearer"**: Configures app role as `.wearer`.
  * **"I am a family member"**: Configures app role as `.family`.

#### Wearer Dashboard (`WearerDashboardView`)
Dedicated primary view for band wearers and patients:
* **Hardware Status Bar:** Header showing real-time BLE connectivity status for the wearer's band.
* **Dynamic Content Cards:**
  * **Pairing List:** Displays nearby discovered BLE peripherals when no known device is configured.
  * **Troubleshooting Card:** Displays actionable instructions (charging, proximity, Bluetooth settings) when a saved device is disconnected, with a manual "Tap to Reconnect" trigger.
  * **Vitals Panel:** Displays heart rate (BPM) with an animated pulsing icon, calculated age-based Tachycardia trigger threshold (`220 - age`), dynamic band battery level, last sync time, and reverse-geocoded location address.
* **Manual SOS Trigger:** A prominent circular "CALL HELP" button with heavy haptic feedback that instantly triggers the emergency countdown timer (`EMSTimerManager`) and dispatches an `SOS` command payload to connected hardware via BLE.
* **Active Emergency Screen:** Displays active emergency confirmation once triggered. Provides a "False Alarm - Cancel Alert" action that retracts the emergency alert through `FamilyDeviceManager`, transmits a hardware cancel command via BLE, and cancels local alarms.
* **Critical Battery Overlay:** Displays a full-screen alert overlay when the connected band's battery drops to 10% or below, advising the user to charge the device immediately.
* **Wearer Settings:** Toolbar menu provides age calibration via `WearerSetupSheet` or role reassignment ("Switch to Caregiver").

#### Family Caregiver Dashboard (`ContentView`)
Primary interface for family members and caregivers:
* **Tab Navigation:** Switch between Family Devices dashboard, Family Map, and local device setup.
* **Caregiver Emergency Notifications:** Listens for telemetry updates across family devices and presents an immediate high-priority alert dialog (`.alert("EMERGENCY")`) when a monitored member's device enters State 4 (Emergency), displaying member display name and coordinates.
* **Family Device List (`FamilyDevicesView` & `FamilyMemberDetailView`):**
  * Displays family group devices, owner display names, last update timestamps, battery levels, and formatted states (`EMERGENCY (4)` in red, `Fall Detected (2)`, `Normal (1)`, `Idle (0)`).
  * Detail view displays telemetry metrics, reverse-geocoded address, administrative emergency cancellation tools, and interactive SwiftUI `Map` with custom markers (`heart.fill` online, `heart.slash` offline).
* **Map Screen (`MapScreen`):** Displays current user location alongside monitored family device locations.

#### Settings (`SettingsView`)
* **Emergency Threshold Setup:** Configures user age using an interactive wheel picker (`Picker` with `.wheel` style). Dynamically displays the calculated Tachycardia Auto-Trigger threshold (`220 - userAge` BPM).
* **Admin & Permissions:**
  * Toggle for family group administrator status (`isAdminUser`).
  * Toggle to allow remote administrators to cancel local EMS calls (`allowRemoteAdminCancel`).
* **Role Reset:** Includes a destructive button ("Reset App Role (Switch to Patient)") that sets `userRole` to `unassigned` and returns the application to `RoleSelectionView`.

---

### 3. Bluetooth Low Energy Integration (`BLEMonitor`)
* **Peripheral Management:** Discovers, connects to, and receives data from hardware peripherals using `CoreBluetooth`.
* **Command Transmission & Safeguards:**
  * Uses confirmed write commands (`.withResponse`) to transmit payload data to the peripheral RX characteristic.
  * `sendSOSCommand()`: Transmits `"SOS"` command payload to hardware peripherals.
  * `sendCancelCommand()`: Transmits `"CANCEL"` command payload to hardware peripherals.
  * Tracks `lastCommandSentAt` timestamp to prevent normal incoming telemetry from overriding manual emergency actions within 35 seconds.
* **Emergency Trigger Handling:**
  * Parses telemetry payloads for cardiac abnormalities (BPM 1–40) or severe falls (State 4).
  * Evaluates `EMSTimerManager.shared.isActive` and `isAlertTriggered` prior to starting countdowns to avoid repeatedly resetting active 30-second timers.

---

### 4. Emergency Management (`EMSTimerManager` & `EmergencyAlarmManager`)
* **Countdown Timer (`EMSTimerManager`):** Manages the 30-second emergency countdown (`EMSCountdown`) when hardware fall detection, cardiac abnormality, or manual SOS is triggered.
* **Audio & Visual Alerts:** Plays alarm audio (`Danger Alarm Sound Effect.mp3`) and triggers countdown screen visual animations (`HexagonGrid`, `MarqueeText`).

---

### 5. Family Telemetry & Synchronization (`FamilyDeviceManager`)
* **Telemetry Synchronization:** Uploads device heart rate, state, battery percentage, location coordinates, and online status to AWS AppSync backend.
* **Wearer Emergency Cancellation:** `cancelMyOwnEmergency(deviceID:displayName:)` allows wearers to send a `CancelEmergencyPayload` to revoke active false alarm emergency dispatches.
* **Offline Queueing & Network Monitoring:**
  * Uses `NWPathMonitor` for network reachability tracking.
  * Automatically queues failed telemetry uploads and emergency dispatches/cancellations in `UserDefaults` (`com.lifeloop.family.pendingTelemetry` and `com.lifeloop.family.pendingAlerts`).
  * Automatically flushes pending queues once connectivity is restored.
* **Emergency Event Processing:** Evaluates device states (State 2 Fall, State 4 Emergency, or critical BPM ranges) and dispatches local system notifications (`UNUserNotificationCenter`).
* **Reverse Geocoding:** Translates latitude/longitude coordinates to street addresses via `CLGeocoder`.

---

### 6. Cloud Infrastructure & Networking (`FamilyAPIClient`)
Interacts with the AWS AppSync GraphQL API backend via the Amplify API plugin:
* **Telemetry Upload (`uploadTelemetry`):** Sends `FamilyTelemetryPayload` updates.
* **Emergency Alert Dispatch (`sendEmergencyAlert`):** Dispatches `EmergencyAlertPayload` including group code, device ID, display name, location coordinates, reason, and timestamp.
* **Emergency Cancellation (`cancelEmergencyAlert`):** Dispatches `CancelEmergencyPayload` mutation to rescind active emergency calls.
* **Device Query (`fetchFamilyDevices`):** Queries current telemetry, status, location, and owner details for devices in the family group.

---

### 7. Location Services (`LocationManager`)
* **Location Tracking:** Manages location permission requests, continuous coordinate updates, and background location services.
* **Telemetry & Dispatch Integration:** Supplies latitude and longitude coordinates for telemetry sync, emergency alerts, map rendering, and reverse geocoding.

---

### 8. Data Models

#### `LifeLoopState`
Represents raw telemetry state received from BLE hardware:
* `bpm`: Heart rate measurement (Float, default: `0`).
* `state`: Device operational state integer (default: `0`).
* `battery`: Hardware battery level percentage (Int, default: `100`).
* `latitude` / `longitude`: Location coordinates (Double, default: `0`).

---

## Infrastructure & CI/CD Updates

### Automated Documentation
* **Auto-Docs Workflow (`.github/workflows/auto-docs.yml`):** Utilizes `gemini-3.6-flash` model endpoint for automated documentation maintenance upon repository updates.
