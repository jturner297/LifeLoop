#include <WiFi.h>
#include <HTTPClient.h>
#include <ArduinoJson.h>
#include <TinyGPS++.h>

// ===== WIFI =====
const char* ssid = "WIFI_NAME";
const char* password = "WIFI_PASSWORD";
const char* apiKey = "GOOGLE_API_KEY";

// ===== GPS =====
TinyGPSPlus gps;
HardwareSerial gpsSerial(2);

// ===== ADDRESS LOOKUP =====
String getAddress(float lat, float lon) {

  HTTPClient http;

  String url =
    "https://maps.googleapis.com/maps/api/geocode/json?latlng=" +
    String(lat, 6) + "," + String(lon, 6) +
    "&key=" + String(apiKey);

  http.begin(url);

  int code = http.GET();

  if (code > 0) {

    String response = http.getString();

    StaticJsonDocument<2048> doc;
    deserializeJson(doc, response);

    const char* address =
      doc["results"][0]["formatted_address"];

    http.end();

    return String(address);
  }

  http.end();

  return "Address not found";
}

// ===== GPS LOCATION =====
bool getGPS(float &lat, float &lon, float &accuracy) {

  unsigned long start = millis();

  // Wait up to 5 sec for GPS
  while (millis() - start < 5000) {

    while (gpsSerial.available()) {
      gps.encode(gpsSerial.read());
    }

    if (gps.location.isValid()) {

      lat = gps.location.lat();
      lon = gps.location.lng();

      // HDOP approximation
      accuracy = gps.hdop.hdop();

      return true;
    }
  }

  return false;
}

// ===== WIFI LOCATION =====
bool getWiFiLocation(float &lat, float &lon, float &accuracy) {

  int n = WiFi.scanNetworks();

  if (n <= 0) {
    return false;
  }

  String wifiList = "\"wifiAccessPoints\":[";

  for (int i = 0; i < n; i++) {

    wifiList += "{";
    wifiList += "\"macAddress\":\"" + WiFi.BSSIDstr(i) + "\",";
    wifiList += "\"signalStrength\":" + String(WiFi.RSSI(i));
    wifiList += "}";

    if (i < n - 1)
      wifiList += ",";
  }

  wifiList += "]";

  String payload = "{" + wifiList + "}";

  HTTPClient http;

  String url =
    "https://www.googleapis.com/geolocation/v1/geolocate?key=" +
    String(apiKey);

  http.begin(url);
  http.addHeader("Content-Type", "application/json");

  int code = http.POST(payload);

  if (code > 0) {

    String response = http.getString();

    StaticJsonDocument<1024> doc;
    deserializeJson(doc, response);

    lat = doc["location"]["lat"];
    lon = doc["location"]["lng"];
    accuracy = doc["accuracy"];

    http.end();

    return true;
  }

  http.end();

  return false;
}

// ===== SETUP =====
void setup() {

  Serial.begin(115200);

  // GPS UART
  gpsSerial.begin(9600, SERIAL_8N1, 16, 17);

  // WiFi
  WiFi.begin(ssid, password);

  Serial.print("Connecting to WiFi");

  while (WiFi.status() != WL_CONNECTED) {

    delay(500);
    Serial.print(".");
  }

  Serial.println("\nWiFi Connected");
}

// ===== LOOP =====
void loop() {

  float lat, lon, accuracy;

  Serial.println("\n========================");
  Serial.println("Getting Location...");
  Serial.println("========================");

  // ===== TRY GPS FIRST =====
  if (getGPS(lat, lon, accuracy)) {

    Serial.println("Using GPS");

    String address = getAddress(lat, lon);

    Serial.print("Latitude: ");
    Serial.println(lat, 6);

    Serial.print("Longitude: ");
    Serial.println(lon, 6);

    Serial.print("GPS HDOP: ");
    Serial.println(accuracy);

    Serial.print("Address: ");
    Serial.println(address);
  }

  // ===== FALLBACK TO WIFI =====
  else {

    Serial.println("GPS Failed - Using WiFi");

    if (getWiFiLocation(lat, lon, accuracy)) {

      String address = getAddress(lat, lon);

      Serial.print("Latitude: ");
      Serial.println(lat, 6);

      Serial.print("Longitude: ");
      Serial.println(lon, 6);

      Serial.print("Accuracy (meters): ");
      Serial.println(accuracy);

      Serial.print("Address: ");
      Serial.println(address);
    }

    else {

      Serial.println("Location Failed");
    }
  }

  // wait 20 seconds
  delay(20000);
}