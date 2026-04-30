#include <Wire.h>
#include <Adafruit_Sensor.h>
#include <Adafruit_MPU6050.h>
#include <math.h>

// ── Timing Thresholds (milliseconds) ─────────────────────────────────────────
#define freeFall_Ms 80        // Minimum time in free-fall to count as a real fall
#define stationary_Ms 6000    // Time person must be still to confirm a fall (6 sec)
#define fastBlinkInterval 300 // Fast red blink during free-fall phase
#define slowBlinkInterval 1000 // Slow red blink during emergency/stationary phase

// ── LED Pin Definitions ───────────────────────────────────────────────────────
#define LED_RED 4  // GPIO 4 - Red LED for emergency states
#define LED_BLUE 5 // GPIO 5 - Blue LED for normal operation

// ── Fall Detection State Machine ──────────────────────────────────────────────
// Four states: Normal → Free_Falling → Impact → Stationary
enum FallDetection { Normal, Free_Falling, Impact, Stationary };
FallDetection state = Normal; // Device starts in normal state

Adafruit_MPU6050 mpu; // MPU6050 accelerometer object

// ── Timing Variables ──────────────────────────────────────────────────────────
unsigned long fallTime = 0;        // Timestamp when free-fall phase started
unsigned long stationaryTime = 0;  // Timestamp when impact phase started
unsigned long lastBlinkTime = 0;   // Timestamp of last LED toggle for blinking
unsigned long stationaryTrack = 0; // Timestamp when stationary/emergency phase started

// ── Magnitude Calculation ─────────────────────────────────────────────────────
// Computes total acceleration vector: sqrt(x² + y² + z²)
// Resting value ≈ 9.8 m/s² (gravity), free-fall ≈ 0, impact >> 9.8
float magnitude(float x, float y, float z) {
  return sqrt(x*x + y*y + z*z);
}

void setup() {
  Serial.begin(115200);

  // Initialize MPU6050 accelerometer, halt if not found
  if (!mpu.begin()) {
    Serial.println("MPU6050 Error!");
    while (1);
  }

  // Set LED pins as outputs
  pinMode(LED_RED, OUTPUT);
  pinMode(LED_BLUE, OUTPUT);
}

void loop() {
  // ── Read Accelerometer ──────────────────────────────────────────────────────
  sensors_event_t a, g, temp;
  mpu.getEvent(&a, &g, &temp);

  // ── Compute Total Acceleration Magnitude ───────────────────────────────────
  float magValues = magnitude(a.acceleration.x, a.acceleration.y, a.acceleration.z);

  // ── Serial Debug Output ────────────────────────────────────────────────────
  Serial.println(magValues); // Print raw magnitude every loop

  // Print current state as a readable string
  if (state == Normal)           Serial.println("Normal");
  else if (state == Free_Falling) Serial.println("Free Falling!");
  else if (state == Impact)       Serial.println("Impact!");
  else if (state == Stationary)   Serial.println("FALL DETECTED!");

  // ── Fall Detection State Machine ───────────────────────────────────────────
  switch(state) {

    // Normal: blue LED on, watch for magnitude drop indicating free-fall
    case Normal:
      digitalWrite(LED_BLUE, HIGH);
      digitalWrite(LED_RED, LOW);
      if (magValues < 9.5) {
        fallTime = millis(); // Record when free-fall started
        state = Free_Falling;
      }
      break;

    // Free_Falling: fast red blink, confirm free-fall duration then watch for impact spike
    case Free_Falling:
      if (millis() - lastBlinkTime >= fastBlinkInterval) {
        lastBlinkTime = millis();
        digitalWrite(LED_RED, !digitalRead(LED_RED)); // Toggle red LED
      }
      if (magValues > 9.5) {
        state = Normal; // Magnitude recovered, not a real fall
      }
      if (magValues > 15 && millis() - fallTime >= freeFall_Ms) {
        stationaryTime = millis(); // Record when impact occurred
        state = Impact;
      }
      break;

    // Impact: solid red LED, wait to see if person stays still
    case Impact:
      digitalWrite(LED_BLUE, LOW);
      digitalWrite(LED_RED, HIGH);
      if (magValues > 12) {
        state = Normal; // Person is moving, not a real fall
      }
      if (millis() - stationaryTime >= stationary_Ms) {
        stationaryTrack = millis(); // Record when emergency phase started
        state = Stationary;
      }
      break;

    // Stationary: slow red blink for 10 seconds, alert family network
    case Stationary:
      if (millis() - lastBlinkTime >= slowBlinkInterval) {
        lastBlinkTime = millis();
        digitalWrite(LED_RED, !digitalRead(LED_RED)); // Toggle red LED slowly
      }
      Serial.println("Fall detected! ACTIVATE SAFETY PROTOCOL");
      if (millis() - stationaryTrack >= 10000) {
        digitalWrite(LED_RED, LOW); // Turn off LED before resetting
        state = Normal; // Reset after 10 seconds
      }
      break;
  }

  delay(100); // Small delay to avoid thrashing the sensor
}