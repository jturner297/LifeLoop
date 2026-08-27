#include <ArduinoBLE.h>
#include <Wire.h>
#include <LSM6DS3.h>          // Seeed Arduino LSM6DS3 library
#include "MAX30105.h"
#include "heartRate.h"
#include <TinyGPS++.h>
#include <math.h>

// ── BLE Definitions ───────────────────────────────────────────────────────────
#define SERVICE_UUID           "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

BLEService lifeLoopService(SERVICE_UUID);
BLECharacteristic txCharacteristic(CHARACTERISTIC_UUID_TX, BLENotify | BLERead, 128);

unsigned long lastSendTime = 0;
const unsigned long SEND_INTERVAL = 1000;

// ── Hardware Objects ──────────────────────────────────────────────────────────
LSM6DS3 myIMU(I2C_MODE, 0x6A); // Onboard XIAO nRF52840 Sense IMU (Address 0x6A)
MAX30105 particleSensor;
TinyGPSPlus gps;
// Hardware Serial1 on XIAO nRF52840: RX = D7 (P1.12), TX = D6 (P1.11)

// ── Fall Detection Variables ──────────────────────────────────────────────────
enum FallDetection { Normal, Free_Falling, Impact, Stationary };
FallDetection fallState = Normal;
unsigned long fallTime = 0;
unsigned long stationaryTime = 0;
unsigned long stationaryTrack = 0;
unsigned long lastBlinkTime = 0;

unsigned long lastMpuReadTime = 0;
const unsigned long MPU_READ_INTERVAL = 100; 

float magnitude(float x, float y, float z) {
  return sqrt(x*x + y*y + z*z);
}

// ── Heart Rate Variables (DSP) ────────────────────────────────────────────────
#define MA_SIZE 16
long maBuffer[MA_SIZE];
int maIndex = 0;
long maSum = 0;
float dcPrev = 0;
float lastFiltered = 0;
long lastBeatTime = 0;
bool descending = false;
float troughValue = 0;
#define TROUGH_HISTORY 5
float troughHistory[TROUGH_HISTORY];
int troughHistIndex = 0;
int troughHistCount = 0;
float adaptiveThreshold = -40;

#define BPM_BUFFER_SIZE 6
float bpmBuffer[BPM_BUFFER_SIZE];
int bpmIndex = 0;
int bpmCount = 0;
float currentBPM = 0;

long movingAverage(long newVal) {
  maSum -= maBuffer[maIndex];
  maBuffer[maIndex] = newVal;
  maSum += newVal;
  maIndex = (maIndex + 1) % MA_SIZE;
  return maSum / MA_SIZE;
}

float dcRemove(float raw) {
  dcPrev = 0.95 * dcPrev + 0.05 * raw;
  return raw - dcPrev;
}

void updateThreshold(float newTroughDepth) {
  if (newTroughDepth < -500) return;
  troughHistory[troughHistIndex] = newTroughDepth;
  troughHistIndex = (troughHistIndex + 1) % TROUGH_HISTORY;
  if (troughHistCount < TROUGH_HISTORY) troughHistCount++;
  float sum = 0;
  for (int i = 0; i < troughHistCount; i++) sum += troughHistory[i];
  adaptiveThreshold = (sum / troughHistCount) * 0.6;
}

void addBPM(float newBPM) {
  bpmBuffer[bpmIndex] = newBPM;
  bpmIndex = (bpmIndex + 1) % BPM_BUFFER_SIZE;
  if (bpmCount < BPM_BUFFER_SIZE) bpmCount++;
  float sum = 0;
  for (int i = 0; i < bpmCount; i++) sum += bpmBuffer[i];
  currentBPM = sum / bpmCount;
}

void resetHR() {
  lastFiltered = 0; dcPrev = 0; descending = false; troughValue = 0;
  troughHistIndex = 0; troughHistCount = 0; adaptiveThreshold = -40;
  currentBPM = 0;
  for (int i = 0; i < TROUGH_HISTORY; i++) troughHistory[i] = 0;
}

