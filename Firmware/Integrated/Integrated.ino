#include <ArduinoBLE.h>
#include <Wire.h>
#include <LSM6DS3.h>          // Seeed Arduino LSM6DS3 library
#include "MAX30105.h"
#include <math.h>
#include <string.h>

// ── Hardware Definitions ──────────────────────────────────────────────────────
#define BUTTON_PIN D1
#define MOTOR_PIN  D2         // MOSFET Gate for Vibration Motor

// ── Battery Settings ──────────────────────────────────────────────────────────
#define ADC_MAX             4095.0f
#define ADC_REF_VOLTS       3.3f      // AR_INTERNAL_3_0
#define DIVIDER_RATIO       3.033f    // (1M + 510k) / 510k, tweak with a multimeter
const unsigned long BATTERY_INTERVAL    = 30000;  // read battery every 30 s
const unsigned long BATTERY_SETTLE_TIME = 10;     // 10 ms non-blocking divider settle time

// ── BLE Definitions ───────────────────────────────────────────────────────────
#define SERVICE_UUID           "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_RX "6E400002-B5A3-F393-E0A9-E50E24DCCA9E" 

BLEService lifeLoopService(SERVICE_UUID);
BLECharacteristic txCharacteristic(CHARACTERISTIC_UUID_TX, BLENotify | BLERead, 32);
BLECharacteristic rxCharacteristic(CHARACTERISTIC_UUID_RX, BLEWrite | BLEWriteWithoutResponse, 32); 

// ── Hardware Objects ──────────────────────────────────────────────────────────
LSM6DS3 myIMU(I2C_MODE, 0x6A); 
MAX30105 particleSensor;

// ── LED State Tracking ────────────────────────────────────────────────────────
bool ledRedState = true; 

// ── Fall Detection Parameters & Thresholds ────────────────────────────────────
constexpr float G_TO_MS2               = 9.80665f;
constexpr float G_TO_MS2_SQ            = G_TO_MS2 * G_TO_MS2;

constexpr float FREE_FALL_THRESHOLD    = 5.0f;     
constexpr float IMPACT_ACCEL_THRESHOLD = 24.5f;    
constexpr float COMBO_ACCEL_THRESHOLD  = 18.0f;
constexpr float IMPACT_GYRO_THRESHOLD  = 60.0f;    

// Pre-squared thresholds to avoid sqrtf() in the 50 Hz loop
constexpr float FREE_FALL_TH_SQ        = FREE_FALL_THRESHOLD * FREE_FALL_THRESHOLD;
constexpr float IMPACT_ACCEL_TH_SQ     = IMPACT_ACCEL_THRESHOLD * IMPACT_ACCEL_THRESHOLD;
constexpr float COMBO_ACCEL_TH_SQ      = COMBO_ACCEL_THRESHOLD * COMBO_ACCEL_THRESHOLD;
constexpr float IMPACT_GYRO_TH_SQ      = IMPACT_GYRO_THRESHOLD * IMPACT_GYRO_THRESHOLD;

const unsigned long FREE_FALL_TIMEOUT      = 800;  
const unsigned long POST_IMPACT_SETTLE     = 1500; 
const unsigned long OBSERVATION_WINDOW     = 4000; 
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

inline float magnitudeSq(float x, float y, float z) {
  return x * x + y * y + z * z;
}

bool checkCancelButton(unsigned long now) {
  if (digitalRead(BUTTON_PIN) == LOW) {
    if (buttonPressStartTime == 0) {
      buttonPressStartTime = now;
    } else if (now - buttonPressStartTime >= CANCEL_HOLD_TIME) {
      fallState = Normal;
      digitalWrite(MOTOR_PIN, LOW); // Force motor OFF immediately
      buttonPressStartTime = 0;
      return true;
    }
  } else {
    buttonPressStartTime = 0;
  }
  return false;
}

// ── Battery ───────────────────────────────────────────────────────────────────
int batteryPct = 0;
unsigned long lastBatteryTime = 0;
unsigned long batterySettleStart = 0;
bool batterySampling = false;

