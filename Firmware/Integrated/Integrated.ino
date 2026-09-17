#include <ArduinoBLE.h>
#include <Wire.h>
#include <LSM6DS3.h>          // Seeed Arduino LSM6DS3 library
#include "MAX30105.h"
#include <math.h>

// ── BLE Definitions ───────────────────────────────────────────────────────────
#define SERVICE_UUID           "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

BLEService lifeLoopService(SERVICE_UUID);
BLECharacteristic txCharacteristic(CHARACTERISTIC_UUID_TX, BLENotify | BLERead, 32);

// ── Hardware Objects ──────────────────────────────────────────────────────────
LSM6DS3 myIMU(I2C_MODE, 0x6A); // Onboard XIAO nRF52840 Sense IMU (Address 0x6A)
MAX30105 particleSensor;

// ── LED State Tracking ────────────────────────────────────────────────────────
bool ledRedState = true; // Active-LOW (true = HIGH = OFF)

// ── Fall Detection Variables ──────────────────────────────────────────────────
enum FallDetection { Normal, Free_Falling, Impact, Recovering, Emergency };
FallDetection fallState = Normal;
unsigned long fallTime = 0;
unsigned long stationaryTime = 0;
unsigned long recoveryStartTime = 0;
unsigned long stableStartTime = 0;
unsigned long lastBlinkTime = 0;

unsigned long lastMpuReadTime = 0;
const unsigned long MPU_READ_INTERVAL = 20; // 50Hz to catch rapid impacts

float magnitude(float x, float y, float z) {
  return sqrt(x*x + y*y + z*z);
}

// ── Heart Rate Variables (DSP) ────────────────────────────────────────────────
unsigned long lastHrReadTime = 0;
const unsigned long HR_READ_INTERVAL = 5; // 200Hz matches sensor setup

#define MA_SIZE 16
long maBuffer[MA_SIZE] = {0};
int maIndex = 0;
long maSum = 0;
float dcPrev = 0;
float lastFiltered = 0;
long lastBeatTime = 0;
bool descending = false;
float troughValue = 0;

#define TROUGH_HISTORY 5
float troughHistory[TROUGH_HISTORY] = {0};
int troughHistIndex = 0;
int troughHistCount = 0;
float adaptiveThreshold = -40;

#define BPM_BUFFER_SIZE 6
float bpmBuffer[BPM_BUFFER_SIZE] = {0};
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

// ── Edge Filtering Variables ──────────────────────────────────────────────────
float lastSentBPM = -100.0; // Initialized low to force the first transmission
FallDetection lastSentFallState = Normal;
unsigned long lastKeepAliveTime = 0;
const unsigned long KEEP_ALIVE_INTERVAL = 15000; // 15 seconds

// ── Setup ─────────────────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);
  
  pinMode(LED_RED, OUTPUT);
  pinMode(LED_GREEN, OUTPUT);
  pinMode(LED_BLUE, OUTPUT);
  digitalWrite(LED_RED, HIGH);
  digitalWrite(LED_GREEN, HIGH);
  digitalWrite(LED_BLUE, HIGH);

  Wire.begin();

  if (myIMU.begin() != 0) {
    Serial.println("LSM6DS3 IMU Error!");
  }

  if (!particleSensor.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("MAX30105 Error!");
  } else {
    particleSensor.setup(60, 1, 2, 200, 411, 4096);
  }

  if (!BLE.begin()) {
    Serial.println("BLE Initialization Failed!");
    while (1);
  }

  // Generate unique dynamic name
  String mac = BLE.address(); 
  String idSuffix = mac.substring(12, 14) + mac.substring(15, 17);
  idSuffix.toUpperCase();
  String deviceName = "Life Loop " + idSuffix;

  BLE.setLocalName(deviceName.c_str());
  BLE.setAdvertisedService(lifeLoopService);
  lifeLoopService.addCharacteristic(txCharacteristic);
  BLE.addService(lifeLoopService);

  txCharacteristic.writeValue("");
  
  BLE.advertise();
  myIMU.writeRegister(LSM6DS3_ACC_GYRO_CTRL1_XL, 0x4C);
  Serial.println("System Ready. BLE Advertising as: " + deviceName);
}