// ── Location & Optimization Variables ─────────────────────────────────────────
float currentLat = 0.0;
float currentLon = 0.0;
float lastCheckedLat = 0.0;
float lastCheckedLon = 0.0;
unsigned long lastLocationCheck = 0;
const unsigned long LOCATION_CHECK_INTERVAL = 30000; 

// Haversine distance formula to check if we moved > 10 meters
float calculateDistance(float lat1, float lon1, float lat2, float lon2) {
  float R = 6371000;
  float dLat = radians(lat2 - lat1);
  float dLon = radians(lon2 - lon1);
  float a = sin(dLat / 2) * sin(dLat / 2) +
            cos(radians(lat1)) * cos(radians(lat2)) *
            sin(dLon / 2) * sin(dLon / 2);
  float c = 2 * atan2(sqrt(a), sqrt(1 - a));
  return R * c;
}

// ── Setup ─────────────────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  
  // 1. Initialize Onboard RGB LED (XIAO LEDs are Active-LOW: HIGH = OFF, LOW = ON)
  pinMode(LED_RED, OUTPUT);
  pinMode(LED_GREEN, OUTPUT);
  pinMode(LED_BLUE, OUTPUT);
  digitalWrite(LED_RED, HIGH);
  digitalWrite(LED_GREEN, HIGH);
  digitalWrite(LED_BLUE, HIGH);

  // 2. Initialize Primary I2C Bus (D4/SDA, D5/SCL)
  Wire.begin();

  // 3. Initialize Onboard LSM6DS3 IMU
  if (myIMU.begin() != 0) {
    Serial.println("LSM6DS3 IMU Error!");
  }

  // 4. Initialize External MAX30105 Heart Rate Sensor
  if (!particleSensor.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("MAX30105 Error!");
  } else {
    particleSensor.setup(60, 1, 2, 200, 411, 4096);
  }

  // 5. Initialize GPS UART (Serial1 on D7=RX, D6=TX)
  Serial1.begin(9600);

  // 6. Initialize ArduinoBLE Stack
  if (!BLE.begin()) {
    Serial.println("BLE Initialization Failed!");
    while (1);
  }

  BLE.setLocalName("Life Loop");
  BLE.setAdvertisedService(lifeLoopService);
  lifeLoopService.addCharacteristic(txCharacteristic);
  BLE.addService(lifeLoopService);

  // Set initial empty value
  txCharacteristic.writeValue("");
  
  BLE.advertise();
  Serial.println("System Ready. BLE Advertising...");
}