float sampleBatteryADC() {
  uint32_t sum = 0;
  for (int i = 0; i < 16; i++) {
    sum += analogRead(PIN_VBAT);
  }
  digitalWrite(PIN_VBAT_ENABLE, HIGH);   // disable divider to save power

  constexpr float scale = (ADC_REF_VOLTS / ADC_MAX) * DIVIDER_RATIO / 16.0f;
  return sum * scale;
}

float readBatteryVoltageBlocking() {
  digitalWrite(PIN_VBAT_ENABLE, LOW);    // enable divider (active LOW)
  delay(BATTERY_SETTLE_TIME);
  return sampleBatteryADC();
}

// Approximate single-cell LiPo discharge curve (voltage -> %)
int batteryPercent(float v) {
  static const float volts[] = {3.30f, 3.50f, 3.60f, 3.70f, 3.75f, 3.80f, 3.90f, 4.00f, 4.10f, 4.20f};
  static const int   pct[]   = {    0,     5,    10,    20,    30,    40,    60,    75,    90,   100};
  const int n = sizeof(volts) / sizeof(volts[0]);

  if (v <= volts[0])   return 0;
  if (v >= volts[n-1]) return 100;

  for (int i = 1; i < n; i++) {
    if (v <= volts[i]) {
      float t = (v - volts[i-1]) / (volts[i] - volts[i-1]);
      return (int)(pct[i-1] + t * (pct[i] - pct[i-1]));
    }
  }
  return 0;
}

// ── Heart Rate Variables (DSP) ────────────────────────────────────────────────
#define MA_SIZE 16
long maBuffer[MA_SIZE] = {0};
uint8_t maIndex = 0;
long maSum = 0;
float dcPrev = 0.0f;
float lastFiltered = 0.0f;
unsigned long lastBeatTime = 0;
bool descending = false;
float troughValue = 0.0f;
bool hrActive = false;

#define TROUGH_HISTORY 5
float troughHistory[TROUGH_HISTORY] = {0};
int troughHistIndex = 0;
int troughHistCount = 0;
float adaptiveThreshold = -40.0f;

#define BPM_BUFFER_SIZE 6
float bpmBuffer[BPM_BUFFER_SIZE] = {0};
int bpmIndex = 0;
int bpmCount = 0;
float currentBPM = 0.0f;

long movingAverage(long newVal) {
  maSum -= maBuffer[maIndex];
  maBuffer[maIndex] = newVal;
  maSum += newVal;
  maIndex = (maIndex + 1) & (MA_SIZE - 1);
  return maSum / MA_SIZE;
}

float dcRemove(float raw) {
  dcPrev = 0.95f * dcPrev + 0.05f * raw;
  return raw - dcPrev;
}

void updateThreshold(float newTroughDepth) {
  if (newTroughDepth < -500.0f) return;
  troughHistory[troughHistIndex] = newTroughDepth;
  troughHistIndex = (troughHistIndex + 1) % TROUGH_HISTORY;
  if (troughHistCount < TROUGH_HISTORY) troughHistCount++;
  float sum = 0.0f;
  for (int i = 0; i < troughHistCount; i++) sum += troughHistory[i];
  adaptiveThreshold = (sum / troughHistCount) * 0.6f;
}

void addBPM(float newBPM) {
  bpmBuffer[bpmIndex] = newBPM;
  bpmIndex = (bpmIndex + 1) % BPM_BUFFER_SIZE;
  if (bpmCount < BPM_BUFFER_SIZE) bpmCount++;
  float sum = 0.0f;
  for (int i = 0; i < bpmCount; i++) sum += bpmBuffer[i];
  currentBPM = sum / bpmCount;
}

void resetHR() {
  if (!hrActive) return;
  hrActive = false;
  maSum = 0;
  maIndex = 0;
  memset(maBuffer, 0, sizeof(maBuffer));
  lastFiltered = 0.0f;
  dcPrev = 0.0f;
  descending = false;
  troughValue = 0.0f;
  troughHistIndex = 0;
  troughHistCount = 0;
  adaptiveThreshold = -40.0f;
  memset(troughHistory, 0, sizeof(troughHistory));
  bpmIndex = 0;
  bpmCount = 0;
  currentBPM = 0.0f;
  memset(bpmBuffer, 0, sizeof(bpmBuffer));
}

