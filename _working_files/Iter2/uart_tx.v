`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 03/05/2026 09:04:51 PM
// Design Name: 
// Module Name: uart_tx
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

module uart_tx #(
    parameter CLK_FREQ = 150_000_000,
    parameter BAUD_RATE = 115200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       valid,
    output reg        ready,
    output reg        tx
);

localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

reg [15:0] clk_cnt;
reg [3:0]  bit_idx;
reg [9:0]  shift_reg;
reg        busy;

always @(posedge clk) begin
    if (rst) begin
        tx      <= 1'b1;
        ready   <= 1'b1;
        busy    <= 1'b0;
        clk_cnt <= 0;
        bit_idx <= 0;
    end else if (!busy && valid) begin
        shift_reg <= {1'b1, data, 1'b0}; // stop, data, start
        busy      <= 1'b1;
        ready     <= 1'b0;
        clk_cnt   <= 0;
        bit_idx   <= 0;
    end else if (busy) begin
        if (clk_cnt == CLKS_PER_BIT - 1) begin
            clk_cnt <= 0;
            tx      <= shift_reg[bit_idx];
            if (bit_idx == 9) begin
                busy    <= 1'b0;
                ready   <= 1'b1;
            end else begin
                bit_idx <= bit_idx + 1;
            end
        end else begin
            clk_cnt <= clk_cnt + 1;
        end
    end
end

endmodule
