    `timescale 1ns / 1ps
    //////////////////////////////////////////////////////////////////////////////////
    // Company: 
    // Engineer: 
    // 
    // Create Date: 03/05/2026 09:07:46 PM
    // Design Name: 
    // Module Name: cosmic_top
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
    
    module cosmic_top (
        input  wire        sys_clock,
        input  wire        reset,
        input  wire        sw0,
    
        // DDR3
        inout  wire [15:0] ddr3_dq,
        inout  wire [1:0]  ddr3_dqs_n,
        inout  wire [1:0]  ddr3_dqs_p,
        output wire [13:0] ddr3_addr,
        output wire [2:0]  ddr3_ba,
        output wire        ddr3_ras_n,
        output wire        ddr3_cas_n,
        output wire        ddr3_we_n,
        output wire        ddr3_reset_n,
        output wire        ddr3_ck_p,
        output wire        ddr3_ck_n,
        output wire        ddr3_cke,
        output wire        ddr3_cs_n,
        output wire [1:0]  ddr3_dm,
        output wire        ddr3_odt,
    
        // UART
        output wire        uart_txd,
    
        // LEDs
        output wire        led0,
        output wire        led1
    );
    
    // Internal wires
    wire        ui_clk;
    wire        ui_rst;
    wire        calib_complete;
    
    // AXI wires
    wire [27:0] awaddr;
    wire        awvalid;
    wire        awready;
    wire [31:0] wdata;
    wire [3:0]  wstrb;
    wire        wvalid;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    wire        bready;
    wire [27:0] araddr;
    wire        arvalid;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    wire        rready;
    
    // UART wires
    wire [7:0]  uart_data;
    wire        uart_valid;
    wire        uart_ready;
    
    wire        fsm_rst;
    assign fsm_rst = !calib_complete;
    assign led1 = calib_complete;  // MIG PLL locked indicator
    
    // Block design instance
    cosmic_bd_wrapper u_bd (
        .sys_clock          (sys_clock),
        .reset              (~reset),
        .DDR3_0_addr        (ddr3_addr),
        .DDR3_0_ba          (ddr3_ba),
        .DDR3_0_cas_n       (ddr3_cas_n),
        .DDR3_0_ck_n        (ddr3_ck_n),
        .DDR3_0_ck_p        (ddr3_ck_p),
        .DDR3_0_cke         (ddr3_cke),
        .DDR3_0_cs_n        (ddr3_cs_n),
        .DDR3_0_dm          (ddr3_dm),
        .DDR3_0_dq          (ddr3_dq),
        .DDR3_0_dqs_n       (ddr3_dqs_n),
        .DDR3_0_dqs_p       (ddr3_dqs_p),
        .DDR3_0_odt         (ddr3_odt),
        .DDR3_0_ras_n       (ddr3_ras_n),
        .DDR3_0_reset_n     (ddr3_reset_n),
        .DDR3_0_we_n        (ddr3_we_n),
        .ui_clk_0           (ui_clk),
        .init_calib_complete_0 (calib_complete),
        .S00_AXI_0_awaddr   (awaddr),
        .S00_AXI_0_awvalid  (awvalid),
        .S00_AXI_0_awready  (awready),
        .S00_AXI_0_wdata    (wdata),
        .S00_AXI_0_wstrb    (wstrb),
        .S00_AXI_0_wvalid   (wvalid),
        .S00_AXI_0_wready   (wready),
        .S00_AXI_0_bresp    (bresp),
        .S00_AXI_0_bvalid   (bvalid),
        .S00_AXI_0_bready   (bready),
        .S00_AXI_0_araddr   (araddr),
        .S00_AXI_0_arvalid  (arvalid),
        .S00_AXI_0_arready  (arready),
        .S00_AXI_0_rdata    (rdata),
        .S00_AXI_0_rresp    (rresp),
        .S00_AXI_0_rvalid   (rvalid),
        .S00_AXI_0_rready   (rready),
        .S00_AXI_0_awburst  (2'b01),
        .S00_AXI_0_awlen    (8'b0),
        .S00_AXI_0_awsize   (3'b010),
        .S00_AXI_0_arburst  (2'b01),
        .S00_AXI_0_arlen    (8'b0),
        .S00_AXI_0_arsize   (3'b010),
        .S00_AXI_0_wlast    (1'b1),
        .reset_0            (~reset)
    );
    
    // FSM
    detector_fsm u_fsm (
        .clk            (ui_clk),
        .rst            (fsm_rst),
        .calib_complete (calib_complete),
        .sw0            (sw0),
        .awaddr         (awaddr),
        .awvalid        (awvalid),
        .awready        (awready),
        .wdata          (wdata),
        .wstrb          (wstrb),
        .wvalid         (wvalid),
        .wready         (wready),
        .bresp          (bresp),
        .bvalid         (bvalid),
        .bready         (bready),
        .araddr         (araddr),
        .arvalid        (arvalid),
        .arready        (arready),
        .rdata          (rdata),
        .rresp          (rresp),
        .rvalid         (rvalid),
        .rready         (rready),
        .uart_data      (uart_data),
        .uart_valid     (uart_valid),
        .uart_ready     (uart_ready),
        .led0           (led0)
    );
    
    // UART
    uart_tx u_uart (
        .clk   (ui_clk),
        .rst   (fsm_rst),
        .data  (uart_data),
        .valid (uart_valid),
        .ready (uart_ready),
        .tx    (uart_txd)
    );
    
    endmodule
