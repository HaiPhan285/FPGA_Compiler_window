module top(
    input clk,
    input rst,
    input uart_rx,
    output uart_tx
);
    wire [7:0] rx_data;
    wire rx_valid;
    reg [7:0] tx_data;
    reg tx_valid;
    wire tx_ready;

    uart_rx rx_inst(
        .clk(clk),
        .rst(rst),
        .rx(uart_rx),
        .data(rx_data),
        .valid(rx_valid)
    );

    uart_tx tx_inst(
        .clk(clk),
        .rst(rst),
        .data(tx_data),
        .valid(tx_valid),
        .tx(uart_tx),
        .ready(tx_ready)
    );

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tx_data <= 0;
            tx_valid <= 0;
        end else begin
            if (rx_valid) begin
                tx_data <= rx_data;
                tx_valid <= 1;
            end else if (tx_ready) begin
                tx_valid <= 0;
            end
        end
    end
endmodule
