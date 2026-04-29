module uart_tx(
    input clk,
    input rst,
    input [7:0] data,
    input valid,
    output reg tx,
    output reg ready
);
    parameter CLK_FREQ = 100_000_000;
    parameter BAUD_RATE = 115_200;
    localparam BAUD_COUNT = CLK_FREQ / BAUD_RATE;

    reg [15:0] counter;
    reg [3:0] bit_count;
    reg [7:0] data_reg;
    reg state;

    localparam IDLE = 0, TRANSMIT = 1;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            counter <= 0;
            bit_count <= 0;
            data_reg <= 0;
            tx <= 1;
            ready <= 1;
        end else begin
            case (state)
                IDLE: begin
                    tx <= 1;
                    if (valid && ready) begin
                        data_reg <= data;
                        bit_count <= 0;
                        counter <= BAUD_COUNT;
                        tx <= 0;
                        ready <= 0;
                        state <= TRANSMIT;
                    end
                end
                TRANSMIT: begin
                    if (counter > 0) begin
                        counter <= counter - 1;
                    end else begin
                        if (bit_count < 8) begin
                            tx <= data_reg[bit_count];
                            bit_count <= bit_count + 1;
                            counter <= BAUD_COUNT;
                        end else begin
                            tx <= 1;
                            ready <= 1;
                            state <= IDLE;
                        end
                    end
                end
            endcase
        end
    end
endmodule