// ── Main Loop ─────────────────────────────────────────────────────────────────
void loop() {
  BLEDevice central = BLE.central();
  unsigned long now = millis();

  // 1. Process Heart Rate (Gated to 200Hz)
  if (now - lastHrReadTime >= HR_READ_INTERVAL) {
    lastHrReadTime = now;
    
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
  }

  // 2. Process Fall Detection State Machine (Gated to 50Hz)
  if (now - lastMpuReadTime >= MPU_READ_INTERVAL) {
    lastMpuReadTime = now;

    float ax = myIMU.readFloatAccelX() * 9.80665f;
    float ay = myIMU.readFloatAccelY() * 9.80665f;
    float az = myIMU.readFloatAccelZ() * 9.80665f;
    float magValues = magnitude(ax, ay, az);

switch(fallState) {
      case Normal:
        digitalWrite(LED_BLUE, LOW);
        digitalWrite(LED_RED, HIGH);
        digitalWrite(LED_GREEN, HIGH);
        ledRedState = true;
        
        if (magValues < 5.0) { 
          fallTime = now;
          fallState = Free_Falling;
        }
        break;

      case Free_Falling:
        digitalWrite(LED_BLUE, HIGH); 
        if (now - lastBlinkTime >= 150) { 
          lastBlinkTime = now;
          ledRedState = !ledRedState;
          digitalWrite(LED_RED, ledRedState ? HIGH : LOW);
        }
        
        if (magValues > 25.0) {
          stationaryTime = now; 
          fallState = Impact;
        }
        else if (magValues >= 8.0 && magValues <= 11.5 && (now - fallTime > 300)) {
          fallState = Normal; 
        }
        else if (now - fallTime > 800) {
          fallState = Normal;
        }
        break;

case Impact:
        digitalWrite(LED_BLUE, HIGH);
        digitalWrite(LED_RED, LOW); 
        ledRedState = false;

        // DEBOUNCE FIX: Ignore the physical bounce and rattle of the hard plastic 
        // on the floor for 2000ms (2 seconds). 
        if (now - stationaryTime < 2000) {
           break; 
        }
        
        // MOVEMENT DETECTED: Checked ONLY after the 2-second bounce window has closed.
        // If they are getting up, they will still be moving heavily.
        if (magValues > 13.0 || magValues < 6.0) {
          recoveryStartTime = now;
          stableStartTime = now;
          fallState = Recovering; 
        }
        
        // NO MOVEMENT: If they lie perfectly motionless for 6 seconds total
        if (now - stationaryTime >= 6000) {
          fallState = Emergency; 
        }
        break;

      case Recovering:
        // Stay solid red while we evaluate the recovery
        digitalWrite(LED_BLUE, HIGH);
        digitalWrite(LED_RED, LOW); 

        // If they are actively moving (writhing or climbing up), reset the stability timer
        if (magValues > 11.5 || magValues < 8.0) {
          stableStartTime = now;
        }

        // SUCCESS: If they achieve 4 continuous seconds of resting gravity (1G), they are standing/sitting.
        if (now - stableStartTime > 4000) {
          fallState = Normal;
        }

        // FAIL (WRITHING): If 15 seconds pass and they NEVER achieve 4 seconds of stillness, it's an emergency.
        if (now - recoveryStartTime > 15000) {
          fallState = Emergency;
        }
        break;

      case Emergency:
        // SOS Pulse
        if (now - lastBlinkTime >= 500) { 
          lastBlinkTime = now;
          ledRedState = !ledRedState;
          digitalWrite(LED_RED, ledRedState ? HIGH : LOW);
        }
        
        // For prototype testing: A purposeful, violent shake (> 20G) will manually cancel the emergency state
        if (magValues > 20.0) {
          fallState = Normal;
        }
        break;
    }
  }

  // 3. Edge-Filtered BLE Transmission
  bool stateChanged = (fallState != lastSentFallState);
  bool bpmChanged = (abs(currentBPM - lastSentBPM) >= 3.0);
  bool keepAlive = (now - lastKeepAliveTime >= KEEP_ALIVE_INTERVAL);

  if (stateChanged || bpmChanged || keepAlive) {
    lastKeepAliveTime = now;
    lastSentFallState = fallState;
    lastSentBPM = currentBPM;
    
    char msg[32];
    snprintf(msg, sizeof(msg), "BPM:%.1f|State:%d\n", currentBPM, fallState);
    
    Serial.print("Local Data -> ");
    Serial.print(msg);

    // Only broadcast if the central is connected AND subscribed to the characteristic
    if (central && txCharacteristic.subscribed()) {
      txCharacteristic.writeValue(msg);
    }
  }
}