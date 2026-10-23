`timescale 1ns/1ps
module a7_gpu_top(input wire clk, output wire uart_tx, output wire [1:0] led);
    wire feedback, feedback_buf, gpu_raw, gpu_clk, locked;
    // 50 MHz input -> 1000 MHz VCO -> 10 MHz compute/serial clock.
    MMCME2_BASE #(.CLKIN1_PERIOD(20.0),.CLKFBOUT_MULT_F(20.0),
        .DIVCLK_DIVIDE(1),.CLKOUT0_DIVIDE_F(100.0)) mmcm(
        .CLKIN1(clk),.CLKFBIN(feedback_buf),.CLKFBOUT(feedback),
        .CLKOUT0(gpu_raw),.LOCKED(locked),.PWRDWN(1'b0),.RST(1'b0));
    BUFG fb_buf(.I(feedback),.O(feedback_buf));
    BUFG gpu_buf(.I(gpu_raw),.O(gpu_clk));
    (* ASYNC_REG="TRUE" *) reg [3:0] reset_sync=4'b1111;
    always @(posedge gpu_clk or negedge locked)
        if(!locked) reset_sync<=4'b1111;
        else reset_sync<={reset_sync[2:0],1'b0};
    // BRAM enables/write strobes must not have asynchronous reset fan-in.
    // This final stage asserts AND releases the SM reset on gpu_clk edges.
    reg gpu_reset=1'b1;
    always @(posedge gpu_clk) gpu_reset<=reset_sync[3];
    gpu_demo demo(.clk(gpu_clk),.reset(gpu_reset),.uart_tx_o(uart_tx),.led(led));
endmodule
