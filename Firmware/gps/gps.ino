#include <WiFi.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>

const char* ssid = "Wifi_SSID";
const char* password = "Wifi_PASSWORD";
const char* apiKey = "GoogleAPI_key";

#define BUTTON_PIN 4
bool lastState = HIGH;

// ===== Convert LAT/LON → Address =====
String getAddress(float lat, float lon) {
  HTTPClient http;

  String url = "https://maps.googleapis.com/maps/api/geocode/json?latlng=" +
               String(lat, 6) + "," + String(lon, 6) +
               "&key=" + String(apiKey);

  http.begin(url);
  int code = http.GET();

  if (code > 0) {
    String response = http.getString();

    StaticJsonDocument<2048> doc;
    deserializeJson(doc, response);

    const char* address = doc["results"][0]["formatted_address"];

    http.end();
    return String(address);
  }

  http.end();
  return "Address not found";
}

void setup() {
  Serial.begin(115200);
  pinMode(BUTTON_PIN, INPUT_PULLUP);

  WiFi.begin(ssid, password);

  Serial.print("Connecting to WiFi");
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }

  Serial.println("\nWiFi connected");
}

void loop() {
  bool currentState = digitalRead(BUTTON_PIN);

  if (lastState == HIGH && currentState == LOW) {

    Serial.println("\n--- BUTTON PRESSED ---");
    Serial.println("Using WiFi for location...");

    int n = WiFi.scanNetworks();

    String wifiList = "\"wifiAccessPoints\":[";

    for (int i = 0; i < n; i++) {
      wifiList += "{";
      wifiList += "\"macAddress\":\"" + WiFi.BSSIDstr(i) + "\",";
      wifiList += "\"signalStrength\":" + String(WiFi.RSSI(i));
      wifiList += "}";
      if (i < n - 1) wifiList += ",";
    }

    wifiList += "]";

    String payload = "{" + wifiList + "}";

    HTTPClient http;
    String url = "https://www.googleapis.com/geolocation/v1/geolocate?key=" + String(apiKey);

    http.begin(url);
    http.addHeader("Content-Type", "application/json");

    int code = http.POST(payload);

    if (code > 0) {
      String response = http.getString();

      StaticJsonDocument<1024> doc;
      deserializeJson(doc, response);

      float lat = doc["location"]["lat"];
      float lon = doc["location"]["lng"];
      float accuracy = doc["accuracy"];

      Serial.print("Latitude: ");
      Serial.println(lat, 6);

      Serial.print("Longitude: ");
      Serial.println(lon, 6);

      Serial.print("Accuracy (meters): ");
      Serial.println(accuracy);

      // 🔥 NEW: Get human-readable address
      Serial.println("Getting address...");
      String address = getAddress(lat, lon);

      Serial.print("Currently near: ");
      Serial.println(address);

    } else {
      Serial.println("Failed to get location");
    }

    http.end();
  }

  lastState = currentState;
}