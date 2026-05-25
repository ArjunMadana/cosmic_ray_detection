`timescale 1ns / 1ps

`ifndef UART_BOOT_BANNER_V
`define UART_BOOT_BANNER_V

module uart_boot_banner (
    input  wire       clk,
    input  wire       rst,
    input  wire       uart_ready,
    output reg [7:0]  uart_data,
    output reg        uart_valid,
    output reg        active,
    output reg        done
);

localparam MSG_LEN = 4'd6;

reg [3:0] idx;

function [7:0] msg_byte;
    input [3:0] pos;
    begin
        case (pos)
            4'd0: msg_byte = "B";
            4'd1: msg_byte = "O";
            4'd2: msg_byte = "O";
            4'd3: msg_byte = "T";
            4'd4: msg_byte = 8'h0D;
            default: msg_byte = 8'h0A;
        endcase
    end
endfunction

always @(posedge clk) begin
    if (rst) begin
        idx        <= 0;
        uart_data  <= 0;
        uart_valid <= 0;
        active     <= 1'b1;
        done       <= 1'b0;
    end else if (!done) begin
        active <= 1'b1;

        if (uart_valid && !uart_ready) begin
            uart_valid <= 1'b1;
        end else begin
            uart_valid <= 1'b0;

            if (idx < MSG_LEN && uart_ready) begin
                uart_data  <= msg_byte(idx);
                uart_valid <= 1'b1;
                idx        <= idx + 1'b1;
            end else if (idx == MSG_LEN && uart_ready) begin
                active <= 1'b0;
                done   <= 1'b1;
            end
        end
    end else begin
        active     <= 1'b0;
        uart_valid <= 1'b0;
    end
end

endmodule

`endif
