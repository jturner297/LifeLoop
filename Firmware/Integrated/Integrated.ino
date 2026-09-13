#include <Wire.h>
#include "MAX30105.h"

MAX30105 particleSensor;

void setup()
{
  Serial.begin(115200);
  delay(1000);

  Serial.println("Starting MAX30105 test...");

  Wire.begin();

  // Check if sensor is detected
  if (!particleSensor.begin(Wire, I2C_SPEED_FAST))
  {
    Serial.println("MAX30105 NOT FOUND.");
    Serial.println("Check wiring and power.");
    while (1);
  }

  Serial.println("MAX30105 FOUND!");

  // Configure sensor
  particleSensor.setup(
    60,     // LED brightness
    4,      // Sample averaging
    2,      // Mode: Red + IR
    100,    // Sample rate
    411,    // Pulse width
    4096    // ADC range
  );

  Serial.println("Put your finger on the sensor.");
}

void loop()
{
  long irValue = particleSensor.getIR();
  long redValue = particleSensor.getRed();

  Serial.print("IR: ");
  Serial.print(irValue);

  Serial.print("    RED: ");
  Serial.println(redValue);

  delay(100);
}