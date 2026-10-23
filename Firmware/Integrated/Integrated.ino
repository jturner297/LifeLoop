#include <LifeLoop-Fall-Detection_inferencing.h>

#include <ArduinoBLE.h>
#include <Wire.h>
#include <LSM6DS3.h>          
#include "MAX30105.h"
#include <math.h>

// ── Hardware Definitions ──────────────────────────────────────────────────────
#define BUTTON_PIN D1
#define BUZZER_PIN A3         

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

const char* FALL_LABEL = "NewFall";        // must match the Edge Impulse label exactly
const float FALL_PROB_THRESHOLD = 0.95f;   // model confidence required
const float IMPACT_GATE_MS2 = 35.0f;       // minimum peak acceleration magnitude

// Post-impact stillness check
const float MOTION_DEV_MS2 = 3.0f;         // deviation from 1 g that counts as "moving"
const float MAX_ACTIVE_FRACTION = 0.5f;    // cancel if moving more than this fraction of the time
const unsigned long SETTLE_MS = 1000;      // ignore the first second after impact (bounce/settling)
unsigned long recoverySamples = 0;
unsigned long activeSamples = 0;

const unsigned long OBSERVATION_WINDOW     = 4000; 
const unsigned long CANCEL_HOLD_TIME       = 2000; 

enum FallDetection { Normal = 0, Recovering = 3, Emergency = 4 };
FallDetection fallState = Normal;

unsigned long observationStartTime = 0;
unsigned long lastBlinkTime = 0;
unsigned long buttonPressStartTime = 0; 
unsigned long lastMpuReadTime = 0;
const unsigned long MPU_READ_INTERVAL = 10; 

float imuBuffer[EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE] = {0};
int imuBufferIndex = 0;
static int consecutiveFallFrames = 0;

float magnitude(float x, float y, float z) {
  return sqrt(x*x + y*y + z*z);
}

// ── Heart Rate Variables (DSP & Standby) ──────────────────────────────────────
unsigned long lastHrReadTime = 0;
const unsigned long HR_READ_INTERVAL = 5; 

bool hrStandbyMode = false;
unsigned long offWristStartTime = 0;
const unsigned long OFF_WRIST_TIMEOUT = 3000;      
const unsigned long STANDBY_POLL_INTERVAL = 2000;  

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
  Serial.begin(115200);

  pinMode(LED_RED, OUTPUT);
  pinMode(LED_GREEN, OUTPUT);
  pinMode(LED_BLUE, OUTPUT);
  digitalWrite(LED_RED, HIGH);
  digitalWrite(LED_GREEN, HIGH);
  digitalWrite(LED_BLUE, HIGH);

  pinMode(BUTTON_PIN, INPUT_PULLUP);
  
  pinMode(BUZZER_PIN, OUTPUT);
  noTone(BUZZER_PIN); 

  Wire.begin();
  myIMU.begin();

  if (particleSensor.begin(Wire, I2C_SPEED_FAST)) {
    // powerLevel=60, sampleAverage=4, ledMode=1 (IR Only), sampleRate=400, pulseWidth=411, adcRange=16384
    particleSensor.setup(60, 4, 1, 400, 411, 16384);
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

  // ── Library sanity check ──
  Serial.println("---- Edge Impulse model info ----");
  Serial.print("Freq (Hz): ");  Serial.println(EI_CLASSIFIER_FREQUENCY);
  Serial.print("Axes: ");       Serial.println(EI_CLASSIFIER_RAW_SAMPLES_PER_FRAME);
  Serial.print("Frame size: "); Serial.println(EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE);
  Serial.println("Labels:");
  for (size_t i = 0; i < EI_CLASSIFIER_LABEL_COUNT; i++) {
    Serial.print("  ");
    Serial.println(ei_classifier_inferencing_categories[i]);
  }
  Serial.println("---------------------------------");
}

