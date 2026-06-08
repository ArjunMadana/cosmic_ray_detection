`timescale 1ns / 1ps

module jtag_vio_mailbox #(
    parameter FIFO_BITS = 12
) (
    input  wire       clk,
    input  wire       vio_clk,
    input  wire       rst,

    input  wire [7:0] tx_data,
    input  wire       tx_valid,

    output reg  [7:0] rx_data,
    output reg        rx_valid
);

localparam FIFO_DEPTH = (1 << FIFO_BITS);
localparam [FIFO_BITS:0] FIFO_DEPTH_COUNT = (1 << FIFO_BITS);

wire [7:0]  vio_tx_data;
wire [15:0] vio_tx_seq;
wire        vio_tx_valid;
wire [11:0] vio_fifo_count;
wire        vio_overflow;
wire [7:0]  vio_cmd_seen_seq;

wire [7:0]  vio_cmd_data;
wire [7:0]  vio_cmd_seq;
wire [15:0] vio_tx_ack_seq;

reg rst_vio_meta = 1'b1;
reg rst_vio = 1'b1;

always @(posedge vio_clk) begin
    rst_vio_meta <= rst;
    rst_vio <= rst_vio_meta;
end

// Detector/UI-clock domain: queue bytes emitted by the firmware and inject
// commands received through the VIO-clock domain.
reg [7:0] fifo_mem [0:FIFO_DEPTH-1];
reg [FIFO_BITS-1:0] wr_ptr = 0;
reg [FIFO_BITS-1:0] rd_ptr = 0;
reg [FIFO_BITS:0] fifo_count = 0;
reg overflow = 1'b0;

reg [15:0] tx_seq = 16'd1;
reg [7:0]  tx_present_data = 8'd0;
reg        tx_present_valid = 1'b0;
reg [7:0]  cmd_seen_seq = 8'd0;
reg [15:0] last_ack_seq = 16'd0;

reg [15:0] ack_seq_ui_meta = 16'd0;
reg [15:0] ack_seq_ui = 16'd0;

reg        cmd_toggle_ui_meta = 1'b0;
reg        cmd_toggle_ui = 1'b0;
reg        cmd_toggle_ui_last = 1'b0;
reg [7:0]  cmd_data_ui_meta = 8'd0;
reg [7:0]  cmd_data_ui = 8'd0;
reg [7:0]  cmd_seq_ui_meta = 8'd0;
reg [7:0]  cmd_seq_ui = 8'd0;

// VIO-clock domain: present detector telemetry to Vivado and latch command
// bytes from the VIO output probes.
reg [7:0]  tx_data_vio_meta = 8'd0;
reg [7:0]  tx_data_vio = 8'd0;
reg [15:0] tx_seq_vio_meta = 16'd1;
reg [15:0] tx_seq_vio = 16'd1;
reg        tx_valid_vio_meta = 1'b0;
reg        tx_valid_vio = 1'b0;
reg [11:0] fifo_count_vio_meta = 12'd0;
reg [11:0] fifo_count_vio = 12'd0;
reg        overflow_vio_meta = 1'b0;
reg        overflow_vio = 1'b0;
reg [7:0]  cmd_seen_vio_meta = 8'd0;
reg [7:0]  cmd_seen_vio = 8'd0;

reg [7:0]  last_cmd_seq_vio = 8'd0;
reg [7:0]  cmd_data_hold_vio = 8'd0;
reg [7:0]  cmd_seq_hold_vio = 8'd0;
reg        cmd_toggle_vio = 1'b0;

wire fifo_load_present = !tx_present_valid && fifo_count != 0;
wire fifo_push = tx_valid && (fifo_count != FIFO_DEPTH_COUNT || fifo_load_present);

always @(posedge clk) begin
    ack_seq_ui_meta <= vio_tx_ack_seq;
    ack_seq_ui <= ack_seq_ui_meta;

    cmd_toggle_ui_meta <= cmd_toggle_vio;
    cmd_toggle_ui <= cmd_toggle_ui_meta;
    cmd_data_ui_meta <= cmd_data_hold_vio;
    cmd_data_ui <= cmd_data_ui_meta;
    cmd_seq_ui_meta <= cmd_seq_hold_vio;
    cmd_seq_ui <= cmd_seq_ui_meta;

    if (rst) begin
        wr_ptr <= 0;
        rd_ptr <= 0;
        fifo_count <= 0;
        overflow <= 1'b0;
        tx_seq <= 16'd1;
        tx_present_data <= 8'd0;
        tx_present_valid <= 1'b0;
        cmd_seen_seq <= 8'd0;
        last_ack_seq <= 16'd0;
        cmd_toggle_ui_last <= cmd_toggle_ui;
        rx_data <= 8'd0;
        rx_valid <= 1'b0;
    end else begin
        rx_valid <= 1'b0;

        if (cmd_toggle_ui != cmd_toggle_ui_last) begin
            cmd_toggle_ui_last <= cmd_toggle_ui;
            cmd_seen_seq <= cmd_seq_ui;
            rx_data <= cmd_data_ui;
            rx_valid <= 1'b1;
        end

        if (tx_valid) begin
            if (fifo_push) begin
                fifo_mem[wr_ptr] <= tx_data;
                wr_ptr <= wr_ptr + 1'b1;
            end else begin
                overflow <= 1'b1;
            end
        end

        if (fifo_load_present) begin
            tx_present_data <= fifo_mem[rd_ptr];
            rd_ptr <= rd_ptr + 1'b1;
            tx_present_valid <= 1'b1;
        end else if (tx_present_valid && ack_seq_ui == tx_seq && ack_seq_ui != last_ack_seq) begin
            last_ack_seq <= ack_seq_ui;
            tx_present_valid <= 1'b0;
            tx_seq <= tx_seq + 1'b1;
        end

        case ({fifo_push, fifo_load_present})
            2'b10: fifo_count <= fifo_count + 1'b1;
            2'b01: fifo_count <= fifo_count - 1'b1;
            default: fifo_count <= fifo_count;
        endcase
    end
end

assign vio_tx_data = tx_data_vio;
assign vio_tx_seq = tx_seq_vio;
assign vio_tx_valid = tx_valid_vio;
assign vio_fifo_count = fifo_count_vio;
assign vio_overflow = overflow_vio;
assign vio_cmd_seen_seq = cmd_seen_vio;

always @(posedge vio_clk) begin
    tx_data_vio_meta <= tx_present_data;
    tx_data_vio <= tx_data_vio_meta;
    tx_seq_vio_meta <= tx_seq;
    tx_seq_vio <= tx_seq_vio_meta;
    tx_valid_vio_meta <= tx_present_valid;
    tx_valid_vio <= tx_valid_vio_meta;
    fifo_count_vio_meta <= fifo_count[FIFO_BITS-1:0];
    fifo_count_vio <= fifo_count_vio_meta;
    overflow_vio_meta <= overflow;
    overflow_vio <= overflow_vio_meta;
    cmd_seen_vio_meta <= cmd_seen_seq;
    cmd_seen_vio <= cmd_seen_vio_meta;

    if (rst_vio) begin
        last_cmd_seq_vio <= 8'd0;
        cmd_data_hold_vio <= 8'd0;
        cmd_seq_hold_vio <= 8'd0;
        cmd_toggle_vio <= 1'b0;
    end else if (vio_cmd_seq != last_cmd_seq_vio) begin
        last_cmd_seq_vio <= vio_cmd_seq;
        cmd_data_hold_vio <= vio_cmd_data;
        cmd_seq_hold_vio <= vio_cmd_seq;
        cmd_toggle_vio <= ~cmd_toggle_vio;
    end
end

vio_jtag_mailbox u_vio_jtag_mailbox (
    .clk        (vio_clk),
    .probe_in0  (vio_tx_data),
    .probe_in1  (vio_tx_seq),
    .probe_in2  (vio_tx_valid),
    .probe_in3  (vio_fifo_count),
    .probe_in4  (vio_overflow),
    .probe_in5  (vio_cmd_seen_seq),
    .probe_out0 (vio_cmd_data),
    .probe_out1 (vio_cmd_seq),
    .probe_out2 (vio_tx_ack_seq)
);

endmodule
