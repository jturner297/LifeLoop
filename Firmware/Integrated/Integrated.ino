#include <ArduinoBLE.h>
#include <Wire.h>
#include <LSM6DS3.h>          // Seeed Arduino LSM6DS3 library
#include "MAX30105.h"
#include <math.h>

// ── Hardware Definitions ──────────────────────────────────────────────────────
#define BUTTON_PIN D1

// ── BLE Definitions ───────────────────────────────────────────────────────────
#define SERVICE_UUID           "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_RX "6E400002-B5A3-F393-E0A9-E50E24DCCA9E" // Added RX UUID

BLEService lifeLoopService(SERVICE_UUID);
BLECharacteristic txCharacteristic(CHARACTERISTIC_UUID_TX, BLENotify | BLERead, 32);
// BLEWriteWithoutResponse ensures the phone doesn't wait for an acknowledgment packet, making it instant
BLECharacteristic rxCharacteristic(CHARACTERISTIC_UUID_RX, BLEWrite | BLEWriteWithoutResponse, 32); 

// ── Hardware Objects ──────────────────────────────────────────────────────────
LSM6DS3 myIMU(I2C_MODE, 0x6A); 
MAX30105 particleSensor;

// ── LED State Tracking ────────────────────────────────────────────────────────
bool ledRedState = true; 

// ── Fall Detection Parameters & Thresholds ────────────────────────────────────
const float FREE_FALL_THRESHOLD    = 5.0f;     
const float IMPACT_ACCEL_THRESHOLD = 24.5f;    
const float IMPACT_GYRO_THRESHOLD  = 60.0f;    

const unsigned long FREE_FALL_TIMEOUT      = 800;  
const unsigned long POST_IMPACT_SETTLE     = 1500; 
const unsigned long OBSERVATION_WINDOW     = 4000; 
const unsigned long STILLNESS_EMERGENCY_TH = 6000; 
const unsigned long CANCEL_HOLD_TIME       = 2000; 

enum FallDetection { Normal, Free_Falling, Impact, Recovering, Emergency };
FallDetection fallState = Normal;

unsigned long fallStartTime = 0;
unsigned long impactTime = 0;
unsigned long observationStartTime = 0;
unsigned long lastBlinkTime = 0;
unsigned long buttonPressStartTime = 0; 

unsigned long lastMpuReadTime = 0;
const unsigned long MPU_READ_INTERVAL = 20; 

float magnitude(float x, float y, float z) {
  return sqrt(x*x + y*y + z*z);
}

// ── Heart Rate Variables (DSP) ────────────────────────────────────────────────
unsigned long lastHrReadTime = 0;
const unsigned long HR_READ_INTERVAL = 5; 

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
float lastSentBPM = -100.0;
FallDetection lastSentFallState = Normal;
unsigned long lastKeepAliveTime = 0;
const unsigned long KEEP_ALIVE_INTERVAL = 15000;

