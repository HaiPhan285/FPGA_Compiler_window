`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Engineer: Gia Pham
// Date: 03/11/2026
//////////////////////////////////////////////////////////////////////////////////


module top #(
        parameter int DIVISOR = 100_000_000
) (
    input CLK100MHZ,
    input CPU_RESETN,
    output reg led
    );
    
    //Invert reset to high
    reg reset_h;
    assign reset_h = ~CPU_RESETN;
    
    reg tick_done;
    tick_gen #(.DIVISOR(DIVISOR)) u_tick (
        .clk(CLK100MHZ),
        .rst(reset_h),
        .tick(tick_done)
    );
        
    always @(posedge CLK100MHZ) begin
        if (reset_h) led <= '0;
        else begin
            if (tick_done) led <= ~led;
            else led <= led;
        end 
       
    end
endmodule