// ── Edge Filtering Variables ──────────────────────────────────────────────────
float lastSentBPM = -100.0f;
int lastSentBattery = -100;
FallDetection lastSentFallState = Normal;
unsigned long lastKeepAliveTime = 0;
const unsigned long KEEP_ALIVE_INTERVAL = 15000;

// ── Setup ─────────────────────────────────────────────────────────────────────
void setup() {
  Serial.begin(115200);

  pinMode(LED_RED, OUTPUT);
  pinMode(LED_GREEN, OUTPUT);
  pinMode(LED_BLUE, OUTPUT);
  digitalWrite(LED_RED, HIGH);
  digitalWrite(LED_GREEN, HIGH);
  digitalWrite(LED_BLUE, HIGH);

  pinMode(BUTTON_PIN, INPUT_PULLUP);
  
  // Initialize Vibration Motor (Active-High via N-Channel MOSFET)
  pinMode(MOTOR_PIN, OUTPUT);
  digitalWrite(MOTOR_PIN, LOW); // Ensure motor starts OFF

  // Battery ADC setup
  pinMode(PIN_VBAT_ENABLE, OUTPUT);
  digitalWrite(PIN_VBAT_ENABLE, HIGH);   // divider off by default
  analogReadResolution(12);             
  batteryPct = batteryPercent(readBatteryVoltageBlocking());
  lastBatteryTime = millis();

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

  BLE.setDeviceName(deviceName.c_str());
  BLE.setLocalName(deviceName.c_str());

  BLE.setAdvertisedService(lifeLoopService);
  lifeLoopService.addCharacteristic(txCharacteristic);
  lifeLoopService.addCharacteristic(rxCharacteristic);
  BLE.addService(lifeLoopService);

  txCharacteristic.writeValue("");
  BLE.advertise();
  
  myIMU.writeRegister(LSM6DS3_ACC_GYRO_CTRL1_XL, 0x4C); 
}

