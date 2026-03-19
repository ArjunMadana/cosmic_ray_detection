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
    parameter MEM_SIZE = 28'h1000000,  // 16M words
//    parameter MEM_SIZE = 28'h1000, // 4000 words
//    parameter HOLD_CYCLES = 32'd750_000_000 // 5 seconds at 150MHz
    parameter HOLD_CYCLES = 64'd4_500_000_000 // 30 s
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        calib_complete,
    input  wire        sw0,

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
    output reg         led0,  // calib complete
    output reg         led1   // not in WAIT_INIT
    );

localparam WAIT_INIT = 3'd0;
localparam FILL      = 3'd1;
localparam HOLD      = 3'd2;
localparam SCAN      = 3'd3;
localparam REPORT    = 3'd4;

reg [2:0]  state;
reg [27:0] addr;
reg [31:0] hit_counter;
reg [31:0] report_shift;
reg [3:0]  report_idx;
reg [63:0] hold_counter;


localparam PATTERN = 32'h55555555;

always @(posedge clk) begin
    if (rst) begin
        state       <= WAIT_INIT;
        addr        <= 0;
        hit_counter <= 0;
        awvalid     <= 0;
        wvalid      <= 0;
        bready      <= 1;
        arvalid     <= 0;
        rready      <= 1;
        uart_valid  <= 0;
        led0        <= 0;
        led1        <= 0;
        hold_counter <= 0;
    end else begin
        led0 <= calib_complete;
        led1 <= (state != WAIT_INIT);

        case (state)
            WAIT_INIT: begin
                if (calib_complete) begin
                    state <= FILL;
                    addr  <= 0;
                end
            end

            FILL: begin
                if (!awvalid && !wvalid) begin
                    awaddr  <= addr;
                    awvalid <= 1;
                    wdata   <= PATTERN;
                    wstrb   <= 4'hF;
                    wvalid  <= 1;
                end
                if (awvalid && awready) awvalid <= 0;
                if (wvalid  && wready)  wvalid  <= 0;
                if (bvalid) begin
                    if (addr >= MEM_SIZE - 1) begin
                        addr  <= 0;
                        state <= HOLD;
                    end else begin
                        addr <= addr + 1;
                    end
                end
            end

            HOLD: begin
                if (hold_counter >= HOLD_CYCLES) begin
                    state <= SCAN;
                    addr  <= 0;
                    hit_counter <= 0;
                    hold_counter <= 0;
                end else begin
                    hold_counter <= hold_counter + 1;
                end
            end

            SCAN: begin
                if (!arvalid) begin
                    araddr  <= addr;
                    arvalid <= 1;
                end
                if (arvalid && arready) arvalid <= 0;
                if (rvalid) begin
                    if (rdata != PATTERN)
                        hit_counter <= hit_counter + 1;
                    if (addr >= MEM_SIZE - 1) begin
                        state <= REPORT;
                        report_shift <= hit_counter;
                        report_idx   <= 0;
                    end else begin
                        addr <= addr + 1;
                    end
                end
            end

            REPORT: begin
                if (uart_ready && !uart_valid) begin
                    report_idx <= report_idx + 1;
            
                    if (report_idx < 14)
                        uart_valid <= 1;
            
                    if (report_idx == 0)      uart_data <= "H";
                    else if (report_idx == 1) uart_data <= "I";
                    else if (report_idx == 2) uart_data <= "T";
                    else if (report_idx == 3) uart_data <= ":";
                    else if (report_idx <= 11) begin
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
                    else if (report_idx == 12) uart_data <= 8'h0D;
                    else if (report_idx == 13) uart_data <= 8'h0A;
                    else if (report_idx == 14) begin
                        uart_valid  <= 0;
                        state       <= FILL;
                        addr        <= 0;
                        hit_counter <= 0;
                    end
                end else begin
                    uart_valid <= 0;
                end
            end
        endcase
    end
end

endmodule