// ── Main Loop ─────────────────────────────────────────────────────────────────
void loop() {
  BLEDevice central = BLE.central();
  unsigned long now = millis();

  // 1. Process Heart Rate & Duty-Cycled Standby
  unsigned long currentHrInterval = hrStandbyMode ? STANDBY_POLL_INTERVAL : HR_READ_INTERVAL;

  if (now - lastHrReadTime >= currentHrInterval) {
    lastHrReadTime = now;
    
    if (hrStandbyMode) {
      particleSensor.wakeUp();
      delay(2); // Give ADC time to power up and sample
      long irRaw = particleSensor.getIR();
      
      if (irRaw >= 80000) {
        hrStandbyMode = false;
        offWristStartTime = 0;
      } else {
        particleSensor.shutDown();
      }
    } else {
      long irRaw = particleSensor.getIR();
      
      if (irRaw < 80000) {
        if (offWristStartTime == 0) {
          offWristStartTime = now;
        } else if (now - offWristStartTime >= OFF_WRIST_TIMEOUT) {
          hrStandbyMode = true;
          particleSensor.shutDown();
          resetHR();
        }
      } else {
        offWristStartTime = 0;
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
  }

  // 2. Process Edge Impulse AI Fall Detection Pipeline
  if (now - lastMpuReadTime >= MPU_READ_INTERVAL) {
    lastMpuReadTime = now;

    switch(fallState) {
      case Normal:
        digitalWrite(LED_BLUE, LOW);  
        digitalWrite(LED_RED, HIGH);
        digitalWrite(LED_GREEN, HIGH);
        noTone(BUZZER_PIN);   
        ledRedState = true;
        buttonPressStartTime = 0; 
        
        imuBuffer[imuBufferIndex++] = myIMU.readFloatAccelX() * CONVERT_G_TO_MS2;
        imuBuffer[imuBufferIndex++] = myIMU.readFloatAccelY() * CONVERT_G_TO_MS2;
        imuBuffer[imuBufferIndex++] = myIMU.readFloatAccelZ() * CONVERT_G_TO_MS2;

        if (imuBufferIndex >= EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE) {
            signal_t signal;
            numpy::signal_from_buffer(imuBuffer, EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE, &signal);
            ei_impulse_result_t result = { 0 };
            EI_IMPULSE_ERROR err = run_classifier(&signal, &result, false);

            if (err == EI_IMPULSE_OK) {
                float fallProb = 0.0;
                for (size_t ix = 0; ix < EI_CLASSIFIER_LABEL_COUNT; ix++) {
                    if (strcmp(result.classification[ix].label, FALL_LABEL) == 0) {
                        fallProb = result.classification[ix].value;
                    }
                }

                // Debug: watch real probabilities while testing
                if (fallProb > 0.3f) {
                    Serial.print("NewFall prob: ");
                    Serial.println(fallProb, 3);
                }
                
                if (fallProb > FALL_PROB_THRESHOLD) {
                    bool validImpact = false;
                    float peakMag = 0;
                    for (int i = 0; i + 2 < EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE; i += 3) {
                        float mag = magnitude(imuBuffer[i], imuBuffer[i+1], imuBuffer[i+2]);
                        if (mag > peakMag) peakMag = mag;
                        if (mag > IMPACT_GATE_MS2) {
                            validImpact = true;
                        }
                    }
                    
                    if (validImpact) {
                        consecutiveFallFrames++;
                        // DEBOUNCE: Require two consecutive triggering frames
                        if (consecutiveFallFrames >= 2) {
                            Serial.print("FALL TRIGGERED, peak mag: ");
                            Serial.println(peakMag, 1);
                            observationStartTime = now;
                            recoverySamples = 0;
                            activeSamples = 0;
                            fallState = Recovering; 
                            consecutiveFallFrames = 0;
                        }
                    } else {
                        consecutiveFallFrames = 0;
                        Serial.print("Suppressed: AI confident, but peak impact only ");
                        Serial.print(peakMag, 1);
                        Serial.println(" m/s^2");
                    }
                } else {
                    consecutiveFallFrames = 0;
                }
            } else {
                Serial.print("Classifier error: ");
                Serial.println((int)err);
            }
            
            // 87.5% sliding window overlap (shift kept a multiple of 3 so X/Y/Z stay aligned)
            int shiftAmount = (EI_CLASSIFIER_DSP_INPUT_FRAME_SIZE / 8 / 3) * 3;
            if (shiftAmount < 3) shiftAmount = 3;
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

        // Sample motion after the settle period to see if the device stays still
        if (now - observationStartTime >= SETTLE_MS) {
          float mag = magnitude(myIMU.readFloatAccelX() * CONVERT_G_TO_MS2,
                                myIMU.readFloatAccelY() * CONVERT_G_TO_MS2,
                                myIMU.readFloatAccelZ() * CONVERT_G_TO_MS2);
          recoverySamples++;
          if (fabs(mag - 9.81f) > MOTION_DEV_MS2) activeSamples++;
        }

        if (digitalRead(BUTTON_PIN) == LOW) {
          if (buttonPressStartTime == 0) {
            buttonPressStartTime = now; 
          } else if (now - buttonPressStartTime >= CANCEL_HOLD_TIME) {
            fallState = Normal; 
            buttonPressStartTime = 0;
            imuBufferIndex = 0; 
          }
        } else {
          buttonPressStartTime = 0; 
          
          if (now - observationStartTime >= OBSERVATION_WINDOW) {
            float activeFrac = recoverySamples ? (float)activeSamples / recoverySamples : 0;
            Serial.print("Post-impact active fraction: ");
            Serial.println(activeFrac, 2);

            if (activeFrac > MAX_ACTIVE_FRACTION) {
              Serial.println("Cancelled: device kept moving after impact");
              fallState = Normal;
              imuBufferIndex = 0;
            } else {
              fallState = Emergency; 
            }
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
            imuBufferIndex = 0; 
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
      imuBufferIndex = 0; 
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