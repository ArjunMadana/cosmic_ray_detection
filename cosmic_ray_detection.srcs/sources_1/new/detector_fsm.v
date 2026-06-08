`timescale 1ns / 1ps
`include "uart_reporter.v"
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
    parameter UI_CLK_HZ = 32'd150_000_000
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
    output wire [7:0]  uart_data,
    output wire        uart_valid,
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
localparam SETTLE       = 5'd9;

localparam PK_READY   = 4'd0;
localparam PK_INT     = 4'd1;
localparam PK_PAT     = 4'd2;
localparam PK_REF     = 4'd3;
localparam PK_REPORT  = 4'd4;
localparam PK_ADDRHDR = 4'd5;
localparam PK_TEMP    = 4'd6;
localparam PK_ADDRLINE = 4'd7;

localparam CMD_NONE = 3'd0;
localparam CMD_H    = 3'd1;
localparam CMD_P    = 3'd2;
localparam CMD_R    = 3'd3;

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

reg [2:0]  cmd_kind;
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

(* ram_style = "block" *) reg [27:0] addr_buf [0:4095];
reg [12:0] buf_count;
reg [12:0] buf_rd_count;
reg [11:0] buf_rd_ptr;
reg        stream_body;
reg [1:0]  stream_read_wait;
reg        stream_addr_pending;
reg        addr_capture_pending;
reg [11:0] addr_capture_wr_addr;
reg [27:0] addr_capture_wr_data;
reg [11:0] addr_buf_rd_addr;
reg [27:0] addr_buf_rd_data;
reg        addr_overflow;
reg [31:0] addr_overflow_count;

reg        write_active;
reg        write_aw_done;
reg        write_w_done;
reg [27:0] issued_addr;
reg        read_active;
reg        read_ar_done;
reg [27:0] issued_read_addr;
reg        mismatch_pending;
reg [27:0] mismatch_addr;
reg        scan_done_pending;
reg [31:0] scan_done_hits;

reg        report_start;
reg [3:0]  report_kind;
reg [4:0]  report_next_state;
reg [27:0] report_addr;
wire       report_busy;
wire       report_done;
wire       write_aw_done_now;
wire       write_w_done_now;
wire       read_ar_done_now;

assign write_aw_done_now = write_aw_done || (awvalid && awready);
assign write_w_done_now  = write_w_done  || (wvalid && wready);
assign read_ar_done_now  = read_ar_done  || (arvalid && arready);

uart_reporter u_reporter (
    .clk(clk),
    .rst(rst),
    .start(report_start),
    .kind(report_kind),
    .busy(report_busy),
    .done(report_done),
    .uart_data(uart_data),
    .uart_valid(uart_valid),
    .uart_ready(uart_ready),
    .hold_dig3(hold_dig3),
    .hold_dig2(hold_dig2),
    .hold_dig1(hold_dig1),
    .hold_dig0(hold_dig0),
    .pattern_sel(pattern_sel),
    .fill_pattern_sel(fill_pattern_sel),
    .refresh_sel(refresh_print_sel),
    .addr_count(buf_count),
    .addr_overflow(addr_overflow),
    .addr_value(report_addr),
    .flip_count(report_shift),
    .temp_raw(temp_shift)
);

always @(posedge clk) begin
    if (!rst && addr_capture_pending) begin
        addr_buf[addr_capture_wr_addr] <= addr_capture_wr_data;
    end
    addr_buf_rd_data <= addr_buf[addr_buf_rd_addr];
