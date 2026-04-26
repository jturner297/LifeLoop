#include <Wire.h>
#include <Adafruit_Sensor.h>
#include <Adafruit_MPU6050.h>
#include <math.h>

// Thresholds will go here
#define freeFall_Ms 80
#define stationary_Ms 6000

// Enum and state variable
enum FallDetection { Normal, Free_Falling, Impact, Stationary };
FallDetection state = Normal;

Adafruit_MPU6050 mpu;

// Timing variables
unsigned long fallTime = 0;
unsigned long stationaryTime = 0;


float magnitude(float x, float y, float z) {
  return sqrt(x*x + y*y + z*z);
}

void setup() {
     Serial.begin(115200);

  // Initalize the accelerometer 
  if (!mpu.begin()) {
    Serial.println("MPU6050 Error!");
    while (1);
  }
}

void loop() {
    // Read accelerometer values
    sensors_event_t a, g, temp;
  mpu.getEvent(&a, &g, &temp);

  // Compute magnitude
  float  magValues = magnitude(a.acceleration.x, a.acceleration.y, a.acceleration.z);
  
  // Displays magnitude values
  Serial.println(magValues);

  // Displays current state
  Serial.println(state);
    // Switch statement for state machine
    switch(state) {
        case Normal:
          if (magValues < 9.5){
            fallTime = millis();
            state = Free_Falling;
            
          }
          break;
        case Free_Falling:
          if (magValues > 9.5){
            state = Normal;
          }
          if (magValues > 15 && millis() - fallTime >= freeFall_Ms){
            stationaryTime = millis();
            state = Impact;
          }
          break;
        case Impact:
          if (magValues > 12){
            state = Normal;
          }
          if (millis() - stationaryTime >= stationary_Ms){
            state = Stationary;
          }
          break; 
        case Stationary:
        Serial.println("Fall detected! ACTIVATE SAFETY PROTOCOL");
        state = Normal;
        break;
        }
   
  delay (100);
}