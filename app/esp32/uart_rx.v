module uart_rx(
    input clk,
    input rst,
    input rx,
    output reg [7:0] data,
    output reg valid
);
    parameter CLK_FREQ = 100_000_000;
    parameter BAUD_RATE = 115_200;
    localparam BAUD_COUNT = CLK_FREQ / BAUD_RATE;
    localparam HALF_BAUD = BAUD_COUNT / 2;

    reg [15:0] counter;
    reg [3:0] bit_count;
    reg [7:0] shift_reg;
    reg rx_sync_0, rx_sync_1, rx_sync;
    reg state;

    localparam IDLE = 0, RECEIVE = 1;

    always @(posedge clk) begin
        rx_sync_0 <= rx;
        rx_sync_1 <= rx_sync_0;
        rx_sync <= rx_sync_1;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            counter <= 0;
            bit_count <= 0;
            shift_reg <= 0;
            data <= 0;
            valid <= 0;
        end else begin
            valid <= 0;
            case (state)
                IDLE: begin
                    if (rx_sync == 0) begin
                        counter <= HALF_BAUD;
                        state <= RECEIVE;
                        bit_count <= 0;
                    end
                end
                RECEIVE: begin
                    if (counter > 0) begin
                        counter <= counter - 1;
                    end else begin
                        if (bit_count < 8) begin
                            shift_reg[bit_count] <= rx_sync;
                            bit_count <= bit_count + 1;
                            counter <= BAUD_COUNT;
                        end else begin
                            data <= shift_reg;
                            valid <= 1;
                            state <= IDLE;
                        end
                    end
                end
            endcase
        end
    end
endmodule
