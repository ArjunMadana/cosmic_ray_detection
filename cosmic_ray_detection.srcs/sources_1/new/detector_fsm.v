`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: detector_fsm
// Description: Main FSM for DRAM bit-flip detection.
//              Hold time can be set via physical buttons (fallback) or by
//              sending an ASCII command over UART RX: "H<seconds>\n"
//              e.g. "H45\n" sets a 45-second hold.  Range: 1-9999 seconds.
//
//              UART output format:
//                HOLD:NNNNs FLIPS:XXXXXXXX\r\n   (27 bytes, NNNN = 4-digit decimal)
//                REFRESH:XXXX\r\n
//                INTERVAL:NNNNs\r\n
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

    // Buttons (btn0=K16=10s, btn1=J16=20s, btn2=H15=30s, btn3=G15=5s default)
    input wire         btn0,
    input wire         btn1,
    input wire         btn2,
    input wire         btn3,

    // On-chip die temperature from MIG XADC (12-bit ADC code)
    // temp_C = raw * 503.975 / 4096 - 273.15
    input wire [11:0]  temp_raw
);

localparam REF_OFF    = 32'h0;
localparam REF_SLOW   = 32'd8_333_333;   // ~100 ms at 83.333 MHz
localparam REF_NORMAL = 32'd650;         // ~7.8 us (DDR3 spec) at 83.333 MHz
localparam REF_FAST   = 32'd325;         // ~3.9 us (2x normal rate) at 83.333 MHz

localparam WAIT_INIT  = 4'd0;
localparam FILL       = 4'd1;
localparam HOLD       = 4'd2;
localparam SCAN       = 4'd3;
localparam REPORT     = 4'd4;
localparam SETTLE     = 4'd5;
localparam PRINT_REF  = 4'd6;
localparam PRINT_INT  = 4'd7;
localparam PRINT_PAT  = 4'd8;
localparam FILL2        = 4'd9;  // second write pass to ensure all cells are written
localparam STREAM_ADDRS = 4'd10; // streams flip addresses over UART before REPORT
localparam PRINT_READY  = 4'd12; // sends READY\r\n after MIG calibration
localparam WAIT_GO      = 4'd13; // idles until G command received from Python
localparam PRINT_TEMP   = 4'd14; // sends TEMP:XXX\r\n after each REPORT

localparam CYCLES_5S  = 64'd416_666_665;    // 5s  at 83.333 MHz
localparam CYCLES_10S = 64'd833_333_330;    // 10s at 83.333 MHz
localparam CYCLES_20S = 64'd1_666_666_660;  // 20s at 83.333 MHz
localparam CYCLES_30S = 64'd2_499_999_990;  // 30s at 83.333 MHz

localparam CLK_PER_SEC = 64'd150_000_000;   // ui_clk frequency (matches uart_tx CLK_FREQ)

// pattern_sel: 0=0xFFFFFFFF, 1=0x00000000, 2=0x55555555, 3=0xAAAAAAAA
// pattern_sel can change any time; fill_pattern_sel is latched at the
// start of each FILL state and held constant through HOLD→SCAN→REPORT.
reg [1:0] pattern_sel;
reg [1:0] fill_pattern_sel;  // latched copy used for current FILL/SCAN cycle
wire [31:0] active_pattern;
assign active_pattern = (fill_pattern_sel == 2'd0) ? 32'hFFFFFFFF :
                        (fill_pattern_sel == 2'd1) ? 32'h00000000 :
                        (fill_pattern_sel == 2'd2) ? 32'h55555555 :
                                                     32'hAAAAAAAA;

reg [4:0]  state;
reg [27:0] addr;
reg [31:0] hit_counter;
reg [31:0] report_shift;
reg [11:0] temp_shift;   // latched temp_raw at start of PRINT_TEMP
reg [5:0]  report_idx;  // must hold up to 34 (new REPORT is 34 bytes)
reg [63:0] hold_counter;
reg [63:0] hold_cycles_sel;

// Hold time in whole seconds (1-9999).  Buttons set known values;
// UART command sets any value in range.
reg [15:0] hold_sec_val;

reg [3:0]  btn_prev;
reg        btn_changed;

reg [31:0] refresh_counter;
reg [31:0] refresh_period;
reg [1:0]  refresh_sel;

reg [1:0]  sw_prev;
reg        sw_changed;
reg [1:0]  sw_print_val;

// UART RX command parser state
reg        cmd_active;    // currently inside an 'H...' command
reg [15:0] cmd_acc;       // accumulates decimal digit value

reg        pcmd_active;   // currently inside a 'P...' command
reg        pat_changed;   // triggers PRINT_PAT confirmation state

reg        go_flag;       // set by G command — starts cycle from WAIT_GO
reg        reset_flag;    // set by X command — aborts any state, returns to PRINT_READY

// Flip address BRAM buffer — filled during SCAN, streamed in STREAM_ADDRS
reg [27:0] addr_buf [0:4095];  // 4096 × 28-bit words (~16 KB BRAM)
reg [11:0] buf_wr_ptr;         // write pointer (SCAN)
reg [11:0] buf_rd_ptr;         // read pointer (STREAM_ADDRS)
reg [11:0] buf_count;          // addresses stored this cycle (max 4095)
reg        stream_body;        // 0=sending header, 1=sending address body

// Combinational BCD breakdown of hold_sec_val for printing
wire [3:0] dig3 = hold_sec_val / 1000;
wire [3:0] dig2 = (hold_sec_val % 1000) / 100;
wire [3:0] dig1 = (hold_sec_val % 100) / 10;
wire [3:0] dig0 = hold_sec_val % 10;

always @(posedge clk) begin
    if (rst) begin
        state           <= WAIT_INIT;
        addr            <= 0;
        hit_counter     <= 0;
        awvalid         <= 0;
        wvalid          <= 0;
        bready          <= 1;
        arvalid         <= 0;
        rready          <= 1;
        uart_valid      <= 0;
        led0            <= 0;
        led1            <= 0;
        hold_counter    <= 0;
        hold_cycles_sel <= CYCLES_5S;
        hold_sec_val    <= 16'd5;
        btn_prev        <= 4'b0;
        sw_prev         <= 2'b0;
        sw_changed      <= 0;
        sw_print_val    <= 2'b0;
        btn_changed     <= 0;
        cmd_active      <= 0;
        cmd_acc         <= 0;
        pcmd_active      <= 0;
        pat_changed      <= 0;
        pattern_sel      <= 2'd0;
        fill_pattern_sel <= 2'd0;
        go_flag          <= 0;
        reset_flag       <= 0;
        buf_wr_ptr       <= 0;
        buf_rd_ptr       <= 0;
        buf_count        <= 0;
        stream_body      <= 0;
        temp_shift       <= 12'd0;
    end else begin
        led0 <= calib_complete;
        led1 <= (state != WAIT_INIT);

        // ----------------------------------------------------------------
        // Button edge detection — works in any state
        // ----------------------------------------------------------------
        btn_prev <= {btn3, btn2, btn1, btn0};

        if (btn3 && !btn_prev[3]) begin
            hold_sec_val    <= 16'd5;
            hold_cycles_sel <= CYCLES_5S;
            btn_changed     <= 1;
        end else if (btn2 && !btn_prev[2]) begin
            hold_sec_val    <= 16'd30;
            hold_cycles_sel <= CYCLES_30S;
            btn_changed     <= 1;
        end else if (btn1 && !btn_prev[1]) begin
            hold_sec_val    <= 16'd20;
            hold_cycles_sel <= CYCLES_20S;
            btn_changed     <= 1;
        end else if (btn0 && !btn_prev[0]) begin
            hold_sec_val    <= 16'd10;
            hold_cycles_sel <= CYCLES_10S;
            btn_changed     <= 1;
        end

        // ----------------------------------------------------------------
        // UART RX command parser — "H<decimal_seconds>\n"
        // Operates independently of FSM state.
        // ----------------------------------------------------------------
        if (rx_valid) begin
            if (rx_data == "H") begin
                cmd_active <= 1;
                cmd_acc    <= 0;
            end else if (cmd_active && rx_data >= "0" && rx_data <= "9") begin
                // Accept up to 4 digits (max 9999)
                if (cmd_acc < 16'd1000)
                    cmd_acc <= (cmd_acc * 10) + {12'd0, rx_data[3:0]};
            end else if (cmd_active && rx_data == 8'h0A) begin  // '\n'
                cmd_active <= 0;
                if (cmd_acc > 0) begin
                    hold_sec_val    <= cmd_acc;
                    hold_cycles_sel <= cmd_acc * CLK_PER_SEC;
                    btn_changed     <= 1;   // triggers PRINT_INT confirmation
                end
            end else if (rx_data != 8'h0D) begin  // ignore '\r', cancel on anything else
                cmd_active <= 0;
            end
        end

        // ----------------------------------------------------------------
        // UART RX pattern command — "P<0-3>\n"
        // ----------------------------------------------------------------
        if (rx_valid) begin
            if (rx_data == "P") begin
                pcmd_active <= 1;
            end else if (pcmd_active && rx_data >= "0" && rx_data <= "3") begin
                pattern_sel <= rx_data[1:0];
            end else if (pcmd_active && rx_data == 8'h0A) begin  // '\n'
                pcmd_active <= 0;
                pat_changed <= 1;
            end else if (rx_data != 8'h0D) begin
                pcmd_active <= 0;
            end
        end

        // ----------------------------------------------------------------
        // Single-byte commands: G = go (start from WAIT_GO), X = reset to WAIT_GO
        // ----------------------------------------------------------------
        if (rx_valid) begin
            if (rx_data == "G") go_flag    <= 1;
            if (rx_data == "X") reset_flag <= 1;
        end

        // ----------------------------------------------------------------
        // Switch change detection — works in any state
        // ----------------------------------------------------------------
        sw_prev <= {sw1, sw0};
        if ({sw1, sw0} != sw_prev) begin
            sw_changed   <= 1;
            sw_print_val <= {sw1, sw0};
        end

        // ----------------------------------------------------------------
        // FSM — reset_flag can interrupt any state and return to PRINT_READY
        // ----------------------------------------------------------------
        if (reset_flag) begin
            reset_flag  <= 0;
            go_flag     <= 0;
            hit_counter <= 0;
            addr        <= 0;
            awvalid     <= 0;
            wvalid      <= 0;
            arvalid     <= 0;
            report_idx  <= 0;
            buf_wr_ptr  <= 0;
            buf_rd_ptr  <= 0;
            buf_count   <= 0;
            stream_body <= 0;
            state       <= PRINT_READY;
        end else case (state)
            WAIT_INIT: begin
                if (calib_complete) begin
                    state      <= PRINT_READY;
                    report_idx <= 0;
                end
            end

            PRINT_READY: begin
                if (uart_ready && !uart_valid) begin
                    report_idx <= report_idx + 1;
                    if (report_idx < 7) uart_valid <= 1;
                    if      (report_idx == 0) uart_data <= "R";
                    else if (report_idx == 1) uart_data <= "E";
                    else if (report_idx == 2) uart_data <= "A";
                    else if (report_idx == 3) uart_data <= "D";
                    else if (report_idx == 4) uart_data <= "Y";
                    else if (report_idx == 5) uart_data <= 8'h0D;
                    else if (report_idx == 6) uart_data <= 8'h0A;
                    else if (report_idx == 7) begin
                        uart_valid <= 0;
                        state      <= WAIT_GO;
                    end
                end else begin
                    uart_valid <= 0;
                end
            end

            WAIT_GO: begin
                if (go_flag) begin
                    go_flag          <= 0;
                    fill_pattern_sel <= pattern_sel;
                    addr             <= 0;
                    state            <= FILL;
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
                end else if (pat_changed) begin
                    pat_changed <= 0;
                    report_idx  <= 0;
                    state       <= PRINT_PAT;
                end else if (hold_counter >= hold_cycles_sel) begin
                    state        <= SCAN;
                    addr         <= 0;
                    hit_counter  <= 0;
                    hold_counter <= 0;
                    buf_wr_ptr   <= 0;
                    buf_count    <= 0;
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
                    if (rdata != active_pattern) begin
                        hit_counter <= hit_counter + 1;
                        if (buf_count < 12'd4095) begin
                            addr_buf[buf_wr_ptr] <= addr;
                            buf_wr_ptr           <= buf_wr_ptr + 1;
                            buf_count            <= buf_count + 1;
                        end
                    end
                    if (addr >= MEM_SIZE - 4) begin
                        state        <= STREAM_ADDRS;
                        report_shift <= hit_counter;
                        report_idx   <= 0;
                        buf_rd_ptr   <= 0;
                        stream_body  <= 0;
                    end else begin
                        addr <= addr + 4;
                    end
                end
            end

            // Output format: "ADDRS:NNNN\r\n" header (12 bytes) then one "XXXXXXX\r\n" per address (9 bytes each)
            // NNNN = 4 hex digits of buf_count (always "0" in top digit since max = 4095 = 0x0FFF)
            // XXXXXXX = 7 hex digits of 28-bit byte address
            // Timing: buf_rd_ptr was set (SCAN→STREAM_ADDRS) before header starts.
            //         BRAM output addr_buf[buf_rd_ptr] is valid by the time body phase begins.
            //         In body: idx=0 loads shift register, idx=1-7 transmit 7 nibbles, idx=8 CR, idx=9 LF+advance.
            STREAM_ADDRS: begin
                if (uart_ready && !uart_valid) begin
                    if (!stream_body) begin
                        // ---- HEADER: ADDRS:NNNN\r\n ----
                        report_idx <= report_idx + 1;
                        if (report_idx < 12) uart_valid <= 1;
                        if      (report_idx == 0)  uart_data <= "A";
                        else if (report_idx == 1)  uart_data <= "D";
                        else if (report_idx == 2)  uart_data <= "D";
                        else if (report_idx == 3)  uart_data <= "R";
                        else if (report_idx == 4)  uart_data <= "S";
                        else if (report_idx == 5)  uart_data <= ":";
                        else if (report_idx == 6)  uart_data <= "0";  // top nibble always 0 (max 4095)
                        else if (report_idx == 7) begin
                            case (buf_count[11:8])
                                4'h0: uart_data <= "0"; 4'h1: uart_data <= "1";
                                4'h2: uart_data <= "2"; 4'h3: uart_data <= "3";
                                4'h4: uart_data <= "4"; 4'h5: uart_data <= "5";
                                4'h6: uart_data <= "6"; 4'h7: uart_data <= "7";
                                4'h8: uart_data <= "8"; 4'h9: uart_data <= "9";
                                4'hA: uart_data <= "A"; 4'hB: uart_data <= "B";
                                4'hC: uart_data <= "C"; 4'hD: uart_data <= "D";
                                4'hE: uart_data <= "E"; 4'hF: uart_data <= "F";
                            endcase
                        end
                        else if (report_idx == 8) begin
                            case (buf_count[7:4])
                                4'h0: uart_data <= "0"; 4'h1: uart_data <= "1";
                                4'h2: uart_data <= "2"; 4'h3: uart_data <= "3";
                                4'h4: uart_data <= "4"; 4'h5: uart_data <= "5";
                                4'h6: uart_data <= "6"; 4'h7: uart_data <= "7";
                                4'h8: uart_data <= "8"; 4'h9: uart_data <= "9";
                                4'hA: uart_data <= "A"; 4'hB: uart_data <= "B";
                                4'hC: uart_data <= "C"; 4'hD: uart_data <= "D";
                                4'hE: uart_data <= "E"; 4'hF: uart_data <= "F";
                            endcase
                        end
                        else if (report_idx == 9) begin
                            case (buf_count[3:0])
                                4'h0: uart_data <= "0"; 4'h1: uart_data <= "1";
                                4'h2: uart_data <= "2"; 4'h3: uart_data <= "3";
                                4'h4: uart_data <= "4"; 4'h5: uart_data <= "5";
                                4'h6: uart_data <= "6"; 4'h7: uart_data <= "7";
                                4'h8: uart_data <= "8"; 4'h9: uart_data <= "9";
                                4'hA: uart_data <= "A"; 4'hB: uart_data <= "B";
                                4'hC: uart_data <= "C"; 4'hD: uart_data <= "D";
                                4'hE: uart_data <= "E"; 4'hF: uart_data <= "F";
                            endcase
                        end
                        else if (report_idx == 10) uart_data <= 8'h0D;
                        else if (report_idx == 11) uart_data <= 8'h0A;
                        else if (report_idx == 12) begin
                            uart_valid <= 0;
                            report_idx <= 0;
                            if (buf_count == 0) begin
                                report_shift <= hit_counter;  // restore for REPORT
                                state        <= REPORT;
                            end else begin
                                stream_body <= 1;
                            end
                        end
                    end else begin
                        // ---- BODY: one "XXXXXXX\r\n" per address ----
                        // idx=0: load shift register from BRAM output (no transmit)
                        // idx=1-7: transmit 7 hex nibbles MSB-first
                        // idx=8: CR, idx=9: LF + advance buf_rd_ptr
                        // idx=10: transition to next address or REPORT
                        if (report_idx == 0) begin
                            report_shift <= {4'd0, addr_buf[buf_rd_ptr]};
                            uart_valid   <= 0;
                            report_idx   <= 1;
                        end else if (report_idx >= 1 && report_idx <= 7) begin
                            uart_valid   <= 1;
                            case (report_shift[27:24])
                                4'h0: uart_data <= "0"; 4'h1: uart_data <= "1";
                                4'h2: uart_data <= "2"; 4'h3: uart_data <= "3";
                                4'h4: uart_data <= "4"; 4'h5: uart_data <= "5";
                                4'h6: uart_data <= "6"; 4'h7: uart_data <= "7";
                                4'h8: uart_data <= "8"; 4'h9: uart_data <= "9";
                                4'hA: uart_data <= "A"; 4'hB: uart_data <= "B";
                                4'hC: uart_data <= "C"; 4'hD: uart_data <= "D";
                                4'hE: uart_data <= "E"; 4'hF: uart_data <= "F";
                            endcase
                            report_shift <= {report_shift[23:0], 4'b0};
                            report_idx   <= report_idx + 1;
                        end else if (report_idx == 8) begin
                            uart_valid <= 1;
                            uart_data  <= 8'h0D;
                            report_idx <= 9;
                        end else if (report_idx == 9) begin
                            uart_valid <= 1;
                            uart_data  <= 8'h0A;
                            buf_rd_ptr <= buf_rd_ptr + 1;
                            report_idx <= 10;
                        end else if (report_idx == 10) begin
                            uart_valid <= 0;
                            report_idx <= 0;
                            if (buf_rd_ptr >= buf_count) begin
                                stream_body  <= 0;
                                report_shift <= hit_counter;  // restore for REPORT
                                state        <= REPORT;
                            end
                        end
                    end
                end else begin
                    uart_valid <= 0;
                end
            end

            // Output format: "HOLD:NNNNs PAT:XX FLIPS:XXXXXXXX\r\n"  (33 bytes)
            // NNNN = 4-digit zero-padded decimal hold time in seconds
            // XX   = pattern label: FF, 00, 55, AA
            REPORT: begin
                if (uart_ready && !uart_valid) begin
                    report_idx <= report_idx + 1;

                    if (report_idx < 33)
                        uart_valid <= 1;

                    if      (report_idx == 0)  uart_data <= "H";
                    else if (report_idx == 1)  uart_data <= "O";
                    else if (report_idx == 2)  uart_data <= "L";
                    else if (report_idx == 3)  uart_data <= "D";
                    else if (report_idx == 4)  uart_data <= ":";
                    else if (report_idx == 5)  uart_data <= "0" + {4'd0, dig3};
                    else if (report_idx == 6)  uart_data <= "0" + {4'd0, dig2};
                    else if (report_idx == 7)  uart_data <= "0" + {4'd0, dig1};
                    else if (report_idx == 8)  uart_data <= "0" + {4'd0, dig0};
                    else if (report_idx == 9)  uart_data <= "s";
                    else if (report_idx == 10) uart_data <= " ";
                    else if (report_idx == 11) uart_data <= "P";
                    else if (report_idx == 12) uart_data <= "A";
                    else if (report_idx == 13) uart_data <= "T";
                    else if (report_idx == 14) uart_data <= ":";
                    // idx 15-16: two ASCII hex chars for pattern label
                    else if (report_idx == 15) begin
                        case (fill_pattern_sel)
                            2'd0: uart_data <= "F";
                            2'd1: uart_data <= "0";
                            2'd2: uart_data <= "5";
                            2'd3: uart_data <= "A";
                        endcase
                    end
                    else if (report_idx == 16) begin
                        case (fill_pattern_sel)
                            2'd0: uart_data <= "F";
                            2'd1: uart_data <= "0";
                            2'd2: uart_data <= "5";
                            2'd3: uart_data <= "A";
                        endcase
                    end
                    else if (report_idx == 17) uart_data <= " ";
                    else if (report_idx == 18) uart_data <= "F";
                    else if (report_idx == 19) uart_data <= "L";
                    else if (report_idx == 20) uart_data <= "I";
                    else if (report_idx == 21) uart_data <= "P";
                    else if (report_idx == 22) uart_data <= "S";
                    else if (report_idx == 23) uart_data <= ":";
                    else if (report_idx <= 31) begin  // idx 24-31: 8 hex digits
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
                    else if (report_idx == 32) uart_data <= 8'h0D;
                    else if (report_idx == 33) begin
                        uart_data  <= 8'h0A;
                        uart_valid <= 1;
                    end
                    else if (report_idx == 34) begin
                        uart_valid <= 0;
                        report_idx <= 0;
                        temp_shift <= temp_raw;
                        state      <= PRINT_TEMP;
                    end
                end else begin
                    uart_valid <= 0;
                end
            end

            SETTLE: begin
                awvalid <= 0;
                wvalid  <= 0;
                arvalid <= 0;
                if (!bvalid && !rvalid) begin
                    addr             <= 0;
                    hit_counter      <= 0;
                    fill_pattern_sel <= pattern_sel;  // latch pending pattern for next cycle
                    state            <= FILL;
                end
            end

            // Output format: "REFRESH:SLOW\r\n"  (OFF/SLOW/NORM/FAST)
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

            // Output format: "INTERVAL:NNNNs\r\n"  (16 bytes)
            PRINT_INT: begin
                if (uart_ready && !uart_valid) begin
                    report_idx <= report_idx + 1;

                    if (report_idx < 16)
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
                    else if (report_idx == 9)  uart_data <= "0" + {4'd0, dig3};
                    else if (report_idx == 10) uart_data <= "0" + {4'd0, dig2};
                    else if (report_idx == 11) uart_data <= "0" + {4'd0, dig1};
                    else if (report_idx == 12) uart_data <= "0" + {4'd0, dig0};
                    else if (report_idx == 13) uart_data <= "s";
                    else if (report_idx == 14) uart_data <= 8'h0D;
                    else if (report_idx == 15) uart_data <= 8'h0A;
                    else if (report_idx == 16) begin
                        uart_valid <= 0;
                        state      <= HOLD;
                    end
                end else begin
                    uart_valid <= 0;
                end
            end

            // Output format: "PATTERN:XX\r\n"  (12 bytes)
            // XX = FF, 00, 55, AA
            PRINT_PAT: begin
                if (uart_ready && !uart_valid) begin
                    report_idx <= report_idx + 1;

                    if (report_idx < 12)
                        uart_valid <= 1;

                    if      (report_idx == 0)  uart_data <= "P";
                    else if (report_idx == 1)  uart_data <= "A";
                    else if (report_idx == 2)  uart_data <= "T";
                    else if (report_idx == 3)  uart_data <= "T";
                    else if (report_idx == 4)  uart_data <= "E";
                    else if (report_idx == 5)  uart_data <= "R";
                    else if (report_idx == 6)  uart_data <= "N";
                    else if (report_idx == 7)  uart_data <= ":";
                    else if (report_idx == 8) begin
                        case (pattern_sel)
                            2'd0: uart_data <= "F";
                            2'd1: uart_data <= "0";
                            2'd2: uart_data <= "5";
                            2'd3: uart_data <= "A";
                        endcase
                    end
                    else if (report_idx == 9) begin
                        case (pattern_sel)
                            2'd0: uart_data <= "F";
                            2'd1: uart_data <= "0";
                            2'd2: uart_data <= "5";
                            2'd3: uart_data <= "A";
                        endcase
                    end
                    else if (report_idx == 10) uart_data <= 8'h0D;
                    else if (report_idx == 11) uart_data <= 8'h0A;
                    else if (report_idx == 12) begin
                        uart_valid <= 0;
                        state      <= HOLD;
                    end
                end else begin
                    uart_valid <= 0;
                end
            end

            // Output format: "TEMP:XXX\r\n"  (10 bytes)
            // XXX = 3 hex digits of 12-bit XADC die temperature
            // Python converts to °C: raw * 503.975 / 4096 - 273.15
            PRINT_TEMP: begin
                if (uart_ready && !uart_valid) begin
                    report_idx <= report_idx + 1;

                    if (report_idx < 10)
                        uart_valid <= 1;

                    if      (report_idx == 0) uart_data <= "T";
                    else if (report_idx == 1) uart_data <= "E";
                    else if (report_idx == 2) uart_data <= "M";
                    else if (report_idx == 3) uart_data <= "P";
                    else if (report_idx == 4) uart_data <= ":";
                    else if (report_idx == 5) begin
                        case (temp_shift[11:8])
                            4'h0: uart_data <= "0"; 4'h1: uart_data <= "1";
                            4'h2: uart_data <= "2"; 4'h3: uart_data <= "3";
                            4'h4: uart_data <= "4"; 4'h5: uart_data <= "5";
                            4'h6: uart_data <= "6"; 4'h7: uart_data <= "7";
                            4'h8: uart_data <= "8"; 4'h9: uart_data <= "9";
                            4'hA: uart_data <= "A"; 4'hB: uart_data <= "B";
                            4'hC: uart_data <= "C"; 4'hD: uart_data <= "D";
                            4'hE: uart_data <= "E"; 4'hF: uart_data <= "F";
                        endcase
                    end
                    else if (report_idx == 6) begin
                        case (temp_shift[7:4])
                            4'h0: uart_data <= "0"; 4'h1: uart_data <= "1";
                            4'h2: uart_data <= "2"; 4'h3: uart_data <= "3";
                            4'h4: uart_data <= "4"; 4'h5: uart_data <= "5";
                            4'h6: uart_data <= "6"; 4'h7: uart_data <= "7";
                            4'h8: uart_data <= "8"; 4'h9: uart_data <= "9";
                            4'hA: uart_data <= "A"; 4'hB: uart_data <= "B";
                            4'hC: uart_data <= "C"; 4'hD: uart_data <= "D";
                            4'hE: uart_data <= "E"; 4'hF: uart_data <= "F";
                        endcase
                    end
                    else if (report_idx == 7) begin
                        case (temp_shift[3:0])
                            4'h0: uart_data <= "0"; 4'h1: uart_data <= "1";
                            4'h2: uart_data <= "2"; 4'h3: uart_data <= "3";
                            4'h4: uart_data <= "4"; 4'h5: uart_data <= "5";
                            4'h6: uart_data <= "6"; 4'h7: uart_data <= "7";
                            4'h8: uart_data <= "8"; 4'h9: uart_data <= "9";
                            4'hA: uart_data <= "A"; 4'hB: uart_data <= "B";
                            4'hC: uart_data <= "C"; 4'hD: uart_data <= "D";
                            4'hE: uart_data <= "E"; 4'hF: uart_data <= "F";
                        endcase
                    end
                    else if (report_idx == 8) uart_data <= 8'h0D;
                    else if (report_idx == 9) begin
                        uart_data  <= 8'h0A;
                        uart_valid <= 1;
                    end
                    else if (report_idx == 10) begin
                        uart_valid <= 0;
                        state      <= SETTLE;
                    end
                end else begin
                    uart_valid <= 0;
                end
            end

        endcase
    end
end

// ----------------------------------------------------------------
// Refresh tick generator — runs independently of FSM state
// ----------------------------------------------------------------
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
