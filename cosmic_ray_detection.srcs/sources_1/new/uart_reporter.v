`timescale 1ns / 1ps

`ifndef UART_REPORTER_V
`define UART_REPORTER_V

module uart_reporter (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [3:0]  kind,
    output reg         busy,
    output reg         done,

    output reg  [7:0]  uart_data,
    output reg         uart_valid,
    input  wire        uart_ready,

    input  wire [3:0]  hold_dig3,
    input  wire [3:0]  hold_dig2,
    input  wire [3:0]  hold_dig1,
    input  wire [3:0]  hold_dig0,
    input  wire [1:0]  pattern_sel,
    input  wire [1:0]  fill_pattern_sel,
    input  wire [1:0]  refresh_sel,
    input  wire [12:0] addr_count,
    input  wire        addr_overflow,
    input  wire [27:0] addr_value,
    input wire [31:0] xor_mask,
    input  wire [31:0] flip_count,
    input  wire [11:0] temp_raw
);

localparam PK_READY    = 4'd0;
localparam PK_INT      = 4'd1;
localparam PK_PAT      = 4'd2;
localparam PK_REF      = 4'd3;
localparam PK_REPORT   = 4'd4;
localparam PK_ADDRHDR  = 4'd5;
localparam PK_TEMP     = 4'd6;
localparam PK_ADDRLINE = 4'd7;

reg [3:0]  active_kind;
reg [7:0]  idx;
reg [7:0]  active_len;
reg [3:0]  hold3_q;
reg [3:0]  hold2_q;
reg [3:0]  hold1_q;
reg [3:0]  hold0_q;
reg [1:0]  pattern_q;
reg [1:0]  fill_pattern_q;
reg [1:0]  refresh_q;
reg [12:0] addr_count_q;
reg        addr_overflow_q;
reg [27:0] addr_value_q;
reg [31:0] xor_mask_q;
reg [31:0] flip_count_q;
reg [11:0] temp_raw_q;

function [7:0] hex_digit;
    input [3:0] nibble;
    begin
        case (nibble)
            4'h0: hex_digit = "0"; 4'h1: hex_digit = "1";
            4'h2: hex_digit = "2"; 4'h3: hex_digit = "3";
            4'h4: hex_digit = "4"; 4'h5: hex_digit = "5";
            4'h6: hex_digit = "6"; 4'h7: hex_digit = "7";
            4'h8: hex_digit = "8"; 4'h9: hex_digit = "9";
            4'hA: hex_digit = "A"; 4'hB: hex_digit = "B";
            4'hC: hex_digit = "C"; 4'hD: hex_digit = "D";
            4'hE: hex_digit = "E"; default: hex_digit = "F";
        endcase
    end
endfunction

function [7:0] hex32_at;
    input [31:0] value;
    input [7:0] pos;
    begin
        case (pos[2:0])
            3'd0: hex32_at = hex_digit(value[31:28]);
            3'd1: hex32_at = hex_digit(value[27:24]);
            3'd2: hex32_at = hex_digit(value[23:20]);
            3'd3: hex32_at = hex_digit(value[19:16]);
            3'd4: hex32_at = hex_digit(value[15:12]);
            3'd5: hex32_at = hex_digit(value[11:8]);
            3'd6: hex32_at = hex_digit(value[7:4]);
            default: hex32_at = hex_digit(value[3:0]);
        endcase
    end
endfunction

function [7:0] hex28_at;
    input [27:0] value;
    input [7:0] pos;
    begin
        case (pos[2:0])
            3'd0: hex28_at = hex_digit(value[27:24]);
            3'd1: hex28_at = hex_digit(value[23:20]);
            3'd2: hex28_at = hex_digit(value[19:16]);
            3'd3: hex28_at = hex_digit(value[15:12]);
            3'd4: hex28_at = hex_digit(value[11:8]);
            3'd5: hex28_at = hex_digit(value[7:4]);
            default: hex28_at = hex_digit(value[3:0]);
        endcase
    end
endfunction

function [7:0] hex16_at;
    input [15:0] value;
    input [7:0] pos;
    begin
        case (pos[1:0])
            2'd0: hex16_at = hex_digit(value[15:12]);
            2'd1: hex16_at = hex_digit(value[11:8]);
            2'd2: hex16_at = hex_digit(value[7:4]);
            default: hex16_at = hex_digit(value[3:0]);
        endcase
    end
endfunction

function [7:0] pattern_char;
    input [1:0] pat;
    begin
        case (pat)
            2'd0: pattern_char = "F";
            2'd1: pattern_char = "0";
            2'd2: pattern_char = "5";
            default: pattern_char = "A";
        endcase
    end
endfunction

function [7:0] refresh_char;
    input [1:0] ref;
    input [1:0] pos;
    begin
        case (ref)
            2'd0: refresh_char = (pos == 0) ? "O" : (pos == 1) ? "F" : (pos == 2) ? "F" : " ";
            2'd1: refresh_char = (pos == 0) ? "S" : (pos == 1) ? "L" : (pos == 2) ? "O" : "W";
            2'd2: refresh_char = (pos == 0) ? "N" : (pos == 1) ? "O" : (pos == 2) ? "R" : "M";
            default: refresh_char = (pos == 0) ? "F" : (pos == 1) ? "A" : (pos == 2) ? "S" : "T";
        endcase
    end
endfunction

function [7:0] message_len;
    input [3:0] msg_kind;
    begin
        case (msg_kind)
            PK_READY:    message_len = 8'd7;
            PK_INT:      message_len = 8'd16;
            PK_PAT:      message_len = 8'd12;
            PK_REF:      message_len = 8'd14;
            PK_REPORT:   message_len = 8'd34;
            PK_ADDRHDR:  message_len = 8'd18;
            PK_TEMP:     message_len = 8'd10;
            PK_ADDRLINE: message_len = 8'd22;
            default:     message_len = 8'd2;
        endcase
    end
endfunction

function [7:0] byte_at;
    input [3:0] msg_kind;
    input [7:0] pos;
    begin
        byte_at = " ";
        case (msg_kind)
            PK_READY: begin
                case (pos)
                    8'd0: byte_at = "R"; 8'd1: byte_at = "E"; 8'd2: byte_at = "A";
                    8'd3: byte_at = "D"; 8'd4: byte_at = "Y"; 8'd5: byte_at = 8'h0D;
                    default: byte_at = 8'h0A;
                endcase
            end
            PK_INT: begin
                case (pos)
                    8'd0: byte_at = "I"; 8'd1: byte_at = "N"; 8'd2: byte_at = "T";
                    8'd3: byte_at = "E"; 8'd4: byte_at = "R"; 8'd5: byte_at = "V";
                    8'd6: byte_at = "A"; 8'd7: byte_at = "L"; 8'd8: byte_at = ":";
                    8'd9: byte_at = "0" + {4'd0, hold3_q};
                    8'd10: byte_at = "0" + {4'd0, hold2_q};
                    8'd11: byte_at = "0" + {4'd0, hold1_q};
                    8'd12: byte_at = "0" + {4'd0, hold0_q};
                    8'd13: byte_at = "s"; 8'd14: byte_at = 8'h0D;
                    default: byte_at = 8'h0A;
                endcase
            end
            PK_PAT: begin
                case (pos)
                    8'd0: byte_at = "P"; 8'd1: byte_at = "A"; 8'd2: byte_at = "T";
                    8'd3: byte_at = "T"; 8'd4: byte_at = "E"; 8'd5: byte_at = "R";
                    8'd6: byte_at = "N"; 8'd7: byte_at = ":";
                    8'd8: byte_at = pattern_char(pattern_q);
                    8'd9: byte_at = pattern_char(pattern_q);
                    8'd10: byte_at = 8'h0D;
                    default: byte_at = 8'h0A;
                endcase
            end
            PK_REF: begin
                case (pos)
                    8'd0: byte_at = "R"; 8'd1: byte_at = "E"; 8'd2: byte_at = "F";
                    8'd3: byte_at = "R"; 8'd4: byte_at = "E"; 8'd5: byte_at = "S";
                    8'd6: byte_at = "H"; 8'd7: byte_at = ":";
                    8'd8, 8'd9, 8'd10, 8'd11: byte_at = refresh_char(refresh_q, pos[1:0]);
                    8'd12: byte_at = 8'h0D;
                    default: byte_at = 8'h0A;
                endcase
            end
            PK_ADDRHDR: begin
                case (pos)
                    8'd0: byte_at = "A"; 8'd1: byte_at = "D"; 8'd2: byte_at = "D";
                    8'd3: byte_at = "R"; 8'd4: byte_at = "S"; 8'd5: byte_at = ":";
                    8'd6, 8'd7, 8'd8, 8'd9: byte_at = hex16_at({3'd0, addr_count_q}, pos - 8'd6);
                    8'd10: byte_at = " "; 8'd11: byte_at = "O"; 8'd12: byte_at = "V";
                    8'd13: byte_at = "F"; 8'd14: byte_at = ":";
                    8'd15: byte_at = addr_overflow_q ? "1" : "0";
                    8'd16: byte_at = 8'h0D;
                    default: byte_at = 8'h0A;
                endcase
            end
            PK_ADDRLINE: begin
                case (pos)
                    8'd0: byte_at = "E";
                    8'd1: byte_at = "R";
                    8'd2: byte_at = "R";
                    8'd3: byte_at = ":";
                    
                    8'd4, 8'd5, 8'd6, 8'd7, 8'd8, 8'd9, 8'd10:
                        byte_at = hex28_at(addr_value_q, pos - 8'd4);
                    
                    8'd11: byte_at = ":";
                    
                    8'd12, 8'd13, 8'd14, 8'd15, 8'd16, 8'd17, 8'd18, 8'd19:
                        byte_at = hex28_at(xor_mask_q, pos - 8'd12);
                        
                   8'd20: byte_at = 8'h0D;
                   default: byte_at = 8'h0A;
                endcase
            end
            PK_REPORT: begin
                case (pos)
                    8'd0: byte_at = "H"; 8'd1: byte_at = "O"; 8'd2: byte_at = "L";
                    8'd3: byte_at = "D"; 8'd4: byte_at = ":";
                    8'd5: byte_at = "0" + {4'd0, hold3_q};
                    8'd6: byte_at = "0" + {4'd0, hold2_q};
                    8'd7: byte_at = "0" + {4'd0, hold1_q};
                    8'd8: byte_at = "0" + {4'd0, hold0_q};
                    8'd9: byte_at = "s"; 8'd10: byte_at = " "; 8'd11: byte_at = "P";
                    8'd12: byte_at = "A"; 8'd13: byte_at = "T"; 8'd14: byte_at = ":";
                    8'd15: byte_at = pattern_char(fill_pattern_q);
                    8'd16: byte_at = pattern_char(fill_pattern_q);
                    8'd17: byte_at = " "; 8'd18: byte_at = "F"; 8'd19: byte_at = "L";
                    8'd20: byte_at = "I"; 8'd21: byte_at = "P"; 8'd22: byte_at = "S";
                    8'd23: byte_at = ":";
                    8'd24, 8'd25, 8'd26, 8'd27, 8'd28, 8'd29, 8'd30, 8'd31:
                        byte_at = hex32_at(flip_count_q, pos - 8'd24);
                    8'd32: byte_at = 8'h0D;
                    default: byte_at = 8'h0A;
                endcase
            end
            PK_TEMP: begin
                case (pos)
                    8'd0: byte_at = "T"; 8'd1: byte_at = "E"; 8'd2: byte_at = "M";
                    8'd3: byte_at = "P"; 8'd4: byte_at = ":";
                    8'd5: byte_at = hex_digit(temp_raw_q[11:8]);
                    8'd6: byte_at = hex_digit(temp_raw_q[7:4]);
                    8'd7: byte_at = hex_digit(temp_raw_q[3:0]);
                    8'd8: byte_at = 8'h0D;
                    default: byte_at = 8'h0A;
                endcase
            end
        endcase
    end
endfunction

always @(posedge clk) begin
    if (rst) begin
        busy       <= 0;
        done       <= 0;
        uart_data  <= 0;
        uart_valid <= 0;
        active_kind <= 0;
        active_len <= 0;
        idx        <= 0;
        xor_mask_q <= 0;
    end else begin
        done <= 0;

        if (uart_valid && !uart_ready) begin
            uart_valid <= 1;
        end else begin
            uart_valid <= 0;

            if (start && !busy) begin
                busy       <= 1;
                active_kind <= kind;
                active_len <= message_len(kind);
                idx        <= 1;
                uart_data  <= byte_at(kind, 8'd0);
                uart_valid <= 1;

                hold3_q <= hold_dig3;
                hold2_q <= hold_dig2;
                hold1_q <= hold_dig1;
                hold0_q <= hold_dig0;
                pattern_q <= pattern_sel;
                fill_pattern_q <= fill_pattern_sel;
                refresh_q <= refresh_sel;
                addr_count_q <= addr_count;
                addr_overflow_q <= addr_overflow;
                addr_value_q <= addr_value;
                xor_mask_q <= xor_mask;
                flip_count_q <= flip_count;
                temp_raw_q <= temp_raw;
            end else if (busy && uart_ready) begin
                if (idx < active_len) begin
                    uart_data  <= byte_at(active_kind, idx);
                    uart_valid <= 1;
                    idx        <= idx + 1;
                end else begin
                    busy <= 0;
                    done <= 1;
                end
            end
        end
    end
end

endmodule

`endif
