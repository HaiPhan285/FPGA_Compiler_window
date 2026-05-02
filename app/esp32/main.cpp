#include <Arduino.h>
#include "BluetoothSerial.h"

#if !defined(CONFIG_BT_ENABLED) || !defined(CONFIG_BLUEDROID_ENABLED)
#error Bluetooth is not enabled!
#endif

BluetoothSerial SerialBT;
HardwareSerial FPGA_UART(2);   // UART2

void setup() {
    Serial.begin(115200);                       // USB serial to PC
    SerialBT.begin("ESP32_BT");                 // Bluetooth serial
    FPGA_UART.begin(9600, SERIAL_8N1, 16, 17);  // RX=16, TX=17

    Serial.println("Bluetooth ready! Pair with 'ESP32_BT'");
    Serial.println("FPGA UART ready on GPIO16(RX), GPIO17(TX)");
}

void loop() {
    // Bluetooth -> FPGA
    if (SerialBT.available()) {
        char c = SerialBT.read();
        FPGA_UART.write(c);
        Serial.write(c);   // optional debug to USB monitor
    }

    // FPGA -> Bluetooth
    if (FPGA_UART.available()) {
        char c = FPGA_UART.read();
        SerialBT.write(c);
        Serial.write(c);   // optional debug to USB monitor
    }

    // PC terminal -> FPGA
    if (Serial.available()) {
        char c = Serial.read();
        FPGA_UART.write(c);
    }
}