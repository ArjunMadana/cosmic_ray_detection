    `timescale 1ns / 1ps
    `include "uart_boot_banner.v"
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
//        input  wire        reset,

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
        input  wire        uart_rxd,

        // LEDs
        output wire        led0,
        output wire        led1
    );
    
    // Internal wires
    wire        ui_clk;
    wire        jtag_clk;
    wire        jtag_cfgmclk;
    wire        calib_complete;
    wire [11:0] device_temp;
    wire        refresh_tick_out;
    
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
    wire [7:0]  rx_data;
    wire        rx_valid;
    wire [7:0]  fsm_rx_data;
    wire        fsm_rx_valid;
    wire [7:0]  jtag_rx_data;
    wire        jtag_rx_valid;
    
    wire reset;
    assign reset = 1'b0;

    wire        fsm_rst;
    wire        boot_active;
    wire        boot_done;
    assign fsm_rst = !calib_complete || !boot_done;

    localparam UI_CLK_HZ = 150_000_000;
    localparam UART_BAUD = 115_200;

    reg [7:0] boot_rst_count = 8'd0;
    wire      boot_rst;
    assign boot_rst = !boot_rst_count[7];

    always @(posedge ui_clk) begin
        if (!boot_rst_count[7]) begin
            boot_rst_count <= boot_rst_count + 1'b1;
        end
    end

    STARTUPE2 #(
        .PROG_USR("FALSE"),
        .SIM_CCLK_FREQ(0.0)
    ) u_jtag_startupe2 (
        .CFGCLK(),
        .CFGMCLK(jtag_cfgmclk),
        .EOS(),
        .PREQ(),
        .CLK(1'b0),
        .GSR(1'b0),
        .GTS(1'b0),
        .KEYCLEARB(1'b1),
        .PACK(1'b0),
        .USRCCLKO(1'b0),
        .USRCCLKTS(1'b1),
        .USRDONEO(1'b1),
        .USRDONETS(1'b1)
    );

    assign jtag_clk = jtag_cfgmclk;
    
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
        .reset_0            (~reset),
        .device_temp_0      (device_temp),
        .ext_refresh_tick   (refresh_tick_out)
    );
    
    // FSM
    detector_fsm u_fsm (
        .clk            (ui_clk),
        .rst            (fsm_rst),
        .calib_complete (calib_complete),
        .refresh_tick_out (refresh_tick_out),
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
        .rx_data        (fsm_rx_data),
        .rx_valid       (fsm_rx_valid),
        .led0           (led0),
        .led1           (led1),
        .temp_raw       (device_temp)
    );
    
    wire [7:0]  boot_uart_data;
    wire        boot_uart_valid;
    wire        boot_uart_ready;
    wire        boot_uart_txd;
    wire        fsm_uart_txd;
    wire        uart_txd_int;
    reg  [7:0]  jtag_tx_data = 8'd0;
    reg         jtag_tx_valid = 1'b0;

    uart_boot_banner u_boot_banner (
        .clk        (ui_clk),
        .rst        (boot_rst),
        .uart_ready (boot_uart_ready),
        .uart_data  (boot_uart_data),
        .uart_valid (boot_uart_valid),
        .active     (boot_active),
        .done       (boot_done)
    );

    uart_tx #(
        .CLK_FREQ  (UI_CLK_HZ),
        .BAUD_RATE (UART_BAUD)
    ) u_boot_uart_tx (
        .clk   (ui_clk),
        .rst   (boot_rst),
        .data  (boot_uart_data),
        .valid (boot_uart_valid),
        .ready (boot_uart_ready),
        .tx    (boot_uart_txd)
    );

    assign uart_txd_int = boot_active ? boot_uart_txd : fsm_uart_txd;
    assign uart_txd = uart_txd_int;
    assign fsm_rx_data = jtag_rx_valid ? jtag_rx_data : rx_data;
    assign fsm_rx_valid = jtag_rx_valid | rx_valid;

    // Capture exactly the bytes accepted by the UART TX path, then forward
    // them to the JTAG mailbox on the following clock.
    always @(posedge ui_clk) begin
        if (boot_rst) begin
            jtag_tx_data  <= 8'd0;
            jtag_tx_valid <= 1'b0;
        end else begin
            jtag_tx_valid <= 1'b0;
            if (boot_active) begin
                if (boot_uart_valid && boot_uart_ready) begin
                    jtag_tx_data  <= boot_uart_data;
                    jtag_tx_valid <= 1'b1;
                end
            end else if (uart_valid && uart_ready) begin
                jtag_tx_data  <= uart_data;
                jtag_tx_valid <= 1'b1;
            end
        end
    end

    jtag_vio_mailbox u_jtag_mailbox (
        .clk       (ui_clk),
        .vio_clk   (jtag_clk),
        .rst       (boot_rst),
        .tx_data   (jtag_tx_data),
        .tx_valid  (jtag_tx_valid),
        .rx_data   (jtag_rx_data),
        .rx_valid  (jtag_rx_valid)
    );

    // UART TX
    uart_tx #(
        .CLK_FREQ  (UI_CLK_HZ),
        .BAUD_RATE (UART_BAUD)
    ) u_uart_tx (
        .clk   (ui_clk),
        .rst   (fsm_rst),
        .data  (uart_data),
        .valid (uart_valid),
        .ready (uart_ready),
        .tx    (fsm_uart_txd)
    );

    // UART RX — receives hold-time commands from laptop
    uart_rx #(
        .CLK_FREQ  (UI_CLK_HZ),
        .BAUD_RATE (UART_BAUD)
    ) u_uart_rx (
        .clk   (ui_clk),
        .rst   (fsm_rst),
        .rx    (uart_rxd),
        .data  (rx_data),
        .valid (rx_valid)
    );

    endmodule
