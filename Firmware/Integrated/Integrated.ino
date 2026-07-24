#include <Wire.h>
#include <Adafruit_Sensor.h>
#include <Adafruit_MPU6050.h>
#include <math.h>
#include "MAX30105.h"
#include <TinyGPS++.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
<<<<<<< HEAD
#include <Adafruit_NeoPixel.h>

// ── Pin Definitions (From wiring_guide.md) ────────────────────────────────────
=======

// ── Pin & Network Definitions ─────────────────────────────────────────────────
>>>>>>> 73593d7 (Updated firmware & software)
#define I2C_SDA 21
#define I2C_SCL 22
#define GPS_RX  16
#define GPS_TX  17
#define LED_RED 4  
#define LED_BLUE 5 
<<<<<<< HEAD
#define RGB_PIN 25
#define RGB_COUNT 1
=======
>>>>>>> 73593d7 (Updated firmware & software)

// ── BLE Definitions ───────────────────────────────────────────────────────────
#define SERVICE_UUID           "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

BLEServer* pServer = nullptr;
BLECharacteristic* pTxCharacteristic = nullptr;
bool deviceConnected = false;
unsigned long lastSendTime = 0;
<<<<<<< HEAD
const unsigned long SEND_INTERVAL = 1000; // Send data to Pi every 1 second
=======
const unsigned long SEND_INTERVAL = 1000;
>>>>>>> 73593d7 (Updated firmware & software)

class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override { deviceConnected = true; }
  void onDisconnect(BLEServer* pServer) override { 
    deviceConnected = false; 
    pServer->getAdvertising()->start(); 
  }
};

// ── Hardware Objects ──────────────────────────────────────────────────────────
<<<<<<< HEAD
Adafruit_NeoPixel rgb(RGB_COUNT, RGB_PIN, NEO_GRB + NEO_KHZ800);
=======
>>>>>>> 73593d7 (Updated firmware & software)
Adafruit_MPU6050 mpu;
MAX30105 particleSensor;
TinyGPSPlus gps;
HardwareSerial gpsSerial(2);

<<<<<<< HEAD
// ── Accelerometer & Fall Detection Variables ──────────────────────────────────
=======
// ── Fall Detection Variables ──────────────────────────────────────────────────
>>>>>>> 73593d7 (Updated firmware & software)
enum FallDetection { Normal, Free_Falling, Impact, Stationary };
FallDetection fallState = Normal;
unsigned long fallTime = 0;
unsigned long stationaryTime = 0;
unsigned long stationaryTrack = 0;
unsigned long lastBlinkTime = 0;

<<<<<<< HEAD
=======
unsigned long lastMpuReadTime = 0;
const unsigned long MPU_READ_INTERVAL = 100; 

>>>>>>> 73593d7 (Updated firmware & software)
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

<<<<<<< HEAD
// ── GPS Variables ─────────────────────────────────────────────────────────────
float currentLat = 0.0;
float currentLon = 0.0;

// ==============================================================================
// ── SETUP ─────────────────────────────────────────────────────────────────────
// ==============================================================================
void setup() {
  Serial.begin(115200);
  
  // 1. Init I2C for Sensors
  Wire.begin(I2C_SDA, I2C_SCL);

  // 2. Init LEDs
  pinMode(LED_RED, OUTPUT);
  pinMode(LED_BLUE, OUTPUT);
  rgb.begin();
  rgb.setBrightness(50);
  rgb.setPixelColor(0, rgb.Color(255, 0, 0)); // Red = Disconnected
  rgb.show();

  // 3. Init MPU6050
  if (!mpu.begin(0x68, &Wire)) {
    Serial.println("MPU6050 Error!");
  }

  // 4. Init MAX30102
=======
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
  Wire.begin(I2C_SDA, I2C_SCL);

  pinMode(LED_RED, OUTPUT);
  pinMode(LED_BLUE, OUTPUT);

  // Init Sensors
  if (!mpu.begin(0x68, &Wire)) Serial.println("MPU6050 Error!");
>>>>>>> 73593d7 (Updated firmware & software)
  if (!particleSensor.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("MAX30102 Error!");
  } else {
    particleSensor.setup(60, 1, 2, 200, 411, 4096);
  }

<<<<<<< HEAD
  // 5. Init GPS
  gpsSerial.begin(9600, SERIAL_8N1, GPS_RX, GPS_TX);

  // 6. Init BLE Server
=======
  // Init GPS
  gpsSerial.begin(9600, SERIAL_8N1, GPS_RX, GPS_TX);

  // Init BLE
>>>>>>> 73593d7 (Updated firmware & software)
  BLEDevice::init("Life Loop");
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());
  BLEService* pService = pServer->createService(SERVICE_UUID);
  pTxCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID_TX,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pTxCharacteristic->addDescriptor(new BLE2902());
  pService->start();
  pServer->getAdvertising()->start();
  
<<<<<<< HEAD
  Serial.println("System Ready. Waiting for Pi connection...");
}

