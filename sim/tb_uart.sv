`timescale 1ns/1ps
module tb_uart;
    reg clk=0,reset=1;
    wire tx;
    wire [1:0] led;
    localparam DIV=4;
    gpu_demo #(.UART_DIV(DIV),.FRAME_GAP(20)) dut(.clk(clk),.reset(reset),.uart_tx_o(tx),.led(led));
    always #5 clk=~clk;
    reg [31:0] frame[0:4095];
    reg [7:0] byte_value,expected;
    integer n,b,p;
    initial begin
        $readmemh("build/frame.hex",frame);
        repeat(3) @(negedge clk); reset=0;
        // Check an entire physical UART frame and the next repeated header.
        for(n=0;n<16396;n=n+1) begin
            @(negedge tx);
            #(DIV*10/2);
            if(tx!==0) $fatal(1,"UART start bit");
            for(b=0;b<8;b=b+1) begin #(DIV*10); byte_value[b]=tx; end
            #(DIV*10); if(tx!==1) $fatal(1,"UART stop bit");
            p=n%16392;
            case(p)
                0:expected="G";1:expected="P";2:expected="U";3:expected="2";
                4:expected=64;5:expected=64;6:expected=32;7:expected=0;
                default:expected=frame[(p-8)/4] >> (8*((p-8)%4));
            endcase
            if(byte_value!==expected) $fatal(1,"UART byte %0d got %h expected %h",n,byte_value,expected);
        end
        if(led!==2'b01) $fatal(1,"Incorrect status LEDs");
        $display("PASS UART: full 16392-byte frame and repeat header at pin level");
        $finish;
    end
    initial begin #15000000; $fatal(1,"UART timeout"); end
endmodule
