`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: detector_fsm
// Description: Main FSM for DRAM bit-flip detection.
//
// UART commands from the GUI:
//   H<seconds>\n  Set hold time, 1-9999 seconds.
//   P<0-3>\n      Set pattern: 0=FF, 1=00, 2=55, 3=AA.
//   R<0-3>\n      Set refresh: 0=OFF, 1=SLOW, 2=NORM, 3=FAST.
//   G             Start from WAIT_GO.
//   X             Abort current cycle and return to WAIT_GO.
//////////////////////////////////////////////////////////////////////////////////

module detector_fsm #(
    parameter MEM_SIZE  = 28'h4000000,
    parameter UI_CLK_HZ = 32'd166_666_667
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        calib_complete,
    output reg         refresh_tick_out,

    // AXI Write Address
    output reg  [27:0] awaddr,
    output reg         awvalid,
    input  wire        awready,

    // AXI Write Data
    output reg  [31:0] wdata,
    output reg  [3:0]  wstrb,
    output reg         wvalid,
    input  wire        wready,

    // AXI Write Response
    input  wire [1:0]  bresp,
    input  wire        bvalid,
    output reg         bready,

    // AXI Read Address
    output reg  [27:0] araddr,
    output reg         arvalid,
    input  wire        arready,

    // AXI Read Data
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,
    input  wire        rvalid,
    output reg         rready,

    // UART TX output
    output reg  [7:0]  uart_data,
    output reg         uart_valid,
    input  wire        uart_ready,

    // UART RX input (from laptop)
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,

    // Status
    output reg         led0,
    output reg         led1,

    // On-chip die temperature from MIG XADC (12-bit ADC code)
    // temp_C = raw * 503.975 / 4096 - 273.15
    input wire [11:0]  temp_raw
);

localparam [31:0] HOLD_SECOND_TICKS    = UI_CLK_HZ - 1;
localparam [31:0] REF_OFF              = 32'd0;
localparam [31:0] REF_SLOW             = UI_CLK_HZ / 32'd10;      // ~100 ms
localparam [31:0] REF_NORMAL           = UI_CLK_HZ / 32'd128205;  // ~7.8 us
localparam [31:0] REF_FAST             = UI_CLK_HZ / 32'd256410;  // ~3.9 us

localparam WAIT_INIT    = 5'd0;
localparam WAIT_GO      = 5'd1;
localparam FILL         = 5'd2;
localparam FILL2        = 5'd3;
localparam HOLD         = 5'd4;
localparam SCAN         = 5'd5;
localparam STREAM_ADDRS = 5'd6;
localparam PRINT        = 5'd7;
localparam PRINT_TEMP   = 5'd8;
localparam PRINT_DIAG   = 5'd9;
localparam SETTLE       = 5'd10;

localparam PK_READY   = 4'd0;
localparam PK_INT     = 4'd1;
localparam PK_PAT     = 4'd2;
localparam PK_REF     = 4'd3;
localparam PK_REPORT  = 4'd4;
localparam PK_ADDRHDR = 4'd5;
localparam PK_TEMP    = 4'd6;
localparam PK_DIAG    = 4'd7;

localparam CMD_NONE = 2'd0;
localparam CMD_H    = 2'd1;
localparam CMD_P    = 2'd2;
localparam CMD_R    = 2'd3;

localparam ADDR_BUF_CAPACITY = 13'd4096;

// pattern_sel: 0=0xFFFFFFFF, 1=0x00000000, 2=0x55555555, 3=0xAAAAAAAA
reg [1:0] pattern_sel;
reg [1:0] fill_pattern_sel;
wire [31:0] active_pattern;
assign active_pattern = (fill_pattern_sel == 2'd0) ? 32'hFFFFFFFF :
                        (fill_pattern_sel == 2'd1) ? 32'h00000000 :
                        (fill_pattern_sel == 2'd2) ? 32'h55555555 :
                                                     32'hAAAAAAAA;

reg [4:0]  state;
reg [27:0] addr;
reg [31:0] hit_counter;
reg [31:0] report_shift;
reg [11:0] temp_shift;
reg [31:0] hold_tick_counter;
reg [15:0] hold_sec_counter;
reg [15:0] hold_sec_val;

reg [31:0] refresh_counter;
reg [31:0] refresh_period;
reg [1:0]  refresh_sel;
reg [1:0]  refresh_print_sel;

reg [1:0]  cmd_kind;
reg [15:0] cmd_acc;
reg [3:0]  cmd_digit;
reg [3:0]  cmd_dig3;
reg [3:0]  cmd_dig2;
reg [3:0]  cmd_dig1;
reg [3:0]  cmd_dig0;
reg [3:0]  hold_dig3;
reg [3:0]  hold_dig2;
reg [3:0]  hold_dig1;
reg [3:0]  hold_dig0;

reg        interval_changed;
reg        pat_changed;
reg        refresh_changed;
reg        go_flag;
reg        reset_flag;

reg [27:0] addr_buf [0:4095];
reg [12:0] buf_count;
reg [12:0] buf_rd_count;
reg [11:0] buf_rd_ptr;
reg [27:0] buf_stream_word;
reg        stream_body;
reg        addr_overflow;
reg [31:0] addr_overflow_count;

reg [31:0] fill1_resp_count;
reg [31:0] fill2_resp_count;
reg [31:0] scan_resp_count;
reg [31:0] bresp_error_count;
reg [31:0] rresp_error_count;
reg [27:0] first_bad_addr;
reg [31:0] first_bad_got;
reg [31:0] first_bad_exp;
reg        first_bad_valid;
reg        mismatch_pending;
reg [27:0] mismatch_addr;
reg [31:0] mismatch_got;
reg [31:0] mismatch_exp;
reg        scan_done_pending;
reg [31:0] scan_done_hits;

reg [7:0]  print_idx;
reg [7:0]  print_len;
reg [4:0]  print_next_state;
reg [3:0]  print_kind;
reg [1:0]  print_wait;

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
        hex32_at = hex_digit((value >> ((7 - pos[2:0]) * 4)) & 4'hF);
    end
endfunction

function [7:0] hex28_at;
    input [27:0] value;
    input [7:0] pos;
    begin
        hex28_at = hex_digit((value >> ((6 - pos[2:0]) * 4)) & 4'hF);
    end
endfunction

function [7:0] hex16_at;
    input [15:0] value;
    input [7:0] pos;
    begin
        hex16_at = hex_digit((value >> ((3 - pos[1:0]) * 4)) & 4'hF);
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

function [7:0] print_byte;
    input [3:0] kind;
    input [7:0] idx;
    begin
        print_byte = " ";
        case (kind)
            PK_READY: begin
                if      (idx == 0) print_byte = "R";
                else if (idx == 1) print_byte = "E";
                else if (idx == 2) print_byte = "A";
                else if (idx == 3) print_byte = "D";
                else if (idx == 4) print_byte = "Y";
                else if (idx == 5) print_byte = 8'h0D;
                else               print_byte = 8'h0A;
            end

            PK_INT: begin
                if      (idx == 0)  print_byte = "I";
                else if (idx == 1)  print_byte = "N";
                else if (idx == 2)  print_byte = "T";
                else if (idx == 3)  print_byte = "E";
                else if (idx == 4)  print_byte = "R";
                else if (idx == 5)  print_byte = "V";
                else if (idx == 6)  print_byte = "A";
                else if (idx == 7)  print_byte = "L";
                else if (idx == 8)  print_byte = ":";
                else if (idx == 9)  print_byte = "0" + {4'd0, hold_dig3};
                else if (idx == 10) print_byte = "0" + {4'd0, hold_dig2};
                else if (idx == 11) print_byte = "0" + {4'd0, hold_dig1};
                else if (idx == 12) print_byte = "0" + {4'd0, hold_dig0};
                else if (idx == 13) print_byte = "s";
                else if (idx == 14) print_byte = 8'h0D;
                else                print_byte = 8'h0A;
            end

            PK_PAT: begin
                if      (idx == 0)  print_byte = "P";
                else if (idx == 1)  print_byte = "A";
                else if (idx == 2)  print_byte = "T";
                else if (idx == 3)  print_byte = "T";
                else if (idx == 4)  print_byte = "E";
                else if (idx == 5)  print_byte = "R";
                else if (idx == 6)  print_byte = "N";
                else if (idx == 7)  print_byte = ":";
                else if (idx == 8)  print_byte = pattern_char(pattern_sel);
                else if (idx == 9)  print_byte = pattern_char(pattern_sel);
                else if (idx == 10) print_byte = 8'h0D;
                else                print_byte = 8'h0A;
            end

            PK_REF: begin
                if      (idx == 0)  print_byte = "R";
                else if (idx == 1)  print_byte = "E";
                else if (idx == 2)  print_byte = "F";
                else if (idx == 3)  print_byte = "R";
                else if (idx == 4)  print_byte = "E";
                else if (idx == 5)  print_byte = "S";
                else if (idx == 6)  print_byte = "H";
                else if (idx == 7)  print_byte = ":";
                else if (idx >= 8 && idx <= 11) print_byte = refresh_char(refresh_print_sel, idx[1:0]);
                else if (idx == 12) print_byte = 8'h0D;
                else                print_byte = 8'h0A;
            end

            PK_ADDRHDR: begin
                if      (idx == 0)  print_byte = "A";
                else if (idx == 1)  print_byte = "D";
                else if (idx == 2)  print_byte = "D";
                else if (idx == 3)  print_byte = "R";
                else if (idx == 4)  print_byte = "S";
                else if (idx == 5)  print_byte = ":";
                else if (idx >= 6 && idx <= 9) print_byte = hex16_at({3'd0, buf_count}, idx - 6);
                else if (idx == 10) print_byte = " ";
                else if (idx == 11) print_byte = "O";
                else if (idx == 12) print_byte = "V";
                else if (idx == 13) print_byte = "F";
                else if (idx == 14) print_byte = ":";
                else if (idx == 15) print_byte = addr_overflow ? "1" : "0";
                else if (idx == 16) print_byte = 8'h0D;
                else                print_byte = 8'h0A;
            end

            PK_REPORT: begin
                if      (idx == 0)  print_byte = "H";
                else if (idx == 1)  print_byte = "O";
                else if (idx == 2)  print_byte = "L";
                else if (idx == 3)  print_byte = "D";
                else if (idx == 4)  print_byte = ":";
                else if (idx == 5)  print_byte = "0" + {4'd0, hold_dig3};
                else if (idx == 6)  print_byte = "0" + {4'd0, hold_dig2};
                else if (idx == 7)  print_byte = "0" + {4'd0, hold_dig1};
                else if (idx == 8)  print_byte = "0" + {4'd0, hold_dig0};
                else if (idx == 9)  print_byte = "s";
                else if (idx == 10) print_byte = " ";
                else if (idx == 11) print_byte = "P";
                else if (idx == 12) print_byte = "A";
                else if (idx == 13) print_byte = "T";
                else if (idx == 14) print_byte = ":";
                else if (idx == 15) print_byte = pattern_char(fill_pattern_sel);
                else if (idx == 16) print_byte = pattern_char(fill_pattern_sel);
                else if (idx == 17) print_byte = " ";
                else if (idx == 18) print_byte = "F";
                else if (idx == 19) print_byte = "L";
                else if (idx == 20) print_byte = "I";
                else if (idx == 21) print_byte = "P";
                else if (idx == 22) print_byte = "S";
                else if (idx == 23) print_byte = ":";
                else if (idx >= 24 && idx <= 31) print_byte = hex32_at(report_shift, idx - 24);
                else if (idx == 32) print_byte = 8'h0D;
                else                print_byte = 8'h0A;
            end

            PK_TEMP: begin
                if      (idx == 0) print_byte = "T";
                else if (idx == 1) print_byte = "E";
                else if (idx == 2) print_byte = "M";
                else if (idx == 3) print_byte = "P";
                else if (idx == 4) print_byte = ":";
                else if (idx == 5) print_byte = hex_digit(temp_shift[11:8]);
                else if (idx == 6) print_byte = hex_digit(temp_shift[7:4]);
                else if (idx == 7) print_byte = hex_digit(temp_shift[3:0]);
                else if (idx == 8) print_byte = 8'h0D;
                else               print_byte = 8'h0A;
            end

            PK_DIAG: begin
                if      (idx == 0)   print_byte = "D";
                else if (idx == 1)   print_byte = "I";
                else if (idx == 2)   print_byte = "A";
                else if (idx == 3)   print_byte = "G";
                else if (idx == 4)   print_byte = ":";
                else if (idx == 5)   print_byte = "F";
                else if (idx == 6)   print_byte = "1";
                else if (idx == 7)   print_byte = ":";
                else if (idx >= 8  && idx <= 15)  print_byte = hex32_at(fill1_resp_count, idx - 8);
                else if (idx == 16)  print_byte = " ";
                else if (idx == 17)  print_byte = "F";
                else if (idx == 18)  print_byte = "2";
                else if (idx == 19)  print_byte = ":";
                else if (idx >= 20 && idx <= 27)  print_byte = hex32_at(fill2_resp_count, idx - 20);
                else if (idx == 28)  print_byte = " ";
                else if (idx == 29)  print_byte = "S";
                else if (idx == 30)  print_byte = "C";
                else if (idx == 31)  print_byte = ":";
                else if (idx >= 32 && idx <= 39)  print_byte = hex32_at(scan_resp_count, idx - 32);
                else if (idx == 40)  print_byte = " ";
                else if (idx == 41)  print_byte = "B";
                else if (idx == 42)  print_byte = "E";
                else if (idx == 43)  print_byte = "R";
                else if (idx == 44)  print_byte = "R";
                else if (idx == 45)  print_byte = ":";
                else if (idx >= 46 && idx <= 53)  print_byte = hex32_at(bresp_error_count, idx - 46);
                else if (idx == 54)  print_byte = " ";
                else if (idx == 55)  print_byte = "R";
                else if (idx == 56)  print_byte = "E";
                else if (idx == 57)  print_byte = "R";
                else if (idx == 58)  print_byte = "R";
                else if (idx == 59)  print_byte = ":";
                else if (idx >= 60 && idx <= 67)  print_byte = hex32_at(rresp_error_count, idx - 60);
                else if (idx == 68)  print_byte = " ";
                else if (idx == 69)  print_byte = "B";
                else if (idx == 70)  print_byte = "A";
                else if (idx == 71)  print_byte = "D";
                else if (idx == 72)  print_byte = ":";
                else if (idx >= 73 && idx <= 79)  print_byte = first_bad_valid ? hex28_at(first_bad_addr, idx - 73) : "X";
                else if (idx == 80)  print_byte = " ";
                else if (idx == 81)  print_byte = "G";
                else if (idx == 82)  print_byte = "O";
                else if (idx == 83)  print_byte = "T";
                else if (idx == 84)  print_byte = ":";
                else if (idx >= 85 && idx <= 92)  print_byte = first_bad_valid ? hex32_at(first_bad_got, idx - 85) : "X";
                else if (idx == 93)  print_byte = " ";
                else if (idx == 94)  print_byte = "E";
                else if (idx == 95)  print_byte = "X";
                else if (idx == 96)  print_byte = "P";
                else if (idx == 97)  print_byte = ":";
                else if (idx >= 98 && idx <= 105) print_byte = first_bad_valid ? hex32_at(first_bad_exp, idx - 98) : "X";
                else if (idx == 106) print_byte = " ";
                else if (idx == 107) print_byte = "O";
                else if (idx == 108) print_byte = "V";
                else if (idx == 109) print_byte = "F";
                else if (idx == 110) print_byte = ":";
                else if (idx == 111) print_byte = addr_overflow ? "1" : "0";
                else if (idx == 112) print_byte = 8'h0D;
                else                 print_byte = 8'h0A;
            end
        endcase
    end
endfunction

always @(posedge clk) begin
    if (rst) begin
        state               <= WAIT_INIT;
        addr                <= 0;
        hit_counter         <= 0;
        awvalid             <= 0;
        wvalid              <= 0;
        bready              <= 1;
        arvalid             <= 0;
        rready              <= 1;
        uart_valid          <= 0;
        led0                <= 0;
        led1                <= 0;
        hold_tick_counter   <= 0;
        hold_sec_counter    <= 0;
        hold_sec_val        <= 16'd5;
        refresh_sel         <= 2'd0;
        refresh_print_sel   <= 2'd0;
        cmd_kind            <= CMD_NONE;
        cmd_acc             <= 0;
        cmd_digit           <= 0;
        cmd_dig3            <= 0;
        cmd_dig2            <= 0;
        cmd_dig1            <= 0;
        cmd_dig0            <= 0;
        hold_dig3           <= 0;
        hold_dig2           <= 0;
        hold_dig1           <= 0;
        hold_dig0           <= 5;
        interval_changed    <= 0;
        pat_changed         <= 0;
        refresh_changed     <= 0;
        pattern_sel         <= 2'd0;
        fill_pattern_sel    <= 2'd0;
        go_flag             <= 0;
        reset_flag          <= 0;
        buf_count           <= 0;
        buf_rd_count        <= 0;
        buf_rd_ptr          <= 0;
        buf_stream_word     <= 0;
        stream_body         <= 0;
        addr_overflow       <= 0;
        addr_overflow_count <= 0;
        fill1_resp_count    <= 0;
        fill2_resp_count    <= 0;
        scan_resp_count     <= 0;
        bresp_error_count   <= 0;
        rresp_error_count   <= 0;
        first_bad_addr      <= 0;
        first_bad_got       <= 0;
        first_bad_exp       <= 0;
        first_bad_valid     <= 0;
        mismatch_pending    <= 0;
        mismatch_addr       <= 0;
        mismatch_got        <= 0;
        mismatch_exp        <= 0;
        scan_done_pending   <= 0;
        scan_done_hits      <= 0;
        report_shift        <= 0;
        temp_shift          <= 0;
        print_idx           <= 0;
        print_len           <= 0;
        print_next_state    <= WAIT_GO;
        print_kind          <= PK_READY;
        print_wait          <= 0;
    end else begin
        led0 <= calib_complete;
        led1 <= (state != WAIT_INIT);

        if (rx_valid) begin
            if (rx_data == "G") begin
                go_flag <= 1;
            end else if (rx_data == "X") begin
                reset_flag <= 1;
            end else if (rx_data == "H") begin
                cmd_kind <= CMD_H;
                cmd_acc  <= 0;
                cmd_dig3 <= 0;
                cmd_dig2 <= 0;
                cmd_dig1 <= 0;
                cmd_dig0 <= 0;
            end else if (rx_data == "P") begin
                cmd_kind <= CMD_P;
            end else if (rx_data == "R") begin
                cmd_kind <= CMD_R;
            end else if (rx_data >= "0" && rx_data <= "9") begin
                cmd_digit <= rx_data[3:0];
                if (cmd_kind == CMD_H) begin
                    if (cmd_acc < 16'd1000) begin
                        cmd_acc <= (cmd_acc * 10) + {12'd0, rx_data[3:0]};
                        cmd_dig3 <= cmd_dig2;
                        cmd_dig2 <= cmd_dig1;
                        cmd_dig1 <= cmd_dig0;
                        cmd_dig0 <= rx_data[3:0];
                    end
                end else if (cmd_kind == CMD_P && rx_data <= "3") begin
                    pattern_sel <= rx_data[1:0];
                end else if (cmd_kind == CMD_R && rx_data <= "3") begin
                    refresh_sel       <= rx_data[1:0];
                    refresh_print_sel <= rx_data[1:0];
                end
            end else if (rx_data == 8'h0A) begin
                if (cmd_kind == CMD_H && cmd_acc > 0) begin
                    hold_sec_val    <= cmd_acc;
                    hold_dig3       <= cmd_dig3;
                    hold_dig2       <= cmd_dig2;
                    hold_dig1       <= cmd_dig1;
                    hold_dig0       <= cmd_dig0;
                    interval_changed <= 1;
                end else if (cmd_kind == CMD_P) begin
                    pat_changed <= 1;
                end else if (cmd_kind == CMD_R) begin
                    refresh_changed <= 1;
                end
                cmd_kind <= CMD_NONE;
            end else if (rx_data != 8'h0D) begin
                cmd_kind <= CMD_NONE;
            end
        end

        if (reset_flag) begin
            reset_flag       <= 0;
            go_flag          <= 0;
            hit_counter      <= 0;
            hold_tick_counter <= 0;
            hold_sec_counter <= 0;
            addr             <= 0;
            awvalid          <= 0;
            wvalid           <= 0;
            arvalid          <= 0;
            uart_valid       <= 0;
            print_idx        <= 0;
            buf_count        <= 0;
            buf_rd_count     <= 0;
            buf_rd_ptr       <= 0;
            buf_stream_word  <= 0;
            stream_body      <= 0;
            mismatch_pending <= 0;
            scan_done_pending <= 0;
            state            <= PRINT;
            print_kind       <= PK_READY;
            print_len        <= 8'd7;
            print_idx        <= 0;
            print_wait       <= 2;
            print_next_state <= WAIT_GO;
        end else begin
            case (state)
                WAIT_INIT: begin
                    if (calib_complete) begin
                        state            <= PRINT;
                        print_kind       <= PK_READY;
                        print_len        <= 8'd7;
                        print_idx        <= 0;
                        print_wait       <= 2;
                        print_next_state <= WAIT_GO;
                    end
                end

                WAIT_GO: begin
                    if (interval_changed) begin
                        interval_changed <= 0;
                        state            <= PRINT;
                        print_kind       <= PK_INT;
                        print_len        <= 8'd16;
                        print_idx        <= 0;
                        print_wait       <= 2;
                        print_next_state <= WAIT_GO;
                    end else if (pat_changed) begin
                        pat_changed      <= 0;
                        state            <= PRINT;
                        print_kind       <= PK_PAT;
                        print_len        <= 8'd12;
                        print_idx        <= 0;
                        print_wait       <= 2;
                        print_next_state <= WAIT_GO;
                    end else if (refresh_changed) begin
                        refresh_changed  <= 0;
                        state            <= PRINT;
                        print_kind       <= PK_REF;
                        print_len        <= 8'd14;
                        print_idx        <= 0;
                        print_wait       <= 2;
                        print_next_state <= WAIT_GO;
                    end else if (go_flag) begin
                        go_flag             <= 0;
                        fill_pattern_sel    <= pattern_sel;
                        addr                <= 0;
                        hold_tick_counter   <= 0;
                        hold_sec_counter    <= 0;
                        fill1_resp_count    <= 0;
                        fill2_resp_count    <= 0;
                        scan_resp_count     <= 0;
                        bresp_error_count   <= 0;
                        rresp_error_count   <= 0;
                        first_bad_valid     <= 0;
                        mismatch_pending    <= 0;
                        scan_done_pending   <= 0;
                        addr_overflow       <= 0;
                        addr_overflow_count <= 0;
                        buf_count           <= 0;
                        state               <= FILL;
                    end
                end

                FILL: begin
                    if (!awvalid && !wvalid && !bvalid) begin
                        awaddr  <= addr;
                        awvalid <= 1;
                        wdata   <= active_pattern;
                        wstrb   <= 4'hF;
                        wvalid  <= 1;
                    end
                    if (awvalid && awready) awvalid <= 0;
                    if (wvalid  && wready)  wvalid  <= 0;
                    if (bvalid) begin
                        fill1_resp_count <= fill1_resp_count + 1;
                        if (bresp != 2'b00) bresp_error_count <= bresp_error_count + 1;
                        if (addr >= MEM_SIZE - 4) begin
                            addr  <= 0;
                            state <= FILL2;
                        end else begin
                            addr <= addr + 4;
                        end
                    end
                end

                FILL2: begin
                    if (!awvalid && !wvalid && !bvalid) begin
                        awaddr  <= addr;
                        awvalid <= 1;
                        wdata   <= active_pattern;
                        wstrb   <= 4'hF;
                        wvalid  <= 1;
                    end
                    if (awvalid && awready) awvalid <= 0;
                    if (wvalid  && wready)  wvalid  <= 0;
                    if (bvalid) begin
                        fill2_resp_count <= fill2_resp_count + 1;
                        if (bresp != 2'b00) bresp_error_count <= bresp_error_count + 1;
                        if (addr >= MEM_SIZE - 4) begin
                            addr  <= 0;
                            state <= HOLD;
                        end else begin
                            addr <= addr + 4;
                        end
                    end
                end

                HOLD: begin
                    if (interval_changed) begin
                        interval_changed <= 0;
                        state            <= PRINT;
                        print_kind       <= PK_INT;
                        print_len        <= 8'd16;
                        print_idx        <= 0;
                        print_wait       <= 2;
                        print_next_state <= HOLD;
                    end else if (pat_changed) begin
                        pat_changed      <= 0;
                        state            <= PRINT;
                        print_kind       <= PK_PAT;
                        print_len        <= 8'd12;
                        print_idx        <= 0;
                        print_wait       <= 2;
                        print_next_state <= HOLD;
                    end else if (refresh_changed) begin
                        refresh_changed  <= 0;
                        state            <= PRINT;
                        print_kind       <= PK_REF;
                        print_len        <= 8'd14;
                        print_idx        <= 0;
                        print_wait       <= 2;
                        print_next_state <= HOLD;
                    end else if (hold_sec_counter >= hold_sec_val) begin
                        state               <= SCAN;
                        addr                <= 0;
                        hit_counter         <= 0;
                        hold_tick_counter   <= 0;
                        hold_sec_counter    <= 0;
                        buf_count           <= 0;
                        addr_overflow       <= 0;
                        addr_overflow_count <= 0;
                        mismatch_pending    <= 0;
                        scan_done_pending   <= 0;
                    end else if (hold_tick_counter >= HOLD_SECOND_TICKS) begin
                        hold_tick_counter <= 0;
                        hold_sec_counter  <= hold_sec_counter + 1;
                    end else begin
                        hold_tick_counter <= hold_tick_counter + 1;
                    end
                end

                SCAN: begin
                    if (mismatch_pending) begin
                        mismatch_pending <= 0;
                        hit_counter      <= hit_counter + 1;
                        if (!first_bad_valid) begin
                            first_bad_valid <= 1;
                            first_bad_addr  <= mismatch_addr;
                            first_bad_got   <= mismatch_got;
                            first_bad_exp   <= mismatch_exp;
                        end
                        if (buf_count < ADDR_BUF_CAPACITY) begin
                            addr_buf[buf_count[11:0]] <= mismatch_addr;
                            buf_count                 <= buf_count + 1;
                        end else begin
                            addr_overflow       <= 1;
                            addr_overflow_count <= addr_overflow_count + 1;
                        end
                    end else if (scan_done_pending) begin
                        scan_done_pending <= 0;
                        state             <= STREAM_ADDRS;
                        report_shift      <= scan_done_hits;
                        print_kind        <= PK_ADDRHDR;
                        print_len         <= 8'd18;
                        print_idx         <= 0;
                        print_wait        <= 2;
                        buf_rd_count      <= 0;
                        buf_rd_ptr        <= 0;
                        buf_stream_word   <= 0;
                        stream_body       <= 0;
                    end else begin
                        if (!arvalid && !rvalid) begin
                            araddr  <= addr;
                            arvalid <= 1;
                        end
                        if (arvalid && arready) arvalid <= 0;
                        if (rvalid) begin
                            scan_resp_count <= scan_resp_count + 1;
                            if (rresp != 2'b00) rresp_error_count <= rresp_error_count + 1;
                            if (rdata != active_pattern) begin
                                mismatch_pending <= 1;
                                mismatch_addr    <= addr;
                                mismatch_got     <= rdata;
                                mismatch_exp     <= active_pattern;
                            end
                            if (addr >= MEM_SIZE - 4) begin
                                scan_done_pending <= 1;
                                scan_done_hits    <= (rdata != active_pattern) ? hit_counter + 1 : hit_counter;
                            end else begin
                                addr <= addr + 4;
                            end
                        end
                    end
                end

                STREAM_ADDRS: begin
                    if (!stream_body && print_wait != 0) begin
                        uart_valid <= 0;
                        print_wait <= print_wait - 1;
                    end else if (uart_ready && !uart_valid) begin
                        if (!stream_body) begin
                            if (print_idx < print_len) begin
                                uart_data  <= print_byte(PK_ADDRHDR, print_idx);
                                uart_valid <= 1;
                                print_idx  <= print_idx + 1;
                            end else begin
                                uart_valid <= 0;
                                print_idx  <= 0;
                                if (buf_count == 0) begin
                                    state            <= PRINT;
                                    print_kind       <= PK_REPORT;
                                    print_len        <= 8'd34;
                                    print_wait       <= 2;
                                    print_next_state <= PRINT_TEMP;
                                end else begin
                                    stream_body <= 1;
                                end
                            end
                        end else begin
                            if (print_idx == 0) begin
                                buf_stream_word <= addr_buf[buf_rd_ptr];
                                uart_valid      <= 0;
                                print_idx       <= 1;
                            end else if (print_idx >= 1 && print_idx <= 7) begin
                                uart_valid      <= 1;
                                uart_data       <= hex_digit(buf_stream_word[27:24]);
                                buf_stream_word <= {buf_stream_word[23:0], 4'b0};
                                print_idx       <= print_idx + 1;
                            end else if (print_idx == 8) begin
                                uart_valid <= 1;
                                uart_data  <= 8'h0D;
                                print_idx  <= 9;
                            end else if (print_idx == 9) begin
                                uart_valid <= 1;
                                uart_data  <= 8'h0A;
                                if (buf_rd_count + 1 >= buf_count) begin
                                    stream_body      <= 0;
                                    print_idx        <= 0;
                                    report_shift     <= hit_counter;
                                    state            <= PRINT;
                                    print_kind       <= PK_REPORT;
                                    print_len        <= 8'd34;
                                    print_wait       <= 2;
                                    print_next_state <= PRINT_TEMP;
                                end else begin
                                    buf_rd_count <= buf_rd_count + 1;
                                    buf_rd_ptr   <= buf_rd_ptr + 1;
                                    print_idx    <= 0;
                                end
                            end
                        end
                    end else begin
                        uart_valid <= 0;
                    end
                end

                PRINT: begin
                    if (print_wait != 0) begin
                        uart_valid <= 0;
                        print_wait <= print_wait - 1;
                    end else if (uart_ready && !uart_valid) begin
                        if (print_idx < print_len) begin
                            uart_data  <= print_byte(print_kind, print_idx);
                            uart_valid <= 1;
                            print_idx  <= print_idx + 1;
                        end else begin
                            uart_valid <= 0;
                            print_idx  <= 0;
                            state      <= print_next_state;
                        end
                    end else begin
                        uart_valid <= 0;
                    end
                end

                PRINT_TEMP: begin
                    temp_shift       <= temp_raw;
                    state            <= PRINT;
                    print_kind       <= PK_TEMP;
                    print_len        <= 8'd10;
                    print_idx        <= 0;
                    print_wait       <= 2;
                    print_next_state <= PRINT_DIAG;
                end

                PRINT_DIAG: begin
                    state            <= PRINT;
                    print_kind       <= PK_DIAG;
                    print_len        <= 8'd114;
                    print_idx        <= 0;
                    print_wait       <= 2;
                    print_next_state <= SETTLE;
                end

                SETTLE: begin
                    awvalid <= 0;
                    wvalid  <= 0;
                    arvalid <= 0;
                    mismatch_pending  <= 0;
                    scan_done_pending <= 0;
                    if (!bvalid && !rvalid) begin
                        addr             <= 0;
                        hit_counter      <= 0;
                        hold_tick_counter <= 0;
                        hold_sec_counter <= 0;
                        fill_pattern_sel <= pattern_sel;
                        fill1_resp_count <= 0;
                        fill2_resp_count <= 0;
                        scan_resp_count  <= 0;
                        bresp_error_count <= 0;
                        rresp_error_count <= 0;
                        addr_overflow_count <= 0;
                        first_bad_valid  <= 0;
                        state            <= FILL;
                    end
                end

                default: state <= WAIT_INIT;
            endcase
        end
    end
end

always @(posedge clk) begin
    if (rst) begin
        refresh_counter  <= 0;
        refresh_tick_out <= 0;
        refresh_period   <= REF_OFF;
    end else begin
        case (refresh_sel)
            2'd0: refresh_period <= REF_OFF;
            2'd1: refresh_period <= REF_SLOW;
            2'd2: refresh_period <= REF_NORMAL;
            2'd3: refresh_period <= REF_FAST;
        endcase

        refresh_tick_out <= 1'b0;
        if (refresh_period != 0) begin
            if (refresh_counter >= refresh_period) begin
                refresh_counter  <= 0;
                refresh_tick_out <= 1'b1;
            end else begin
                refresh_counter <= refresh_counter + 1;
            end
        end else begin
            refresh_counter <= 0;
        end
    end
end

endmodule
