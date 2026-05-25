`timescale 1ns / 1ps

module detector_fsm_tb;
    localparam MEM_SIZE  = 28'h0000100;
    localparam MEM_WORDS = MEM_SIZE / 4;

    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1;
    reg calib_complete = 0;

    wire        refresh_tick_out;
    wire [27:0] awaddr;
    wire        awvalid;
    reg         awready = 0;
    wire [31:0] wdata;
    wire [3:0]  wstrb;
    wire        wvalid;
    reg         wready = 0;
    reg  [1:0]  bresp = 0;
    reg         bvalid = 0;
    wire        bready;
    wire [27:0] araddr;
    wire        arvalid;
    reg         arready = 0;
    reg  [31:0] rdata = 0;
    reg  [1:0]  rresp = 0;
    reg         rvalid = 0;
    wire        rready;
    wire [7:0]  uart_data;
    wire        uart_valid;
    reg         uart_ready = 1;
    reg  [7:0]  rx_data = 0;
    reg         rx_valid = 0;
    wire        led0;
    wire        led1;

    reg [31:0] mem [0:MEM_WORDS-1];
    reg [27:0] pending_awaddr;
    reg [31:0] pending_wdata;
    reg        aw_seen = 0;
    reg        w_seen = 0;
    reg        stall_mode = 0;
    reg [1:0]  write_order_mode = 0;
    integer i;

    detector_fsm #(
        .MEM_SIZE(MEM_SIZE),
        .UI_CLK_HZ(32'd20)
    ) dut (
        .clk(clk),
        .rst(rst),
        .calib_complete(calib_complete),
        .refresh_tick_out(refresh_tick_out),
        .awaddr(awaddr),
        .awvalid(awvalid),
        .awready(awready),
        .wdata(wdata),
        .wstrb(wstrb),
        .wvalid(wvalid),
        .wready(wready),
        .bresp(bresp),
        .bvalid(bvalid),
        .bready(bready),
        .araddr(araddr),
        .arvalid(arvalid),
        .arready(arready),
        .rdata(rdata),
        .rresp(rresp),
        .rvalid(rvalid),
        .rready(rready),
        .uart_data(uart_data),
        .uart_valid(uart_valid),
        .uart_ready(uart_ready),
        .rx_data(rx_data),
        .rx_valid(rx_valid),
        .led0(led0),
        .led1(led1),
        .temp_raw(12'h800)
    );

    function ready_now;
        input unused;
        begin
            ready_now = !stall_mode || ($random % 4 != 0);
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            awready <= 0;
            wready  <= 0;
            arready <= 0;
            bvalid  <= 0;
            rvalid  <= 0;
            aw_seen <= 0;
            w_seen  <= 0;
            bresp   <= 0;
            rresp   <= 0;
            for (i = 0; i < MEM_WORDS; i = i + 1)
                mem[i] <= 32'hCAFE0000 + i;
        end else begin
            case (write_order_mode)
                2'd1: begin
                    awready <= w_seen && ready_now(1'b0);
                    wready  <= ready_now(1'b0);
                end
                2'd2: begin
                    awready <= ready_now(1'b0);
                    wready  <= aw_seen && ready_now(1'b0);
                end
                default: begin
                    awready <= ready_now(1'b0);
                    wready  <= ready_now(1'b0);
                end
            endcase
            arready <= ready_now(1'b0) && !rvalid;

            if (awvalid && awready) begin
                pending_awaddr <= awaddr;
                aw_seen <= 1;
            end
            if (wvalid && wready) begin
                pending_wdata <= wdata;
                w_seen <= 1;
            end
            if (!bvalid && aw_seen && w_seen) begin
                mem[pending_awaddr[7:2]] <= pending_wdata;
                bvalid <= 1;
                aw_seen <= 0;
                w_seen <= 0;
            end else if (bvalid && bready) begin
                bvalid <= 0;
            end

            if (arvalid && arready && !rvalid) begin
                rdata <= mem[araddr[7:2]];
                rvalid <= 1;
            end else if (rvalid && rready) begin
                rvalid <= 0;
            end
        end
    end

    task send_byte;
        input [7:0] value;
        begin
            @(posedge clk);
            rx_data <= value;
            rx_valid <= 1;
            @(posedge clk);
            rx_valid <= 0;
        end
    endtask

    task send_pattern;
        input [7:0] digit;
        begin
            send_byte("P");
            send_byte(digit);
            send_byte(8'h0A);
        end
    endtask

    task start_cycle;
        begin
            send_byte("G");
        end
    endtask

    function [31:0] pattern_word;
        input [1:0] expected_pattern;
        begin
            case (expected_pattern)
                2'd0: pattern_word = 32'hFFFFFFFF;
                2'd1: pattern_word = 32'h00000000;
                2'd2: pattern_word = 32'h55555555;
                default: pattern_word = 32'hAAAAAAAA;
            endcase
        end
    endfunction

    task wait_cycle_and_check;
        input [1:0] expected_pattern;
        integer timeout;
        integer j;
        reg [31:0] expected_word;
        begin
            timeout = 0;
            while (dut.state == 5'd9 && timeout < 20000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            while (dut.state != 5'd9 && timeout < 20000) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (timeout >= 20000) begin
                $display("TIMEOUT waiting for cycle SETTLE");
                $finish;
            end
            #1;
            if (dut.hit_counter != 0) begin
                $display("FAIL mismatch count: got %0d", dut.hit_counter);
                $finish;
            end
            expected_word = pattern_word(expected_pattern);
            for (j = 0; j < MEM_WORDS; j = j + 1) begin
                if (mem[j] !== expected_word) begin
                    $display("FAIL memory[%0d]: got %h expected %h", j, mem[j], expected_word);
                    $finish;
                end
            end
            @(posedge clk);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst <= 0;
        calib_complete <= 1;

        repeat (20) @(posedge clk);
        start_cycle();

        stall_mode <= 0;
        write_order_mode <= 0;
        wait_cycle_and_check(2'd0);

        stall_mode <= 1;
        write_order_mode <= 1;
        wait (dut.state == 5'd4);
        send_pattern("3");
        wait_cycle_and_check(2'd0);
        write_order_mode <= 2;
        wait (dut.state == 5'd4);
        send_pattern("1");
        wait_cycle_and_check(2'd3);
        wait_cycle_and_check(2'd1);

        $display("detector_fsm_tb PASS");
        $finish;
    end
endmodule