// ── Main Loop ─────────────────────────────────────────────────────────────────
void loop() {
  BLEDevice central = BLE.central();
  unsigned long now = millis();

  // 1. Process GPS Data (Non-Blocking via Hardware Serial1)
  while (Serial1.available() > 0) {
    gps.encode(Serial1.read());
  }

  // Check Location & Apply Optimization (Run every 30s)
  if (now - lastLocationCheck >= LOCATION_CHECK_INTERVAL) {
    lastLocationCheck = now;

    float newLat = 0.0;
    float newLon = 0.0;
    bool locationFound = false;

    // Try GPS first (if valid lock exists)
    if (gps.location.isValid() && gps.location.age() < 2000) {
      newLat = gps.location.lat();
      newLon = gps.location.lng();
      locationFound = true;
    } 

    // Cost-Saving Check: Did we move more than 10 meters?
    if (locationFound) {
      float distanceMoved = calculateDistance(lastCheckedLat, lastCheckedLon, newLat, newLon);
      if (distanceMoved > 10.0 || lastCheckedLat == 0.0) {
        currentLat = newLat;
        currentLon = newLon;
        lastCheckedLat = newLat;
        lastCheckedLon = newLon;
        Serial.print("[LOCATION UPDATED] Lat: ");
        Serial.print(currentLat, 6);
        Serial.print(", Lon: ");
        Serial.println(currentLon, 6);
      } else {
        Serial.println("[OPTIMIZATION] Stationary detected. Skipping redundant location update.");
      }
    }
  }

  // 2. Process Heart Rate (DSP Loop)
  long irRaw = particleSensor.getIR();
  if (irRaw < 80000) {
    resetHR();
  } else {
    long smoothed  = movingAverage(irRaw);
    float filtered = dcRemove((float)smoothed);
    
    if (filtered < lastFiltered) {
      descending = true;
      if (filtered < troughValue) troughValue = filtered;
    }

    if (descending && filtered > lastFiltered) {
      if (troughValue < adaptiveThreshold) {
        long delta = now - lastBeatTime;
        if (delta > 400 && delta < 2000) {
          addBPM(60000.0 / delta);
          lastBeatTime = now;
          updateThreshold(troughValue);
        } else if (delta >= 2000) {
          lastBeatTime = now;
          bpmCount = 0; bpmIndex = 0;
          updateThreshold(troughValue);
        }
      }
      descending = false;
      troughValue = 0;
    }
    lastFiltered = filtered;
  }

  // 3. Process Fall Detection State Machine (100ms interval)
  if (now - lastMpuReadTime >= MPU_READ_INTERVAL) {
    lastMpuReadTime = now;

    // Read onboard IMU in Gs and convert to m/s^2 (1G = 9.80665 m/s^2) to match exact thresholds
    float ax = myIMU.readFloatAccelX() * 9.80665f;
    float ay = myIMU.readFloatAccelY() * 9.80665f;
    float az = myIMU.readFloatAccelZ() * 9.80665f;
    float magValues = magnitude(ax, ay, az);

    switch(fallState) {
      case Normal:
        // Blue ON (LOW), Red OFF (HIGH), Green OFF (HIGH)
        digitalWrite(LED_BLUE, LOW);
        digitalWrite(LED_RED, HIGH);
        digitalWrite(LED_GREEN, HIGH);
        if (magValues < 6.0) {
          fallTime = now;
          fallState = Free_Falling;
        }
        break;

      case Free_Falling:
        digitalWrite(LED_BLUE, HIGH); // Ensure Blue is OFF
        if (now - lastBlinkTime >= 300) {
          lastBlinkTime = now;
          digitalWrite(LED_RED, !digitalRead(LED_RED));
        }
        
        if (now - fallTime > 500) {
          fallState = Normal;
        }
        else if (magValues > 9.0 && now - fallTime < 80) {
          fallState = Normal; 
        }
        else if (magValues > 15.0 && (now - fallTime >= 80)) {
          stationaryTime = now;
          fallState = Impact;
        }
        break;

      case Impact:
        // Blue OFF (HIGH), Red ON (LOW)
        digitalWrite(LED_BLUE, HIGH);
        digitalWrite(LED_RED, LOW);
        
        if (magValues > 11.0 && magValues < 13.0) {
          fallState = Normal; 
        }
        if (now - stationaryTime >= 6000) {
          stationaryTrack = now;
          fallState = Stationary;
        }
        break;

      case Stationary:
        if (now - lastBlinkTime >= 1000) {
          lastBlinkTime = now;
          digitalWrite(LED_RED, !digitalRead(LED_RED));
        }
        if (now - stationaryTrack >= 10000) {
          digitalWrite(LED_RED, HIGH); // Turn Red OFF
          fallState = Normal;
        }
        break;
    }
  }

  // 4. Send Data over BLE
  if (now - lastSendTime >= SEND_INTERVAL) {
    lastSendTime = now;
    
    char msg[128];
    snprintf(msg, sizeof(msg), "BPM:%.1f|State:%d|Lat:%.6f|Lon:%.6f\n", 
             currentBPM, fallState, currentLat, currentLon);
    
    Serial.print("Local Data -> ");
    Serial.print(msg);

    // Notify connected BLE central
    if (central && central.connected()) {
      txCharacteristic.writeValue(msg);
    }
  }
}