end

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
        stream_body         <= 0;
        stream_read_wait    <= 0;
        stream_addr_pending <= 0;
        addr_capture_pending <= 0;
        addr_capture_wr_addr <= 0;
        addr_capture_wr_data <= 0;
        addr_buf_rd_addr    <= 0;
        addr_overflow       <= 0;
        addr_overflow_count <= 0;
        write_active        <= 0;
        write_aw_done       <= 0;
        write_w_done        <= 0;
        issued_addr         <= 0;
        read_active         <= 0;
        read_ar_done        <= 0;
        issued_read_addr    <= 0;
        mismatch_pending    <= 0;
        mismatch_addr       <= 0;
        scan_done_pending   <= 0;
        scan_done_hits      <= 0;
        report_shift        <= 0;
        temp_shift          <= 0;
        report_start        <= 0;
        report_kind         <= PK_READY;
        report_next_state   <= WAIT_GO;
        report_addr         <= 0;
    end else begin
        led0 <= calib_complete;
        led1 <= (state != WAIT_INIT);
        report_start <= 0;
        addr_capture_pending <= 0;

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
            write_active     <= 0;
            write_aw_done    <= 0;
            write_w_done     <= 0;
            read_active      <= 0;
            read_ar_done     <= 0;
            issued_read_addr <= 0;
            buf_count        <= 0;
            buf_rd_count     <= 0;
            buf_rd_ptr       <= 0;
            stream_body      <= 0;
            stream_read_wait <= 0;
            stream_addr_pending <= 0;
            addr_capture_pending <= 0;
            mismatch_pending <= 0;
            scan_done_pending <= 0;
            state            <= PRINT;
            report_kind      <= PK_READY;
            report_next_state <= WAIT_GO;
            report_start     <= 1;
        end else begin
            case (state)
                WAIT_INIT: begin
                    if (calib_complete) begin
                        state            <= PRINT;
                        report_kind      <= PK_READY;
                        report_next_state <= WAIT_GO;
                        report_start     <= 1;
                    end
                end

                WAIT_GO: begin
                    if (interval_changed) begin
                        interval_changed <= 0;
                        state            <= PRINT;
                        report_kind      <= PK_INT;
                        report_next_state <= WAIT_GO;
                        report_start     <= 1;
                    end else if (pat_changed) begin
                        pat_changed      <= 0;
                        state            <= PRINT;
                        report_kind      <= PK_PAT;
                        report_next_state <= WAIT_GO;
                        report_start     <= 1;
                    end else if (refresh_changed) begin
                        refresh_changed  <= 0;
                        state            <= PRINT;
                        report_kind      <= PK_REF;
                        report_next_state <= WAIT_GO;
                        report_start     <= 1;
                    end else if (go_flag) begin
                        go_flag             <= 0;
                        fill_pattern_sel    <= pattern_sel;
                        addr                <= 0;
                        hold_tick_counter   <= 0;
                        hold_sec_counter    <= 0;
                        write_active        <= 0;
                        write_aw_done       <= 0;
                        write_w_done        <= 0;
                        issued_addr         <= 0;
                        mismatch_pending    <= 0;
                        scan_done_pending   <= 0;
                        addr_overflow       <= 0;
                        addr_overflow_count <= 0;
                        buf_count           <= 0;
                        state               <= FILL;
                    end
                end

                FILL: begin
                    if (!write_active && !awvalid && !wvalid && !bvalid) begin
                        issued_addr   <= addr;
                        awaddr        <= addr;
                        awvalid       <= 1;
                        wdata         <= active_pattern;
                        wstrb         <= 4'hF;
                        wvalid        <= 1;
                        write_active  <= 1;
                        write_aw_done <= 0;
                        write_w_done  <= 0;
                    end
                    if (awvalid && awready) begin
                        awvalid            <= 0;
                        write_aw_done      <= 1;
                    end
                    if (wvalid && wready) begin
                        wvalid             <= 0;
                        write_w_done       <= 1;
                    end
                    if (write_active && write_aw_done_now && write_w_done_now && bvalid) begin
                        write_active      <= 0;
                        write_aw_done     <= 0;
                        write_w_done      <= 0;
                        if (issued_addr >= MEM_SIZE - 4) begin
                            addr  <= 0;
                            state <= FILL2;
                        end else begin
                            addr <= issued_addr + 4;
                        end
                    end
                end

                FILL2: begin
                    if (!write_active && !awvalid && !wvalid && !bvalid) begin
                        issued_addr   <= addr;
                        awaddr        <= addr;
                        awvalid       <= 1;
                        wdata         <= active_pattern;
                        wstrb         <= 4'hF;
                        wvalid        <= 1;
                        write_active  <= 1;
                        write_aw_done <= 0;
                        write_w_done  <= 0;
                    end
                    if (awvalid && awready) begin
                        awvalid            <= 0;
                        write_aw_done      <= 1;
                    end
                    if (wvalid && wready) begin
                        wvalid             <= 0;
                        write_w_done       <= 1;
                    end
                    if (write_active && write_aw_done_now && write_w_done_now && bvalid) begin
                        write_active      <= 0;
                        write_aw_done     <= 0;
                        write_w_done      <= 0;
                        if (issued_addr >= MEM_SIZE - 4) begin
                            addr              <= 0;
                            hold_tick_counter <= 0;
                            hold_sec_counter  <= 0;
                            state             <= HOLD;
                        end else begin
                            addr <= issued_addr + 4;
                        end
                    end
                end

                HOLD: begin
                    if (interval_changed) begin
                        interval_changed <= 0;
                        state            <= PRINT;
                        report_kind      <= PK_INT;
                        report_next_state <= HOLD;
                        report_start     <= 1;
                    end else if (pat_changed) begin
                        pat_changed      <= 0;
                        state            <= PRINT;
                        report_kind      <= PK_PAT;
                        report_next_state <= HOLD;
                        report_start     <= 1;
                    end else if (refresh_changed) begin
                        refresh_changed  <= 0;
                        state            <= PRINT;
                        report_kind      <= PK_REF;
                        report_next_state <= HOLD;
                        report_start     <= 1;
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
                        read_active         <= 0;
                        read_ar_done        <= 0;
                        issued_read_addr    <= 0;
                        arvalid             <= 0;
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
                        if (buf_count < ADDR_BUF_CAPACITY) begin
                            addr_capture_pending <= 1;
                            addr_capture_wr_addr <= buf_count[11:0];
                            addr_capture_wr_data <= mismatch_addr;
                            buf_count            <= buf_count + 1;
                        end else begin
                            addr_overflow       <= 1;
                            addr_overflow_count <= addr_overflow_count + 1;
                        end
                    end else if (scan_done_pending) begin
                        scan_done_pending <= 0;
                        state             <= STREAM_ADDRS;
                        report_shift      <= scan_done_hits;
                        report_kind       <= PK_ADDRHDR;
                        report_start      <= 1;
                        buf_rd_count      <= 0;
                        buf_rd_ptr        <= 0;
                        stream_body       <= 0;
                        stream_read_wait  <= 0;
                        stream_addr_pending <= 0;
                    end else begin
                        if (!read_active) begin
                            araddr           <= addr;
                            issued_read_addr <= addr;
                            arvalid          <= 1;
                            read_active      <= 1;
                            read_ar_done     <= 0;
                        end else begin
                            if (arvalid && arready) begin
                                arvalid      <= 0;
                                read_ar_done <= 1;
                            end
                            if (rvalid && read_ar_done_now) begin
                                read_active  <= 0;
                                read_ar_done <= 0;
                                if (rdata != active_pattern) begin
                                    mismatch_pending <= 1;
                                    mismatch_addr    <= issued_read_addr;
                                end
                                if (issued_read_addr >= MEM_SIZE - 4) begin
                                    scan_done_pending <= 1;
                                    scan_done_hits    <= (rdata != active_pattern) ? hit_counter + 1 : hit_counter;
                                end else begin
                                    addr <= issued_read_addr + 4;
                                end
                            end
                        end
                    end
                end

                STREAM_ADDRS: begin
                    if (stream_addr_pending) begin
                        stream_addr_pending <= 0;
                        report_kind         <= PK_ADDRLINE;
                        report_start        <= 1;
                    end else if (stream_read_wait != 0) begin
                        if (stream_read_wait == 1) begin
                            report_addr         <= addr_buf_rd_data;
                            stream_addr_pending <= 1;
                        end
                        stream_read_wait <= stream_read_wait - 1;
                    end else if (report_done) begin
                        if (!stream_body) begin
                            if (buf_count == 0) begin
                                report_shift      <= hit_counter;
                                state             <= PRINT;
                                report_kind       <= PK_REPORT;
                                report_next_state <= PRINT_TEMP;
                                report_start      <= 1;
                            end else begin
                                stream_body       <= 1;
                                buf_rd_count      <= 0;
                                buf_rd_ptr        <= 0;
                                addr_buf_rd_addr  <= 0;
                                stream_read_wait  <= 2;
                            end
                        end else begin
                            if (buf_rd_count + 1 >= buf_count) begin
                                stream_body      <= 0;
                                report_shift     <= hit_counter;
                                state            <= PRINT;
                                report_kind      <= PK_REPORT;
                                report_next_state <= PRINT_TEMP;
                                report_start     <= 1;
                            end else begin
                                buf_rd_count     <= buf_rd_count + 1;
                                buf_rd_ptr       <= buf_rd_ptr + 1;
                                addr_buf_rd_addr <= buf_rd_ptr + 1;
                                stream_read_wait <= 2;
                            end
                        end
                    end
                end

                PRINT: begin
                    if (report_done) begin
                        state <= report_next_state;
                    end
                end

                PRINT_TEMP: begin
                    temp_shift       <= temp_raw;
                    state            <= PRINT;
                    report_kind      <= PK_TEMP;
                    report_next_state <= SETTLE;
                    report_start     <= 1;
                end

                SETTLE: begin
                    awvalid          <= 0;
                    wvalid           <= 0;
                    arvalid          <= 0;
                    write_active     <= 0;
                    write_aw_done    <= 0;
                    write_w_done     <= 0;
                    mismatch_pending  <= 0;
                    scan_done_pending <= 0;
                    if (!bvalid && !rvalid) begin
                        addr             <= 0;
                        hit_counter      <= 0;
                        hold_tick_counter <= 0;
                        hold_sec_counter <= 0;
                        fill_pattern_sel <= pattern_sel;
                        addr_overflow_count <= 0;
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
