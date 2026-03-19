`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 03/05/2026 09:07:06 PM
// Design Name: 
// Module Name: detector_fsm
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

module detector_fsm #(
    parameter MEM_SIZE = 28'h4000000
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        calib_complete,
    input  wire        sw0,
    input  wire        sw1,
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

    // UART output
    output reg  [7:0]  uart_data,
    output reg         uart_valid,
    input  wire        uart_ready,

    // Status
    output reg         led0,
    output reg         led1,

    // Buttons (btn0=K16=10s, btn1=J16=20s, btn2=H15=30s, default=5s)
    input wire         btn0,
    input wire         btn1,
    input wire         btn2,
    input wire         btn3
);

localparam REF_OFF    = 32'h0;
localparam REF_SLOW   = 32'd8_333_333;   // ~100 ms at 83.333 MHz
localparam REF_NORMAL = 32'd650;         // ~7.8 us (DDR3 spec) at 83.333 MHz
localparam REF_FAST   = 32'd325;         // ~3.9 us (2x normal rate) at 83.333 MHz

localparam WAIT_INIT = 3'd0;
localparam FILL      = 3'd1;
localparam HOLD      = 3'd2;
localparam SCAN      = 3'd3;
localparam REPORT    = 3'd4;
localparam SETTLE    = 3'd5;
localparam PRINT_REF = 3'd6;
localparam PRINT_INT = 3'd7;

localparam CYCLES_5S  = 64'd416_666_665;    // 5s  at 83.333 MHz
localparam CYCLES_10S = 64'd833_333_330;    // 10s at 83.333 MHz
localparam CYCLES_20S = 64'd1_666_666_660;  // 20s at 83.333 MHz
localparam CYCLES_30S = 64'd2_499_999_990;  // 30s at 83.333 MHz

reg [2:0]  state;
reg [27:0] addr;
reg [31:0] hit_counter;
reg [31:0] report_shift;
reg [4:0]  report_idx;   // widened to 5 bits
reg [63:0] hold_counter;
reg [63:0] hold_cycles_sel;
reg [1:0]  time_sel;     // 0=5s, 1=10s, 2=20s, 3=30s
reg [3:0] btn_prev;  // previous button state for edge detection

reg [31:0] refresh_counter;
reg [31:0] refresh_period;
reg [1:0]  refresh_sel;

reg [1:0]  sw_prev;
reg        sw_changed;
reg [1:0]  sw_print_val;

reg        btn_changed;

localparam PATTERN = 32'hFFFFFFFF;
//localparam PATTERN = 32'h00000000;

always @(posedge clk) begin
    if (rst) begin
        state          <= WAIT_INIT;
        addr           <= 0;
        hit_counter    <= 0;
        awvalid        <= 0;
        wvalid         <= 0;
        bready         <= 1;
        arvalid        <= 0;
        rready         <= 1;
        uart_valid     <= 0;
        led0           <= 0;
        led1           <= 0;
        hold_counter   <= 0;
        hold_cycles_sel <= CYCLES_5S;
        time_sel       <= 0;
        btn_prev       <= 4'b0;
        sw_prev        <= 2'b0;
        sw_changed     <= 0;
        sw_print_val   <= 2'b0;
        btn_changed    <= 0;
    end else begin
        led0 <= calib_complete;
        led1 <= (state != WAIT_INIT);

        // Button selection works in any state
        btn_prev <= {btn3, btn2, btn1, btn0};
        
        if (btn3 && !btn_prev[3]) begin
            hold_cycles_sel <= CYCLES_5S;
            time_sel        <= 0;
            btn_changed     <= 1;
        end else if (btn2 && !btn_prev[2]) begin
            hold_cycles_sel <= CYCLES_30S;
            time_sel        <= 3;
            btn_changed     <= 1;
        end else if (btn1 && !btn_prev[1]) begin
            hold_cycles_sel <= CYCLES_20S;
            time_sel        <= 2;
            btn_changed     <= 1;
        end else if (btn0 && !btn_prev[0]) begin
            hold_cycles_sel <= CYCLES_10S;
            time_sel        <= 1;
            btn_changed     <= 1;
        end
    
        // Switch change detection — works in any state
        sw_prev <= {sw1, sw0};
        if ({sw1, sw0} != sw_prev) begin
            sw_changed   <= 1;
            sw_print_val <= {sw1, sw0};
        end

        case (state)
            WAIT_INIT: begin
                if (calib_complete) begin
                    state <= FILL;
                    addr  <= 0;
                end
            end

            FILL: begin
                if (!awvalid && !wvalid && !bvalid) begin
                    awaddr  <= addr;
                    awvalid <= 1;
                    wdata   <= PATTERN;
                    wstrb   <= 4'hF;
                    wvalid  <= 1;
                end
                if (awvalid && awready) awvalid <= 0;
                if (wvalid  && wready)  wvalid  <= 0;
                if (bvalid) begin
                    if (addr >= MEM_SIZE - 4) begin
                        addr  <= 0;
                        state <= HOLD;
                    end else begin
                        addr <= addr + 4;
                    end
                end
            end

            HOLD: begin
                if (btn_changed) begin
                    btn_changed <= 0;
                    report_idx  <= 0;
                    state       <= PRINT_INT;
                end else if (sw_changed) begin
                    sw_changed <= 0;
                    report_idx <= 0;
                    state      <= PRINT_REF;
                end else if (hold_counter >= hold_cycles_sel) begin
                    state        <= SCAN;
                    addr         <= 0;
                    hit_counter  <= 0;
                    hold_counter <= 0;
                end else begin
                    hold_counter <= hold_counter + 1;
                end
            end

            SCAN: begin
                if (!arvalid && !rvalid) begin
                    araddr  <= addr;
                    arvalid <= 1;
                end
                if (arvalid && arready) arvalid <= 0;
                if (rvalid) begin
                    if (rdata != PATTERN)
                        hit_counter <= hit_counter + 1;
                    if (addr >= MEM_SIZE - 4) begin
                        state        <= REPORT;
                        report_shift <= hit_counter;
                        report_idx   <= 0;
                    end else begin
                        addr <= addr + 4;
                    end
                end
            end

            // Output format: "HOLD:05s FLIPS:XXXXXXXX\r\n"
            REPORT: begin
                if (uart_ready && !uart_valid) begin
                    report_idx <= report_idx + 1;

                    if (report_idx < 25)
                        uart_valid <= 1;

                    if      (report_idx == 0)  uart_data <= "H";
                    else if (report_idx == 1)  uart_data <= "O";
                    else if (report_idx == 2)  uart_data <= "L";
                    else if (report_idx == 3)  uart_data <= "D";
                    else if (report_idx == 4)  uart_data <= ":";
                    else if (report_idx == 5) begin
                        case (time_sel)
                            2'd0: uart_data <= "0"; // 05s
                            2'd1: uart_data <= "1"; // 10s
                            2'd2: uart_data <= "2"; // 20s
                            2'd3: uart_data <= "3"; // 30s
                        endcase
                    end
                    else if (report_idx == 6) begin
                        case (time_sel)
                            2'd0: uart_data <= "5"; // 05s
                            2'd1: uart_data <= "0"; // 10s
                            2'd2: uart_data <= "0"; // 20s
                            2'd3: uart_data <= "0"; // 30s
                        endcase
                    end
                    else if (report_idx == 7)  uart_data <= "s";
                    else if (report_idx == 8)  uart_data <= " ";
                    else if (report_idx == 9)  uart_data <= "F";
                    else if (report_idx == 10) uart_data <= "L";
                    else if (report_idx == 11) uart_data <= "I";
                    else if (report_idx == 12) uart_data <= "P";
                    else if (report_idx == 13) uart_data <= "S";
                    else if (report_idx == 14) uart_data <= ":";
                    else if (report_idx <= 22) begin  // idx 15-22: 8 hex digits
                        case (report_shift[31:28])
                            4'h0: uart_data <= "0"; 4'h1: uart_data <= "1";
                            4'h2: uart_data <= "2"; 4'h3: uart_data <= "3";
                            4'h4: uart_data <= "4"; 4'h5: uart_data <= "5";
                            4'h6: uart_data <= "6"; 4'h7: uart_data <= "7";
                            4'h8: uart_data <= "8"; 4'h9: uart_data <= "9";
                            4'hA: uart_data <= "A"; 4'hB: uart_data <= "B";
                            4'hC: uart_data <= "C"; 4'hD: uart_data <= "D";
                            4'hE: uart_data <= "E"; 4'hF: uart_data <= "F";
                        endcase
                        report_shift <= {report_shift[27:0], 4'b0};
                    end
                    else if (report_idx == 23) uart_data <= 8'h0D;
                    else if (report_idx == 24) uart_data <= 8'h0A;
                    else if (report_idx == 25) begin
                        uart_valid <= 0;
                        state      <= SETTLE;
                    end
                end else begin
                    uart_valid <= 0;
                end
            end

            SETTLE: begin
                // Wait for any in-flight AXI responses to drain
                awvalid     <= 0;
                wvalid      <= 0;
                arvalid     <= 0;
                if (!bvalid && !rvalid) begin
                    addr        <= 0;
                    hit_counter <= 0;
                    state       <= FILL;
                end
            end
            // Output format: "REFRESH:SLOW\r\n" (OFF /SLOW/NORM/FAST)
            PRINT_REF: begin
                if (uart_ready && !uart_valid) begin
                    report_idx <= report_idx + 1;

                    if (report_idx < 14)
                        uart_valid <= 1;

                    if      (report_idx == 0)  uart_data <= "R";
                    else if (report_idx == 1)  uart_data <= "E";
                    else if (report_idx == 2)  uart_data <= "F";
                    else if (report_idx == 3)  uart_data <= "R";
                    else if (report_idx == 4)  uart_data <= "E";
                    else if (report_idx == 5)  uart_data <= "S";
                    else if (report_idx == 6)  uart_data <= "H";
                    else if (report_idx == 7)  uart_data <= ":";
                    else if (report_idx == 8) begin
                        case (sw_print_val)
                            2'd0: uart_data <= "O"; // OFF
                            2'd1: uart_data <= "S"; // SLOW
                            2'd2: uart_data <= "N"; // NORM
                            2'd3: uart_data <= "F"; // FAST
                        endcase
                    end
                    else if (report_idx == 9) begin
                        case (sw_print_val)
                            2'd0: uart_data <= "F"; // OFF
                            2'd1: uart_data <= "L"; // SLOW
                            2'd2: uart_data <= "O"; // NORM
                            2'd3: uart_data <= "A"; // FAST
                        endcase
                    end
                    else if (report_idx == 10) begin
                        case (sw_print_val)
                            2'd0: uart_data <= "F"; // OFF
                            2'd1: uart_data <= "O"; // SLOW
                            2'd2: uart_data <= "R"; // NORM
                            2'd3: uart_data <= "S"; // FAST
                        endcase
                    end
                    else if (report_idx == 11) begin
                        case (sw_print_val)
                            2'd0: uart_data <= " "; // OFF  (pad to 4 chars)
                            2'd1: uart_data <= "W"; // SLOW
                            2'd2: uart_data <= "M"; // NORM
                            2'd3: uart_data <= "T"; // FAST
                        endcase
                    end
                    else if (report_idx == 12) uart_data <= 8'h0D;
                    else if (report_idx == 13) uart_data <= 8'h0A;
                    else if (report_idx == 14) begin
                        uart_valid <= 0;
                        state      <= HOLD;
                    end
                end else begin
                    uart_valid <= 0;
                end
            end

            // Output format: "INTERVAL:05s\r\n"
            PRINT_INT: begin
                if (uart_ready && !uart_valid) begin
                    report_idx <= report_idx + 1;

                    if (report_idx < 14)
                        uart_valid <= 1;

                    if      (report_idx == 0)  uart_data <= "I";
                    else if (report_idx == 1)  uart_data <= "N";
                    else if (report_idx == 2)  uart_data <= "T";
                    else if (report_idx == 3)  uart_data <= "E";
                    else if (report_idx == 4)  uart_data <= "R";
                    else if (report_idx == 5)  uart_data <= "V";
                    else if (report_idx == 6)  uart_data <= "A";
                    else if (report_idx == 7)  uart_data <= "L";
                    else if (report_idx == 8)  uart_data <= ":";
                    else if (report_idx == 9) begin
                        case (time_sel)
                            2'd0: uart_data <= "0"; // 05s
                            2'd1: uart_data <= "1"; // 10s
                            2'd2: uart_data <= "2"; // 20s
                            2'd3: uart_data <= "3"; // 30s
                        endcase
                    end
                    else if (report_idx == 10) begin
                        case (time_sel)
                            2'd0: uart_data <= "5"; // 05s
                            2'd1: uart_data <= "0"; // 10s
                            2'd2: uart_data <= "0"; // 20s
                            2'd3: uart_data <= "0"; // 30s
                        endcase
                    end
                    else if (report_idx == 11) uart_data <= "s";
                    else if (report_idx == 12) uart_data <= 8'h0D;
                    else if (report_idx == 13) uart_data <= 8'h0A;
                    else if (report_idx == 14) begin
                        uart_valid <= 0;
                        state      <= HOLD;
                    end
                end else begin
                    uart_valid <= 0;
                end
            end

        endcase
    end
end

// Refresh tick generator — runs independently of FSM state
always @(posedge clk) begin
    if (rst) begin
        refresh_counter  <= 0;
        refresh_tick_out <= 0;
        refresh_period   <= REF_OFF;
        refresh_sel      <= 0;
    end else begin
        refresh_sel <= {sw1, sw0};
        case (refresh_sel)
            2'd0: refresh_period <= REF_OFF;
            2'd1: refresh_period <= REF_SLOW;
            2'd2: refresh_period <= REF_NORMAL;
            2'd3: refresh_period <= REF_FAST;
        endcase

        refresh_tick_out <= 1'b0;  // default: single-cycle pulse
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