// ── Setup ─────────────────────────────────────────────────────────────────────
void setup() {
  pinMode(LED_RED, OUTPUT);
  pinMode(LED_GREEN, OUTPUT);
  pinMode(LED_BLUE, OUTPUT);
  digitalWrite(LED_RED, HIGH);
  digitalWrite(LED_GREEN, HIGH);
  digitalWrite(LED_BLUE, HIGH);

  pinMode(BUTTON_PIN, INPUT_PULLUP);
  Wire.begin();

  myIMU.begin();

  if (particleSensor.begin(Wire, I2C_SPEED_FAST)) {
    particleSensor.setup(60, 1, 2, 200, 411, 4096);
  }

  if (!BLE.begin()) {
    while (1);
  }

  String mac = BLE.address(); 
  String idSuffix = mac.substring(12, 14) + mac.substring(15, 17);
  idSuffix.toUpperCase();
  String deviceName = "Life Loop " + idSuffix;

  BLE.setLocalName(deviceName.c_str());
  BLE.setAdvertisedService(lifeLoopService);
  lifeLoopService.addCharacteristic(txCharacteristic);
  lifeLoopService.addCharacteristic(rxCharacteristic); // Attached new characteristic
  BLE.addService(lifeLoopService);

  txCharacteristic.writeValue("");
  BLE.advertise();
  
  myIMU.writeRegister(LSM6DS3_ACC_GYRO_CTRL1_XL, 0x4C); 
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

  // 2. Process Fall Detection Pipeline (Gated to 50Hz)
  if (now - lastMpuReadTime >= MPU_READ_INTERVAL) {
    lastMpuReadTime = now;

    float ax = myIMU.readFloatAccelX() * 9.80665f;
    float ay = myIMU.readFloatAccelY() * 9.80665f;
    float az = myIMU.readFloatAccelZ() * 9.80665f;
    float accMag = magnitude(ax, ay, az);

    float gx = myIMU.readFloatGyroX();
    float gy = myIMU.readFloatGyroY();
    float gz = myIMU.readFloatGyroZ();
    float gyroMag = magnitude(gx, gy, gz);

    switch(fallState) {
      case Normal:
        digitalWrite(LED_BLUE, LOW);  
        digitalWrite(LED_RED, HIGH);
        digitalWrite(LED_GREEN, HIGH);
        ledRedState = true;
        buttonPressStartTime = 0; 
        
        if (accMag < FREE_FALL_THRESHOLD) { 
          fallStartTime = now;
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
        
        if (accMag > IMPACT_ACCEL_THRESHOLD || (accMag > 18.0f && gyroMag > IMPACT_GYRO_THRESHOLD)) {
          impactTime = now; 
          fallState = Impact;
        }
        else if (now - fallStartTime > FREE_FALL_TIMEOUT) {
          fallState = Normal;
        }
        break;

      case Impact:
        digitalWrite(LED_BLUE, HIGH);
        digitalWrite(LED_RED, LOW); 
        ledRedState = false;

        if (now - impactTime >= POST_IMPACT_SETTLE) {
          observationStartTime = now;
          fallState = Recovering; 
        }
        break;

      case Recovering:
        digitalWrite(LED_BLUE, HIGH);
        digitalWrite(LED_RED, LOW); 

        if (digitalRead(BUTTON_PIN) == LOW) {
          if (buttonPressStartTime == 0) {
            buttonPressStartTime = now; 
          } else if (now - buttonPressStartTime >= CANCEL_HOLD_TIME) {
            fallState = Normal; 
            buttonPressStartTime = 0;
          }
        } else {
          buttonPressStartTime = 0; 
          
          if (now - observationStartTime >= OBSERVATION_WINDOW) {
            fallState = Emergency; 
          }
        }
        break;

      case Emergency:
        digitalWrite(LED_BLUE, HIGH);
        digitalWrite(LED_GREEN, HIGH);

        if (now - lastBlinkTime >= 500) { 
          lastBlinkTime = now;
          ledRedState = !ledRedState;
          digitalWrite(LED_RED, ledRedState ? HIGH : LOW);
        }
        
        if (digitalRead(BUTTON_PIN) == LOW) {
          if (buttonPressStartTime == 0) {
            buttonPressStartTime = now; 
          } else if (now - buttonPressStartTime >= CANCEL_HOLD_TIME) {
            fallState = Normal; 
            buttonPressStartTime = 0;
          }
        } else {
          buttonPressStartTime = 0; 
        }
        break;
    }
  }

  // 3. Listen for iOS Commands (Inserted exactly per software team specs)
  if (rxCharacteristic.written()) {
    int length = rxCharacteristic.valueLength();
    const uint8_t* val = rxCharacteristic.value();
    String command = "";
    for (int i = 0; i < length; i++) {
      command += (char)val[i];
    }
    
    // Trim handles any stray newline characters iOS might append
    command.trim(); 
    
    if (command == "CANCEL") {
      fallState = Normal;
    }
  }

  // 4. Edge-Filtered BLE Transmission
  bool stateChanged = (fallState != lastSentFallState);
  bool bpmChanged = (abs(currentBPM - lastSentBPM) >= 3.0);
  bool keepAlive = (now - lastKeepAliveTime >= KEEP_ALIVE_INTERVAL);

  if (stateChanged || bpmChanged || keepAlive) {
    lastKeepAliveTime = now;
    lastSentFallState = fallState;
    lastSentBPM = currentBPM;
    
    char msg[32];
    snprintf(msg, sizeof(msg), "BPM:%.1f|State:%d\n", currentBPM, fallState);

    if (central && txCharacteristic.subscribed()) {
      txCharacteristic.writeValue(msg);
    }
  }
}