module uart_passthrough(
    input  wire ja_0,  // ESP32 TX -> FPGA RX
    output wire ja_1,  // FPGA TX -> ESP32 RX
    input  wire uart_rx,  // From Nexys A7 USB-UART
    output wire uart_tx,  // To Nexys A7 USB-UART
    input  wire clk
);

    assign uart_tx = ja_0;  // ESP32 TX -> PC RX
    assign ja_1 = uart_rx;  // PC TX -> ESP32 RX

endmodule
