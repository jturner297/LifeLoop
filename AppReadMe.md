# LifeLoop iOS App Documentation

## Overview
LifeLoop is an iOS application built with SwiftUI, integrating Bluetooth Low Energy (BLE) hardware connectivity and location-based services via CoreLocation.

---

## Architecture & Core Components

### 1. SwiftUI Components
* **UI Architecture:** Declarative UI layouts using SwiftUI.
* **State Management:** Reactive updates leveraging `@StateObject`, `@ObservedObject`, and `@Published` properties.

### 2. BLE Integration (`CoreBluetooth`)
* **Peripheral Discovery & Connection:** Handles scanning, connecting, and discovering services/characteristics for hardware peripherals.
* **Data Streaming:** Manages continuous data transmission and state syncing between the iOS device and LifeLoop hardware.

### 3. Location Logic (`LocationManager`)
* **Location Tracking:** Manages user permissions, continuous location updates, and background positioning.
* **Geofencing & Region Monitoring:** Monitors entry/exit events for location-based automation.

---

## Infrastructure & CI/CD Updates

### Automated Documentation
* **Auto-Docs Workflow (`.github/workflows/auto-docs.yml`):** Updated internal Gemini model endpoint to `gemini-3.6-flash` for automated documentation processing.