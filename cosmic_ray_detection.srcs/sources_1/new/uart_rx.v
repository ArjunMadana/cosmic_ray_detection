`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: uart_rx
// Description: Standard UART receiver.  Matches uart_tx parameters.
//              Outputs a 1-cycle valid pulse with the received byte.
//              CLK_FREQ must be set to the actual clock driving this module
//              (83_333_333 for ui_clk on this project).
//////////////////////////////////////////////////////////////////////////////////

module uart_rx #(
    parameter CLK_FREQ  = 83_333_333,
    parameter BAUD_RATE = 115_200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        valid   // 1-cycle pulse when a byte is ready
);

localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;  // 723

localparam IDLE  = 2'd0;
localparam START = 2'd1;
localparam DATA  = 2'd2;
localparam STOP  = 2'd3;

reg [1:0]  state;
reg [15:0] clk_cnt;  // 16-bit matches uart_tx.v, no overflow risk at any clock rate
reg [2:0]  bit_idx;
reg [7:0]  shift;

// 2-FF synchroniser to avoid metastability on the async RX pin
reg rx_s1, rx_sync;
always @(posedge clk) begin
    rx_s1   <= rx;
    rx_sync <= rx_s1;
end

always @(posedge clk) begin
    valid <= 1'b0;

    if (rst) begin
        state   <= IDLE;
        clk_cnt <= 0;
        bit_idx <= 0;
        shift   <= 0;
        data    <= 0;
    end else begin
        case (state)
            IDLE: begin
                clk_cnt <= 0;
                bit_idx <= 0;
                if (!rx_sync)           // falling edge = start bit
                    state <= START;
            end

            START: begin
                // Sample at the centre of the start bit
                if (clk_cnt == (CLKS_PER_BIT / 2) - 1) begin
                    if (!rx_sync) begin // still low: valid start bit
                        clk_cnt <= 0;
                        state   <= DATA;
                    end else begin
                        state   <= IDLE; // glitch — discard
                    end
                end else begin
                    clk_cnt <= clk_cnt + 1;
                end
            end

            DATA: begin
                if (clk_cnt == CLKS_PER_BIT - 1) begin
                    clk_cnt <= 0;
                    // Shift in LSB-first
                    shift   <= {rx_sync, shift[7:1]};
                    if (bit_idx == 7) begin
                        bit_idx <= 0;
                        state   <= STOP;
                    end else begin
                        bit_idx <= bit_idx + 1;
                    end
                end else begin
                    clk_cnt <= clk_cnt + 1;
                end
            end

            STOP: begin
                if (clk_cnt == CLKS_PER_BIT - 1) begin
                    clk_cnt <= 0;
                    state   <= IDLE;
                    if (rx_sync) begin  // stop bit high: valid frame
                        data  <= shift;
                        valid <= 1'b1;
                    end
                    // If stop bit is low (framing error): silently discard
                end else begin
                    clk_cnt <= clk_cnt + 1;
                end
            end
        endcase
    end
end

endmodule
