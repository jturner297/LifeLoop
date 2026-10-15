// IMPORTANT: Change this to match the exact name of your Edge Impulse project library
#include <LifeLoop-Fall-Detection_inferencing.h>

#include <ArduinoBLE.h>
#include <Wire.h>
#include <LSM6DS3.h>          // Seeed Arduino LSM6DS3 library
#include "MAX30105.h"
#include <math.h>

// ── Hardware Definitions ──────────────────────────────────────────────────────
#define BUTTON_PIN D1
#define BUZZER_PIN A3         // Added Buzzer Pin

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

// ── Fall Detection Parameters & Edge Impulse Buffers ──────────────────────────
const float CONVERT_G_TO_MS2 = 9.81f;

// The AI replaces the hardcoded thresholds. We only need the timers for the UI now.
const unsigned long OBSERVATION_WINDOW     = 4000; 
const unsigned long CANCEL_HOLD_TIME       = 2000; 

// Simplified State Machine: AI handles the physical fall, jumping straight to Recovering
// FIXED: Explicitly mapping to original integer values so the iOS app recognizes the state
enum FallDetection { Normal = 0, Recovering = 3, Emergency = 4 };
FallDetection fallState = Normal;

unsigned long observationStartTime = 0;
unsigned long lastBlinkTime = 0;
unsigned long buttonPressStartTime = 0; 

unsigned long lastMpuReadTime = 0;
// Changed to 10ms to enforce the strict 100Hz frequency required by the AI
const unsigned long MPU_READ_INTERVAL = 10; 

// Global buffer to hold the IMU data without overflowing the local stack
float imuBuffer[EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE] = {0};
int imuBufferIndex = 0;

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
  
  // Initialize Buzzer
  pinMode(BUZZER_PIN, OUTPUT);
  noTone(BUZZER_PIN); // Ensure it starts quiet using noTone()

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

  // 1. Process Heart Rate
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

  // 2. Process Edge Impulse AI Fall Detection Pipeline
  if (now - lastMpuReadTime >= MPU_READ_INTERVAL) {
    lastMpuReadTime = now;

    switch(fallState) {
      case Normal:
        digitalWrite(LED_BLUE, LOW);  
        digitalWrite(LED_RED, HIGH);
        digitalWrite(LED_GREEN, HIGH);
        noTone(BUZZER_PIN);   // Silence the buzzer using noTone()
        ledRedState = true;
        buttonPressStartTime = 0; 
        
        // Fill the ML buffer with 100Hz data
        imuBuffer[imuBufferIndex++] = myIMU.readFloatAccelX() * CONVERT_G_TO_MS2;
        imuBuffer[imuBufferIndex++] = myIMU.readFloatAccelY() * CONVERT_G_TO_MS2;
        imuBuffer[imuBufferIndex++] = myIMU.readFloatAccelZ() * CONVERT_G_TO_MS2;

        // When the buffer hits 2000ms worth of data, run the prediction
        if (imuBufferIndex >= EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE) {
            signal_t signal;
            numpy::signal_from_buffer(imuBuffer, EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE, &signal);
            ei_impulse_result_t result = { 0 };
            EI_IMPULSE_ERROR err = run_classifier(&signal, &result, false);

            if (err == EI_IMPULSE_OK) {
                // Check the AI's confidence that a fall just occurred
                float fallProb = 0.0;
                for (size_t ix = 0; ix < EI_CLASSIFIER_LABEL_COUNT; ix++) {
                    if (strcmp(result.classification[ix].label, "fall") == 0) {
                        fallProb = result.classification[ix].value;
                    }
                }
                
                // If the AI is > 85% certain, trigger the recovery alarm window
                if (fallProb > 0.85) {
                    observationStartTime = now;
                    fallState = Recovering; 
                }
            }
            
            // Implement an 87.5% sliding window overlap to process data 
            // every 250ms, making the fall detection highly responsive
            int shiftAmount = EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE / 8; 
            int keepAmount = EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE - shiftAmount;
            
            for (int i = 0; i < keepAmount; i++) {
                imuBuffer[i] = imuBuffer[i + shiftAmount];
            }
            imuBufferIndex = keepAmount;
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
            imuBufferIndex = 0; // Wipe old data so it doesn't instantly re-trigger
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
          
          // Drive the passive buzzer with a 3000 Hz square wave.
          // ledRedState == LOW means the LED is ON, so we sound the alarm.
          if (!ledRedState) {
            tone(BUZZER_PIN, 3000); 
          } else {
            noTone(BUZZER_PIN);
          }
        }
        
        if (digitalRead(BUTTON_PIN) == LOW) {
          if (buttonPressStartTime == 0) {
            buttonPressStartTime = now; 
          } else if (now - buttonPressStartTime >= CANCEL_HOLD_TIME) {
            fallState = Normal; 
            buttonPressStartTime = 0;
            imuBufferIndex = 0; // Wipe old data so it doesn't instantly re-trigger
          }
        } else {
          buttonPressStartTime = 0; 
        }
        break;
    }
  }

  // 3. Listen for iOS Commands 
  if (rxCharacteristic.written()) {
    int length = rxCharacteristic.valueLength();
    const uint8_t* val = rxCharacteristic.value();
    String command = "";
    for (int i = 0; i < length; i++) {
      command += (char)val[i];
    }
    
    command.trim(); 
    
    if (command == "CANCEL") {
      fallState = Normal;
      imuBufferIndex = 0; // Wipe old data so it doesn't instantly re-trigger
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
