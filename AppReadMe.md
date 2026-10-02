# LifeLoop iOS App Documentation

## Overview
LifeLoop is an iOS application built with SwiftUI, integrating Bluetooth Low Energy (BLE) hardware connectivity, location services via CoreLocation, and AWS Amplify GraphQL services for family health telemetry monitoring and emergency alert dispatching.

---

## Architecture & Core Components

### 1. Application Lifecycle & Configuration
* **App Initialization (`LifeLoopApp`):** Configures AWS Amplify (Auth and API plugins) and requests user notification authorizations (`.alert`, `.sound`, `.badge`) on app launch.
* **Bundle Identifier:** Configured for development build target `app.ShortCircuit.LifeLoop-dev`.

### 2. UI & User Flows

#### Root View (`ContentView`)
* Manages tab navigation and initial configuration flows (prompts settings setup if age is unconfigured).
* Listens to emergency timer triggers (`EMSTimerManager.isAlertTriggered`) to automatically dispatch emergency alerts for linked devices or fallback local device details.

#### Family Devices (`FamilyDevicesView` & `FamilyMemberDetailView`)
* **Family Device List:** Displays active family devices along with owner names, last updated timestamps, and formatted device states:
  * `EMERGENCY (4)` (highlighted in red)
  * `Fall Detected (2)`
  * `Normal (1)`
  * `Idle (0)`
* **Family Member Detail View:**
  * Shows device telemetry (BPM, state, coordinates, owner details).
  * **Interactive Map:** Displays a SwiftUI `Map` with custom markers (`heart.fill` when online, `heart.slash` when offline) if location sharing is active and coordinates are valid.
  * **Admin Tools:** Provides administrative actions, including requesting EMS alert cancellation for active emergencies.

#### Settings (`SettingsView`)
* **User Profile:** Configures user age.
* **Admin & Permissions:**
  * Toggle for family group administrator status (`isAdminUser`).
  * Toggle to permit remote administrators to cancel EMS calls (`allowRemoteAdminCancel`).

---

### 3. Bluetooth Low Energy Integration (`BLEMonitor`)
* **Peripheral Management:** Handles BLE scanning, connecting, and data streaming from hardware peripherals using `CoreBluetooth`.
* **Immediate Emergency Triggering:** When telemetry indicates a cardiac abnormality or severe fall:
  * Triggers the local countdown timer (`EMSTimerManager`).
  * Immediately dispatches an emergency alert payload (`sendImmediateEmergency`) to AWS AppSync with current coordinates, throttled to prevent duplicate sends within 10 seconds.
  * Posts a local notification confirming immediate EMS alert transmission.

---

### 4. Emergency Management (`EMSTimerManager`)
* **Countdown Manager:** Controls the 30-second emergency countdown timer when cardiac or fall events are detected.
* **Immediate Callback Support:** Provides an `onImmediateTrigger` closure for instant actions upon emergency event initiation.

---

### 5. Family Telemetry & Synchronization (`FamilyDeviceManager`)
* **Telemetry Sync:** Periodically uploads connected device telemetry (BPM, state, location, online status) to the cloud for family group monitoring.
* **Offline Telemetry Updates:** Periodically updates AWS with offline device state for disconnected devices.
* **Offline Queueing & Network Monitoring:**
  * Monitors network reachability via `NWPathMonitor`.
  * Automatically queues failed telemetry uploads and emergency alerts to `UserDefaults` (`com.lifeloop.family.pendingTelemetry` and `com.lifeloop.family.pendingAlerts`).
  * Automatically flushes queued telemetry and alerts once network connectivity is restored.
* **Emergency Detection & Local Notifications:** Monitors telemetry updates for emergency conditions (State 2 fall, State 4 emergency, or critical low BPM between 1 and 40) and issues local user notifications (`UNUserNotificationCenter`).
* **EMS Cancellation:** Allows administrators to issue emergency alert cancellation requests (`cancelEmergency(for:)`) to the backend.
* **Reverse Geocoding:** Converts latitude and longitude coordinates into human-readable street addresses using `CLGeocoder`, with local address caching.

---

### 6. Cloud Infrastructure & Networking (`FamilyAPIClient`)
Communicates with AWS AppSync GraphQL API backend via Amplify API plugin.
* **Telemetry Upload (`uploadTelemetry`):** Sends `FamilyTelemetryPayload` updates.
* **Emergency Alert Dispatch (`sendEmergencyAlert`):** Dispatches `EmergencyAlertPayload` including group code, location, reason, and device metadata.
* **Emergency Cancellation (`cancelEmergencyAlert`):** Sends `CancelEmergencyPayload` mutation to cancel active emergency requests.
* **Device Query (`fetchFamilyDevices`):** Queries current family member device statuses, owner names, telemetry, and locations.

---

### 7. Location Services (`LocationManager`)
* **Location Tracking:** Manages user permissions, continuous position updates, and background GPS positioning.
* **Coordinates Integration:** Supplies real-time latitude and longitude data for telemetry updates and emergency alert dispatches.

---

## Infrastructure & CI/CD Updates

### Automated Documentation
* **Auto-Docs Workflow (`.github/workflows/auto-docs.yml`):** Utilizes `gemini-3.6-flash` model endpoint for automated documentation maintenance upon repository updates.