// ── Main Loop ─────────────────────────────────────────────────────────────────
void loop() {
  BLEDevice central = BLE.central();
  unsigned long now = millis();

  // 0. Non-blocking periodic battery reading
  if (!batterySampling && (now - lastBatteryTime >= BATTERY_INTERVAL)) {
    lastBatteryTime = now;
    batterySettleStart = now;
    batterySampling = true;
    digitalWrite(PIN_VBAT_ENABLE, LOW); // Enable divider; wait 10 ms before sampling
  } else if (batterySampling && (now - batterySettleStart >= BATTERY_SETTLE_TIME)) {
    batterySampling = false;
    float v = sampleBatteryADC();
    batteryPct = batteryPercent(v);

    Serial.print("Battery: ");
    Serial.print(v, 2);
    Serial.print(" V  ");
    Serial.print(batteryPct);
    Serial.println("%");
  }

  // 1. Process Heart Rate (Non-blocking FIFO drain)
  particleSensor.check();
  while (particleSensor.available()) {
    uint32_t irRaw = particleSensor.getFIFOIR();
    particleSensor.nextSample();
    now = millis();

    if (irRaw < 80000) {
      resetHR();
    } else {
      hrActive = true;
      long smoothed  = movingAverage((long)irRaw);
      float filtered = dcRemove((float)smoothed);
      
      if (filtered < lastFiltered) {
        descending = true;
        if (filtered < troughValue) troughValue = filtered;
      }

      if (descending && filtered > lastFiltered) {
        if (troughValue < adaptiveThreshold) {
          unsigned long delta = now - lastBeatTime;
          if (delta > 400 && delta < 2000) {
            addBPM(60000.0f / (float)delta);
            lastBeatTime = now;
            updateThreshold(troughValue);
          } else if (delta >= 2000) {
            lastBeatTime = now;
            bpmCount = 0;
            bpmIndex = 0;
            updateThreshold(troughValue);
          }
        }
        descending = false;
        troughValue = 0.0f;
      }
      lastFiltered = filtered;
    }
  }

  // 2. Process Fall Detection Pipeline
  if (now - lastMpuReadTime >= MPU_READ_INTERVAL) {
    lastMpuReadTime = now;

    switch(fallState) {
      case Normal: {
        digitalWrite(LED_BLUE, LOW);  
        digitalWrite(LED_RED, HIGH);
        digitalWrite(LED_GREEN, HIGH);
        digitalWrite(MOTOR_PIN, LOW);   // Turn off the vibration motor
        ledRedState = true;
        buttonPressStartTime = 0; 

        float ax = myIMU.readFloatAccelX();
        float ay = myIMU.readFloatAccelY();
        float az = myIMU.readFloatAccelZ();
        float accMagSq = magnitudeSq(ax, ay, az) * G_TO_MS2_SQ;
        
        if (accMagSq < FREE_FALL_TH_SQ) { 
          fallStartTime = now;
          fallState = Free_Falling;
        }
        break;
      }

      case Free_Falling: {
        digitalWrite(LED_BLUE, HIGH); 
        if (now - lastBlinkTime >= 150) { 
          lastBlinkTime = now;
          ledRedState = !ledRedState;
          digitalWrite(LED_RED, ledRedState ? HIGH : LOW);
        }

        float ax = myIMU.readFloatAccelX();
        float ay = myIMU.readFloatAccelY();
        float az = myIMU.readFloatAccelZ();
        float accMagSq = magnitudeSq(ax, ay, az) * G_TO_MS2_SQ;

        bool impactDetected = (accMagSq > IMPACT_ACCEL_TH_SQ);
        if (!impactDetected && accMagSq > COMBO_ACCEL_TH_SQ) {
          // Only read gyroscope over I2C when acceleration is in the combo window
          float gx = myIMU.readFloatGyroX();
          float gy = myIMU.readFloatGyroY();
          float gz = myIMU.readFloatGyroZ();
          float gyroMagSq = magnitudeSq(gx, gy, gz);
          impactDetected = (gyroMagSq > IMPACT_GYRO_TH_SQ);
        }
        
        if (impactDetected) {
          impactTime = now; 
          fallState = Impact;
        } else if (now - fallStartTime > FREE_FALL_TIMEOUT) {
          fallState = Normal;
        }
        break;
      }

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

        if (!checkCancelButton(now) && buttonPressStartTime == 0) {
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
          digitalWrite(MOTOR_PIN, ledRedState ? LOW : HIGH);
        }
        
        checkCancelButton(now);
        break;
    }
  }

  // 3. Listen for iOS Commands (Zero-allocation parsing)
  if (rxCharacteristic.written()) {
    int length = rxCharacteristic.valueLength();
    const char* val = (const char*)rxCharacteristic.value();

    // Trim leading whitespace
    while (length > 0 && (*val == ' ' || *val == '\r' || *val == '\n' || *val == '\t')) {
      val++;
      length--;
    }
    // Trim trailing whitespace/nulls
    while (length > 0 && (val[length - 1] == ' ' || val[length - 1] == '\r' || val[length - 1] == '\n' || val[length - 1] == '\t' || val[length - 1] == '\0')) {
      length--;
    }

    if (length == 6 && strncmp(val, "CANCEL", 6) == 0) {
      fallState = Normal;
      digitalWrite(MOTOR_PIN, LOW);   // Force motor pin LOW immediately upon BLE cancel
      buttonPressStartTime = 0;
    }
  }

  // 4. Edge-Filtered BLE Transmission
  if (central && txCharacteristic.subscribed()) {
    bool stateChanged   = (fallState != lastSentFallState);
    bool bpmChanged     = (fabsf(currentBPM - lastSentBPM) >= 3.0f);
    bool batteryChanged = (abs(batteryPct - lastSentBattery) >= 2);
    bool keepAlive      = (now - lastKeepAliveTime >= KEEP_ALIVE_INTERVAL);

    if (stateChanged || bpmChanged || batteryChanged || keepAlive) {
      lastKeepAliveTime = now;
      lastSentFallState = fallState;
      lastSentBPM = currentBPM;
      lastSentBattery = batteryPct;
      
      char msg[32];
      snprintf(msg, sizeof(msg), "BPM:%.1f|State:%d|Bat:%d\n", currentBPM, fallState, batteryPct);
      txCharacteristic.writeValue(msg);
    }
  }
}