// ==============================================================================
// ── MAIN LOOP ─────────────────────────────────────────────────────────────────
// ==============================================================================
void loop() {
  unsigned long now = millis();

  // ── 1. Process GPS Data (Non-Blocking) ──
  while (gpsSerial.available() > 0) {
    gps.encode(gpsSerial.read());
    if (gps.location.isUpdated()) {
      currentLat = gps.location.lat();
      currentLon = gps.location.lng();
    }
  }

  // ── 2. Process Heart Rate (DSP Loop) ──
  long irRaw = particleSensor.getIR();
  if (irRaw < 80000) {
    resetHR(); // No finger/wrist detected
=======
  Serial.println("System Ready.");
}

// ── Main Loop ─────────────────────────────────────────────────────────────────
void loop() {
  unsigned long now = millis();

  // 1. Process GPS Data (Non-Blocking)
  while (gpsSerial.available() > 0) {
    gps.encode(gpsSerial.read());
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
        Serial.printf("[LOCATION UPDATED] Lat: %.6f, Lon: %.6f\n", currentLat, currentLon);
      } else {
        Serial.println("[OPTIMIZATION] Stationary detected. Skipping redundant location update.");
      }
    }
  }

  // 2. Process Heart Rate (DSP Loop)
  long irRaw = particleSensor.getIR();
  if (irRaw < 80000) {
    resetHR();
>>>>>>> 73593d7 (Updated firmware & software)
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

<<<<<<< HEAD
  // ── 3. Process Fall Detection (State Machine) ──
  sensors_event_t a, g, temp;
  mpu.getEvent(&a, &g, &temp);
  float magValues = magnitude(a.acceleration.x, a.acceleration.y, a.acceleration.z);

  switch(fallState) {
    case Normal:
      digitalWrite(LED_BLUE, HIGH);
      digitalWrite(LED_RED, LOW);
      if (magValues < 9.5) {
        fallTime = now;
        fallState = Free_Falling;
      }
      break;

    case Free_Falling:
      if (now - lastBlinkTime >= 300) {
        lastBlinkTime = now;
        digitalWrite(LED_RED, !digitalRead(LED_RED));
      }
      if (magValues > 9.5) fallState = Normal;
      if (magValues > 15 && now - fallTime >= 80) {
        stationaryTime = now;
        fallState = Impact;
      }
      break;

    case Impact:
      digitalWrite(LED_BLUE, LOW);
      digitalWrite(LED_RED, HIGH);
      if (magValues > 12) fallState = Normal;
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
        digitalWrite(LED_RED, LOW);
        fallState = Normal;
      }
      break;
  }

  // ── 4. Data Output (BLE & Serial Monitor) ──
  if (now - lastSendTime >= SEND_INTERVAL) {
    lastSendTime = now;
    
    // Format payload string
=======
  // 3. Process Fall Detection State Machine
  // Only read the sensor and update state every 100ms
  if (now - lastMpuReadTime >= MPU_READ_INTERVAL) {
    lastMpuReadTime = now;

    sensors_event_t a, g, temp;
    mpu.getEvent(&a, &g, &temp);
    float magValues = magnitude(a.acceleration.x, a.acceleration.y, a.acceleration.z);

    switch(fallState) {
      case Normal:
        digitalWrite(LED_BLUE, HIGH);
        digitalWrite(LED_RED, LOW);
        if (magValues < 6.0) {
          fallTime = now;
          fallState = Free_Falling;
        }
        break;

      case Free_Falling:
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
        digitalWrite(LED_BLUE, LOW);
        digitalWrite(LED_RED, HIGH);
        
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
          digitalWrite(LED_RED, LOW);
          fallState = Normal;
        }
        break;
    }
  }

  // 4. Send Data over BLE
  if (now - lastSendTime >= SEND_INTERVAL) {
    lastSendTime = now;
    
>>>>>>> 73593d7 (Updated firmware & software)
    char msg[128];
    snprintf(msg, sizeof(msg), "BPM:%.1f|State:%d|Lat:%.6f|Lon:%.6f\n", 
             currentBPM, fallState, currentLat, currentLon);
    
<<<<<<< HEAD
    // ALWAYS print to local Serial for debugging
    Serial.print("Local Data -> ");
    Serial.print(msg);

    // Send via BLE if connected
    if (deviceConnected) {
      // Flash NeoPixel Green during transmission
      rgb.setPixelColor(0, rgb.Color(0, 255, 0)); 
      rgb.show();
      
      pTxCharacteristic->setValue((uint8_t*)msg, strlen(msg));
      pTxCharacteristic->notify();
      
      // Briefly pause to let the green flash register visually
      delay(20); 
    }
  }

  // Restore NeoPixel state color
  if (deviceConnected) {
    rgb.setPixelColor(0, rgb.Color(0, 0, 255)); // Blue = Connected
  } else {
    rgb.setPixelColor(0, rgb.Color(255, 0, 0)); // Red = Disconnected
  }
  rgb.show();
=======
    Serial.print("Local Data -> ");
    Serial.print(msg);

    if (deviceConnected) {
      pTxCharacteristic->setValue((uint8_t*)msg, strlen(msg));
      pTxCharacteristic->notify();
    }
  }
>>>>>>> 73593d7 (Updated firmware & software)
}