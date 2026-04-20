module your_design (
    input  logic [1:0] sw,
    output logic       led
);

    assign led = sw[0] & sw[1];

endmodule
