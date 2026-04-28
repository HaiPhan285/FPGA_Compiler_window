module adder_top (
    input  wire [3:0] SW_A,
    input  wire [3:0] SW_B,
    output wire [4:0] LED_SUM
);

    wire [4:0] carry;
    assign carry[0] = 1'b0;
    
    // Manually implement ripple carry using gates
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : adder_bit
            assign LED_SUM[i] = SW_A[i] ^ SW_B[i] ^ carry[i];
            assign carry[i+1] = (SW_A[i] & SW_B[i]) | ((SW_A[i] ^ SW_B[i]) & carry[i]);
        end
    endgenerate
    
    assign LED_SUM[4] = carry[4];

endmodule