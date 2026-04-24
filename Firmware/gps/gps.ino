void setup() {
  Serial.begin(115200);    // PC Serial Monitor
  Serial1.begin(9600);     // GPS baud rate (usually 9600)
}

void loop() {
  while (Serial1.available()) {
    char c = Serial1.read();
    Serial.write(c); // print raw GPS data
  }
}