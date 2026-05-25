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
    parameter BAUD_RATE = 115_200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       valid,
    output reg        ready,
    output reg        tx
);

localparam CLKS_PER_BIT = CLK_FREQ / BAUD_RATE;

localparam ST_IDLE  = 2'd0;
localparam ST_START = 2'd1;
localparam ST_DATA  = 2'd2;
localparam ST_STOP  = 2'd3;

reg [1:0]  state;
reg [15:0] clk_cnt;
reg [2:0]  bit_idx;
reg [7:0]  data_latched;

always @(posedge clk) begin
    if (rst) begin
        state        <= ST_IDLE;
        tx           <= 1'b1;
        ready        <= 1'b1;
        clk_cnt      <= 0;
        bit_idx      <= 0;
        data_latched <= 8'h00;
    end else begin
        case (state)
            ST_IDLE: begin
                tx      <= 1'b1;
                ready   <= 1'b1;
                clk_cnt <= 0;
                bit_idx <= 0;

                if (valid) begin
                    data_latched <= data;
                    tx           <= 1'b0;
                    ready        <= 1'b0;
                    state        <= ST_START;
                end
            end

            ST_START: begin
                ready <= 1'b0;
                tx    <= 1'b0;
                if (clk_cnt == CLKS_PER_BIT - 1) begin
                    clk_cnt <= 0;
                    tx      <= data_latched[0];
                    state   <= ST_DATA;
                end else begin
                    clk_cnt <= clk_cnt + 1;
                end
            end

            ST_DATA: begin
                ready <= 1'b0;
                if (clk_cnt == CLKS_PER_BIT - 1) begin
                    clk_cnt <= 0;
                    if (bit_idx == 7) begin
                        bit_idx <= 0;
                        tx      <= 1'b1;
                        state   <= ST_STOP;
                    end else begin
                        bit_idx <= bit_idx + 1;
                        tx      <= data_latched[bit_idx + 1'b1];
                    end
                end else begin
                    clk_cnt <= clk_cnt + 1;
                end
            end

            ST_STOP: begin
                ready <= 1'b0;
                tx    <= 1'b1;
                if (clk_cnt == CLKS_PER_BIT - 1) begin
                    clk_cnt <= 0;
                    ready   <= 1'b1;
                    state   <= ST_IDLE;
                end else begin
                    clk_cnt <= clk_cnt + 1;
                end
            end

            default: begin
                state   <= ST_IDLE;
                tx      <= 1'b1;
                ready   <= 1'b1;
                clk_cnt <= 0;
                bit_idx <= 0;
            end
        endcase
    end
end

endmodule
