#include <Wire.h>
#include "MAX30105.h"

MAX30105 particleSensor;
#define MA_SIZE 16
long maBuffer[MA_SIZE];
int maIndex = 0;
long maSum = 0;

// this function smooths out the noisy sensor readings by averageing the last 16 values
long movingAverage(long newVal) {
  maSum -= maBuffer[maIndex];
  maBuffer[maIndex] = newVal;
  maSum += newVal;
  maIndex = (maIndex + 1) % MA_SIZE;
  return maSum / MA_SIZE;
}

// this function removes the DC baseline that the sensor reads
// this leavs the moving values (the actual heart rate)
float dcPrev = 0;
float dcRemove(float raw) {
  dcPrev = 0.95 * dcPrev + 0.05 * raw;
  return raw - dcPrev;
}

// these variables and the next two functions go together
float lastFiltered = 0;
long lastBeatTime = 0;
bool descending = false;
float troughValue = 0;
#define TROUGH_HISTORY 5
float troughHistory[TROUGH_HISTORY];
int troughHistIndex = 0;
int troughHistCount = 0;
float adaptiveThreshold = -40;

// this function resets all the moving parts back to 0
// basically keeps the baseline when no wrist detected
void resetAll() {
  lastFiltered = 0;
  dcPrev = 0;
  descending = false;
  troughValue = 0;
  troughHistIndex = 0;
  troughHistCount = 0;
  adaptiveThreshold = -40;   // back to safe starting value
  for (int i = 0; i < TROUGH_HISTORY; i++) troughHistory[i] = 0;
}

// this function updates the beat detection threshold based on the average depth of the recent troughs
void updateThreshold(float newTroughDepth) {
  // a trough below -500 is probably a false value so just discard
  if (newTroughDepth < -500) return;

  troughHistory[troughHistIndex] = newTroughDepth;
  troughHistIndex = (troughHistIndex + 1) % TROUGH_HISTORY;
  if (troughHistCount < TROUGH_HISTORY) troughHistCount++;

  float sum = 0;
  for (int i = 0; i < troughHistCount; i++) sum += troughHistory[i];
  float avgDepth = sum / troughHistCount;
  adaptiveThreshold = avgDepth * 0.6;
}

// these variables and the next function go together
// they basically keep an average heart rate, which prevents crazy jumps in BPM
#define BPM_BUFFER_SIZE 6
float bpmBuffer[BPM_BUFFER_SIZE];
int bpmIndex = 0;
int bpmCount = 0;
float bpm = 0;

// adds a new BPM and updates the average of the last 6 (buffer size)
void addBPM(float newBPM) {
  bpmBuffer[bpmIndex] = newBPM;
  bpmIndex = (bpmIndex + 1) % BPM_BUFFER_SIZE;
  if (bpmCount < BPM_BUFFER_SIZE) bpmCount++;

  float sum = 0;
  for (int i = 0; i < bpmCount; i++) sum += bpmBuffer[i];
  bpm = sum / bpmCount;
}

// the setup just initializes the serial connection, i2c, and the MAX30102 sensor
void setup() {
  Serial.begin(115200);
  Wire.begin(6, 7);

  if (!particleSensor.begin(Wire, I2C_SPEED_FAST)) {
    Serial.println("MAX30102 not found. Check wiring.");
    while (1);
  }

  particleSensor.setup(60, 1, 2, 200, 411, 4096);
}

// the main loop reads the IR sensor value, conditions it, detects the heartbeat troughs,
// calculates BPM and prints the data into the serial monitor
void loop() {
  long irRaw = particleSensor.getIR();
  // handling if the wrist isnt on the sensor itself
  if (irRaw < 80000) {
    Serial.println("0,0,0");
    resetAll();          
    delay(5);
    return;
  }

  long smoothed  = movingAverage(irRaw);
  float filtered = dcRemove((float)smoothed);

  if (filtered < lastFiltered) {
    descending = true;
    if (filtered < troughValue) troughValue = filtered;
  }

  if (descending && filtered > lastFiltered) {
    if (troughValue < adaptiveThreshold) {
      long now = millis();
      long delta = now - lastBeatTime;

      if (delta > 400 && delta < 2000) {
        float instantBPM = 60000.0 / delta;
        addBPM(instantBPM);
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
    troughValue = 0;
  }

  lastFiltered = filtered;

  Serial.print(filtered);
  Serial.print(" IR, Threshold: ");
  Serial.print(adaptiveThreshold);
  Serial.print(", BPM: ");
  Serial.println(bpm);

  delay(5);
}