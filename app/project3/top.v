`timescale 1ns / 1ps

// top.v — Nexys A7-100T board wrapper for the 8-bit ALU
//
// I/O mapping:
//   sw[7:0]   → ALU input A
//   sw[15:8]  → ALU input B
//   btn[2:0]  → ALU op (BTNC=op[0], BTNU=op[1], BTNL=op[2])
//   led[7:0]  → ALU result y
//   led[8]    → zero flag
//   led[9]    → negative flag
//   led[10]   → carry flag
//   led[11]   → overflow flag
module top (
    input  wire [15:0] sw,
    input  wire [2:0]  btn,
    output wire [15:0] led
);

    wire [7:0] y;
    wire       z_flag, n_flag, c_flag, v_flag;

    alu #(.w(8)) u_alu (
        .A        (sw[7:0]),
        .B        (sw[15:8]),
        .op       (btn),
        .y        (y),
        .zero     (z_flag),
        .negative (n_flag),
        .carry    (c_flag),
        .overflow (v_flag)
    );

    assign led[7:0]  = y;
    assign led[8]    = z_flag;
    assign led[9]    = n_flag;
    assign led[10]   = c_flag;
    assign led[11]   = v_flag;
    assign led[15:12] = 4'b0;

endmodule