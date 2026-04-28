#include <Wire.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <Adafruit_NeoPixel.h>

// --- BLE UUIDs (standard BLE UART profile) ---
#define SERVICE_UUID           "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_RX "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
#define CHARACTERISTIC_UUID_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

// --- Onboard RGB LED ---
#define RGB_PIN   8
#define RGB_COUNT 1
Adafruit_NeoPixel rgb(RGB_COUNT, RGB_PIN, NEO_GRB + NEO_KHZ800);

// --- Colors ---
#define COLOR_RED    rgb.Color(255, 0,   0)
#define COLOR_GREEN  rgb.Color(0,   255, 0)
#define COLOR_BLUE   rgb.Color(0,   0,   255)

// --- BLE Objects ---
BLEServer*         pServer           = nullptr;
BLECharacteristic* pTxCharacteristic = nullptr;
bool               deviceConnected   = false;

// --- Timing ---
unsigned long lastBlueFlash  = 0;
unsigned long lastSendTime   = 0;
bool          blueFlashOn    = false;
const unsigned long SEND_INTERVAL = 1000; 

// BLE Server Callbacks
class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override {
    deviceConnected = true;
    Serial.println("BLE Client Connected");
  }
  void onDisconnect(BLEServer* pServer) override {
    deviceConnected = false;
    Serial.println("BLE Client Disconnected");
    pServer->getAdvertising()->start();
  }
};

// BLE RX Callback
class MyRxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* pCharacteristic) override {
    String rxValue = pCharacteristic->getValue();
    if (rxValue.length() > 0) {
      Serial.print("BLE RX: ");
      Serial.println(rxValue.c_str());
    }
  }
};

// Helper — send string over BLE TX with blue flash
void blePrint(const char* message) {
  if (deviceConnected && pTxCharacteristic != nullptr) {
    rgb.setPixelColor(0, COLOR_BLUE);
    rgb.show();
    lastBlueFlash = millis();
    blueFlashOn   = true;

    pTxCharacteristic->setValue((uint8_t*)message, strlen(message));
    pTxCharacteristic->notify();

    Serial.print("BLE TX: ");
    Serial.println(message);
  }
}

void setup() {
  Serial.begin(115200);

  rgb.begin();
  rgb.setBrightness(50);
  rgb.clear();
  rgb.show();

  rgb.setPixelColor(0, COLOR_RED);
  rgb.show();

  delay(3000);

  BLEDevice::init("Life Loop");

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService* pService = pServer->createService(SERVICE_UUID);

  pTxCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID_TX,
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pTxCharacteristic->addDescriptor(new BLE2902());

  BLECharacteristic* pRxCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID_RX,
    BLECharacteristic::PROPERTY_WRITE
  );
  pRxCharacteristic->setCallbacks(new MyRxCallbacks());

  pService->start();
  pServer->getAdvertising()->start();

  Serial.println("BLE started — waiting for connection...");
}

void loop() {
  unsigned long now = millis();

  // --- RGB Status ---
  if (blueFlashOn && (now - lastBlueFlash >= 80)) {
    blueFlashOn = false;
  }
  if (!blueFlashOn) {
    rgb.setPixelColor(0, deviceConnected ? COLOR_GREEN : COLOR_RED);
    rgb.show();
  }

  // --- Placeholder for sensors ---
  if (deviceConnected && (now - lastSendTime >= SEND_INTERVAL)) {
    lastSendTime = now;
    
    char msg[64];
    snprintf(msg, sizeof(msg), "heartbeat:%lu\n", now);
    blePrint(msg);
  }
}