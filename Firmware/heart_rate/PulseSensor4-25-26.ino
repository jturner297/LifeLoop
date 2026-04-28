#include <Wire.h>
#include "MAX30105.h"

MAX30105 particleSensor;

// making an array that is 16 long values ferda average
#define MA_SIZE 16
long maBuffer[MA_SIZE];
int maIndex = 0;
long maSum = 0;

// function takes in newIrVal and 
long movingAverage(long newIrVal) {
  maSum -= maBuffer[maIndex];
  maBuffer[maIndex] = newIrVal;
  maSum += newIrVal;
  maIndex = (maIndex + 1) % MA_SIZE;
  return maSum / MA_SIZE;
}

// DC removal
float dcPrev = 0;
float dcRemove(float raw) {
  dcPrev = 0.95 * dcPrev + 0.05 * raw;
  return raw - dcPrev;
}

void setup() {
  Serial.begin(115200);
  Wire.begin();

  if (!particleSensor.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("MAX30102 not found. Check wiring.");
    while (1);
  }

  particleSensor.setup(60, 1, 2, 200, 411, 4096);
}

void loop() {
  long irRaw = particleSensor.getIR();

  // dont count values when a wrist isnt detected
  if (irRaw < 80000) {
    Serial.println(0);
    delay(5);
    return;
  }

  long smoothed  = movingAverage(irRaw);
  float filtered = dcRemove((float)smoothed);

  // start checking for lowest point
  if (filtered < -50){
    
  }

  Serial.println(filtered);
  float prevFiltered = filtered;
  delay(5);
}